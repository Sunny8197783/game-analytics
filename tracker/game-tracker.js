/*!
 * game-tracker.js — 게임 방문/체류/마일스톤 기록기 (의존성 없음, 약 4KB)
 *
 * 사용법 (게임 index.html 의 </body> 바로 위):
 *   <script src="https://sunny8197783.github.io/game-analytics/tracker/game-tracker.js"
 *           data-game="flip_it_all"
 *           data-url="https://YOUR-PROJECT.supabase.co"
 *           data-key="sb_publishable_xxx"></script>
 *
 * 게임 코드에서:
 *   GameTracker.milestone('스테이지 3', 3);   // 이름, 순서(step: 클수록 더 진행)
 *
 * 베타 테스터 입장 코드 (기본: 켜짐)
 *   게임을 열면 코드 입력 화면이 게임 위에 뜨고, 맞는 코드를 넣어야 조작할 수 있습니다.
 *   게임 코드는 건드리지 않습니다. 이 기기·이 게임에서 한 번 통과하면 다음부터는 묻지 않습니다.
 *   끄려면 script 태그에 data-gate="off"
 *
 * 자동으로 기록되는 것:
 *   session_start  접속
 *   heartbeat      15초마다 (화면을 보고 있고, 90초 안에 조작이 있었을 때만 시간이 늘어남)
 *   session_end    탭을 닫거나 다른 탭으로 갈 때
 */
