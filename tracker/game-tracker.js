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
    debug: ds.debug === 'true'
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
    if (document.visibilityState === 'visible' && t - lastInput < CFG.idleMs && !ended) {
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
    info: function () { return { game: CFG.game, visitorId: visitorId, sessionId: sess.id, elapsedMs: sess.elapsed, totalMs: profile.total }; }
  };
  log('ready', window.GameTracker.info());
})();