(function () {
  'use strict';
  if (window.GameTracker) return;

  var script = document.currentScript || {};
  var ds = script.dataset || {};
  var CFG = {
    game: ds.game || window.GAME_TRACKER_GAME,
    url: (ds.url || window.GAME_TRACKER_URL || '').replace(/\/+$/, ''),
    key: ds.key || window.GAME_TRACKER_KEY,
    heartbeatMs: 15000,
    idleMs: 90000,             // 이 시간 동안 조작이 없으면 '자리 비움'으로 보고 시간을 안 셈
    sessionGapMs: 30 * 60000,  // 30분 넘게 떠나 있다 오면 새 세션
    debug: ds.debug === 'true',
    gate: ds.gate !== 'off'
  };

  function log() { if (CFG.debug) console.log.apply(console, ['[GameTracker]'].concat([].slice.call(arguments))); }
  function noop() {}
  if (!CFG.game || !CFG.url || !CFG.key || !/^[a-z0-9_-]{1,40}$/.test(CFG.game)) {
    console.warn('[GameTracker] data-game / data-url / data-key 를 확인하세요. 기록하지 않습니다.');
    window.GameTracker = { milestone: noop, flush: noop, info: function () { return null; } };
    return;
  }

  // ---------- 저장소 (사생활 보호 모드 등에서 실패해도 동작) ----------
  function get(store, k) { try { return JSON.parse(store.getItem(k)); } catch (e) { return null; } }
  function put(store, k, v) { try { store.setItem(k, JSON.stringify(v)); } catch (e) {} }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
      var r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16);
    });
  }

  var VKEY = 'gt_visitor';
  var PKEY = 'gt_profile_' + CFG.game;   // 이 게임 누적 플레이 시간
  var SKEY = 'gt_session_' + CFG.game;

  var visitorId = get(localStorage, VKEY);
  if (!visitorId) { visitorId = uuid(); put(localStorage, VKEY, visitorId); }

  var profile = get(localStorage, PKEY) || { total: 0 };
  var now = Date.now();
  var sess = get(sessionStorage, SKEY);
  var isNew = !sess || (now - sess.last) > CFG.sessionGapMs;
  if (isNew) sess = { id: uuid(), elapsed: 0, last: now };

  var ua = navigator.userAgent || '';
  var device = /iPad|Tablet/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? 'tablet'
             : /Mobi|Android|iPhone/i.test(ua) ? 'mobile' : 'desktop';
  var referrer = (document.referrer || '').slice(0, 300) || null;

  // ---------- 활동 시간 측정 ----------
  var lastTick = now, lastInput = now, ended = false;
  ['pointerdown', 'keydown', 'touchstart', 'wheel', 'mousemove'].forEach(function (ev) {
    window.addEventListener(ev, function () { lastInput = Date.now(); }, { passive: true, capture: true });
  });
  function tick() {
    var t = Date.now();
    var dt = Math.min(t - lastTick, CFG.heartbeatMs * 2);   // 슬립/백그라운드 후 튀는 값 방지
    if (document.visibilityState === 'visible' && t - lastInput < CFG.idleMs && !ended && !gated) {
      sess.elapsed += dt; profile.total += dt;
    }
    lastTick = t; sess.last = t;
    put(sessionStorage, SKEY, sess); put(localStorage, PKEY, profile);
  }

  // ---------- 전송 (모아서 한 번에) ----------
  var queue = [];
  function push(type, extra) {
    var row = {
      game_id: CFG.game, visitor_id: visitorId, session_id: sess.id, event_type: type,
      elapsed_ms: Math.min(Math.round(sess.elapsed), 86400000),
      total_ms: Math.min(Math.round(profile.total), 3600000000),
      device: device, referrer: referrer
    };
    if (tester && tester.code) row.tester_code = tester.code;
    for (var k in extra) row[k] = extra[k];
    queue.push(row); log(type, row);
  }
  function flush(final) {
    if (!queue.length) return;
    var body = JSON.stringify(queue.splice(0, 50));
    try {
      fetch(CFG.url + '/rest/v1/events', {
        method: 'POST', keepalive: !!final,
        headers: { 'apikey': CFG.key, 'Content-Type': 'application/json', 'Prefer': 'return=minimal' },
        body: body
      }).then(function (r) { if (!r.ok) r.text().then(function (t) { console.warn('[GameTracker]', r.status, t); }); })
        .catch(noop);
    } catch (e) {}
    if (queue.length) flush(final);
  }

  // ---------- 베타 테스터 입장 코드 ----------
  var TKEY = 'gt_tester_' + CFG.game;
  var tester = CFG.gate ? get(localStorage, TKEY) : null;
  var gated = false, host = null, gateInput = null;

  function rpc(fn, args) {
    return fetch(CFG.url + '/rest/v1/rpc/' + fn, {
      method: 'POST', headers: { 'apikey': CFG.key, 'Content-Type': 'application/json' }, body: JSON.stringify(args)
    }).then(function (r) { return r.ok ? r.json() : Promise.reject(new Error('HTTP ' + r.status)); });
  }

  // 입장 화면이 떠 있는 동안 게임으로 가는 입력을 막음 (게임 코드는 그대로)
  var BLOCK = ['keydown', 'keyup', 'keypress', 'pointerdown', 'pointerup', 'pointermove', 'mousedown', 'mouseup', 'mousemove',
               'click', 'dblclick', 'contextmenu', 'touchstart', 'touchmove', 'touchend', 'wheel'];
  function fromGate(e) { var p = e.composedPath ? e.composedPath() : []; return host && p.indexOf(host) >= 0; }
  function blockOutside(e) {
    if (!gated || fromGate(e)) return;
    e.stopImmediatePropagation();
    if (e.type === 'keydown' && gateInput) { try { gateInput.focus(); } catch (x) {} }
    if (e.cancelable && e.type !== 'wheel' && e.type !== 'pointermove' && e.type !== 'mousemove') e.preventDefault();
  }
  BLOCK.forEach(function (t) { window.addEventListener(t, blockOutside, { capture: true, passive: false }); });

  var GATE_CSS =
    ':host{all:initial}' +
    '.bg{position:fixed;inset:0;background:rgba(12,12,14,.82);-webkit-backdrop-filter:blur(8px);backdrop-filter:blur(8px);display:flex;align-items:center;justify-content:center;padding:20px;' +
      'font-family:system-ui,-apple-system,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;color:#f2f1ec;box-sizing:border-box}' +
    '.card{width:min(360px,100%);background:#1c1c1a;border:1px solid #34342f;border-radius:16px;padding:26px 24px 20px;box-shadow:0 20px 60px rgba(0,0,0,.45);box-sizing:border-box}' +
    '.tag{display:inline-block;font-size:11px;letter-spacing:.08em;color:#b9b8ae;border:1px solid #3d3d38;border-radius:99px;padding:3px 9px;margin-bottom:12px}' +
    'h1{font-size:19px;margin:0 0 6px;font-weight:700;letter-spacing:-.01em;line-height:1.35}' +
    'p{font-size:13.5px;color:#b9b8ae;margin:0 0 16px;line-height:1.5}' +
    'input{all:unset;box-sizing:border-box;display:block;width:100%;background:#111110;border:1.5px solid #3d3d38;border-radius:10px;padding:12px 14px;' +
      'font:600 22px/1.2 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.18em;text-align:center;color:#fff;text-transform:uppercase}' +
    'input:focus{border-color:#3987e5}' +
    'input::placeholder{color:#55554f}' +
    'button{all:unset;box-sizing:border-box;display:block;width:100%;margin-top:10px;background:#3987e5;color:#fff;text-align:center;border-radius:10px;padding:12px;font-size:15px;font-weight:600;cursor:pointer}' +
    'button[disabled]{opacity:.55;cursor:default}' +
    '.err{min-height:20px;font-size:12.5px;color:#ef6b63;margin-top:10px;text-align:center}' +
    '.foot{font-size:11.5px;color:#7d7b74;margin-top:6px;text-align:center}';

  function showGate(msg) {
    if (gated) return;
    gated = true;
    host = document.createElement('div');
    host.setAttribute('data-game-tracker-gate', '');
    host.style.cssText = 'all:initial;position:fixed;top:0;left:0;right:0;bottom:0;z-index:2147483647;display:block';
    var root = host.attachShadow ? host.attachShadow({ mode: 'closed' }) : host;
    var title = (document.title || '게임').slice(0, 60);
    root.innerHTML = '<style>' + GATE_CSS + '</style>' +
      '<div class="bg" role="dialog" aria-modal="true" aria-labelledby="t"><form class="card" novalidate>' +
      '<span class="tag">BETA TEST</span><h1 id="t"></h1>' +
      '<p>받은 베타 테스터 코드를 입력하면 게임을 시작할 수 있어요.</p>' +
      '<input name="code" inputmode="text" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="9" placeholder="XXXX-XXXX" aria-label="베타 테스터 코드">' +
      '<button type="submit">입장하기</button><div class="err" role="alert"></div>' +
      '<div class="foot">이 기기에서는 한 번만 입력하면 됩니다</div></form></div>';
    root.querySelector('h1').textContent = title;
    var form = root.querySelector('form'), input = root.querySelector('input'),
        btn = root.querySelector('button'), err = root.querySelector('.err');
    if (msg) err.textContent = msg;
    gateInput = input;
    // 빈 곳을 눌러도 입력칸에 커서가 남아 있게
    root.querySelector('.bg').addEventListener('pointerdown', function (e) {
      if (e.target !== input && e.target !== btn) { e.preventDefault(); input.focus(); }
    });
    // 입장 화면에서 생긴 입력이 게임 쪽으로 퍼지지 않게
    BLOCK.forEach(function (t) { host.addEventListener(t, function (e) { e.stopPropagation(); }); });
    input.addEventListener('input', function () {
      var c = input.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 8);
      input.value = c.length > 4 ? c.slice(0, 4) + '-' + c.slice(4) : c;
      err.textContent = '';
    });
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var code = input.value.replace(/[^A-Z0-9]/g, '');
      if (code.length !== 8) { err.textContent = '코드 8자리를 모두 입력해 주세요.'; return; }
      btn.disabled = true; btn.textContent = '확인 중…';
      rpc('verify_tester', { p_code: code, p_game: CFG.game, p_visitor: visitorId }).then(function (res) {
        if (res && res.ok) {
          tester = { code: res.code, name: res.name }; put(localStorage, TKEY, tester);
          log('tester ok', tester); hideGate(res.name);
        } else {
          btn.disabled = false; btn.textContent = '입장하기';
          err.textContent = res && res.reason === 'inactive' ? '사용이 중지된 코드예요. 담당자에게 문의해 주세요.' : '등록되지 않은 코드예요. 다시 확인해 주세요.';
          input.select();
        }
      }).catch(function () {
        btn.disabled = false; btn.textContent = '입장하기';
        err.textContent = '서버에 연결하지 못했어요. 잠시 후 다시 시도해 주세요.';
      });
    });
    (document.documentElement || document.body).appendChild(host);
    setTimeout(function () { try { input.focus(); } catch (e) {} }, 50);
  }

  function hideGate(name) {
    if (!gated) return;
    gated = false;
    if (host && host.parentNode) host.parentNode.removeChild(host);
    host = null; gateInput = null;
    lastTick = lastInput = Date.now();
    push('heartbeat', {}); flush();
    if (name) toast(name + '님, 환영해요!');
  }

  function toast(text) {
    var t = document.createElement('div');
    t.style.cssText = 'all:initial;position:fixed;left:50%;top:18px;transform:translateX(-50%);z-index:2147483647;pointer-events:none;' +
      'background:rgba(20,20,20,.88);color:#fff;font:600 14px system-ui,-apple-system,"Malgun Gothic",sans-serif;padding:10px 16px;border-radius:99px;' +
      'box-shadow:0 6px 24px rgba(0,0,0,.3);transition:opacity .4s';
    t.textContent = text;
    (document.documentElement || document.body).appendChild(t);
    setTimeout(function () { t.style.opacity = '0'; }, 1800);
    setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 2400);
  }

  if (CFG.gate) {
    if (tester && tester.code) {
      // 예전에 통과한 기기: 바로 들여보내고 뒤에서 다시 확인 (중지된 코드면 그때 막음)
      rpc('verify_tester', { p_code: tester.code, p_game: CFG.game, p_visitor: visitorId }).then(function (res) {
        if (res && res.ok === false) {
          put(localStorage, TKEY, null); tester = null;
          showGate(res.reason === 'inactive' ? '사용이 중지된 코드예요. 담당자에게 문의해 주세요.' : '코드를 다시 입력해 주세요.');
        }
      }).catch(noop);
    } else {
      showGate();
    }
  }

  // ---------- 수명주기 ----------
  if (isNew) push('session_start', {});
  tick(); flush();

  setInterval(function () {
    if (document.visibilityState !== 'visible') return;
    tick(); push('heartbeat', {}); flush();
  }, CFG.heartbeatMs);

  function end() {
    if (ended) return;
    tick(); ended = true; push('session_end', {}); flush(true);
  }
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') end();
    else if (ended) {                       // 돌아옴
      ended = false; lastTick = lastInput = Date.now();
      if (Date.now() - sess.last > CFG.sessionGapMs) { sess = { id: uuid(), elapsed: 0, last: Date.now() }; push('session_start', {}); }
      flush();
    }
  });
  window.addEventListener('pagehide', end);

  // ---------- 공개 API ----------
  window.GameTracker = {
    /** 진행 지점 기록. 같은 사람이 같은 마일스톤을 다시 밟아도 세션마다 한 번만 보냄 */
    milestone: function (name, step) {
      name = String(name || '').slice(0, 60);
      step = Math.max(0, Math.min(10000, parseInt(step, 10) || 0));
      if (!name) return;
      sess.sent = sess.sent || {};
      var key = step + '|' + name;
      if (sess.sent[key]) return;
      sess.sent[key] = 1;
      tick(); push('milestone', { milestone: name, step: step }); flush();
    },
    flush: function () { flush(); },
    info: function () { return { game: CFG.game, visitorId: visitorId, sessionId: sess.id, elapsedMs: sess.elapsed, totalMs: profile.total, tester: tester, gated: gated }; }
  };
  log('ready', window.GameTracker.info());
})();
