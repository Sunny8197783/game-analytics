-- =====================================================================
--  베타 테스터 입장 코드 (schema.sql, players.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
-- =====================================================================

-- 1. 테스터 명단 : 관리자만 보고 만들 수 있음
create table if not exists public.testers (
  code       text primary key check (code ~ '^[A-Z0-9]{4}-[A-Z0-9]{4}$'),
  name       text not null check (char_length(name) between 1 and 60),
  memo       text check (char_length(memo) <= 300),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- 2. 입장 시도 기록 (성공·실패 모두)
create table if not exists public.tester_entries (
  id         bigint generated always as identity primary key,
  code       text not null check (char_length(code) <= 20),
  game_id    text not null check (game_id ~ '^[a-z0-9_-]{1,40}$'),
  visitor_id uuid not null,
  ok         boolean not null,
  created_at timestamptz not null default now()
);
create index if not exists tester_entries_code_idx on public.tester_entries (code, created_at);

-- 3. 게임 기록에 테스터 코드 칸 추가
alter table public.events add column if not exists tester_code text
  check (tester_code ~ '^[A-Z0-9]{4}-[A-Z0-9]{4}$');
create index if not exists events_tester_idx on public.events (tester_code) where tester_code is not null;
grant insert (tester_code) on public.events to anon, authenticated;

-- 4. 보안 규칙
alter table public.testers enable row level security;
alter table public.tester_entries enable row level security;
revoke all on public.testers from anon, authenticated;
revoke all on public.tester_entries from anon, authenticated;
grant select, insert, delete on public.testers to authenticated;
grant update (name, memo, active) on public.testers to authenticated;
grant select on public.tester_entries to authenticated;

drop policy if exists "admins manage testers" on public.testers;
create policy "admins manage testers" on public.testers
  for all to authenticated
  using (exists (select 1 from public.admins a where a.user_id = (select auth.uid())))
  with check (exists (select 1 from public.admins a where a.user_id = (select auth.uid())));

drop policy if exists "admins read entries" on public.tester_entries;
create policy "admins read entries" on public.tester_entries
  for select to authenticated
  using (exists (select 1 from public.admins a where a.user_id = (select auth.uid())));

-- 5. 게임이 부르는 코드 확인 함수
--    명단은 게임(anon)이 직접 못 읽으므로 이 함수만 권한을 빌려 확인하고,
--    맞는지 여부와 이름만 돌려줍니다.
create or replace function public.verify_tester(p_code text, p_game text, p_visitor uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c text;
  v_code text; v_name text; v_active boolean;
begin
  c := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if char_length(c) <> 8 or coalesce(p_game, '') !~ '^[a-z0-9_-]{1,40}$' or p_visitor is null then
    return jsonb_build_object('ok', false);
  end if;
  c := substr(c, 1, 4) || '-' || substr(c, 5, 4);
  select t.code, t.name, t.active into v_code, v_name, v_active
  from public.testers t where t.code = c;
  insert into public.tester_entries (code, game_id, visitor_id, ok)
  values (c, p_game, p_visitor, coalesce(v_active, false));
  if v_code is null or not v_active then
    return jsonb_build_object('ok', false, 'reason', case when v_code is null then 'unknown' else 'inactive' end);
  end if;
  return jsonb_build_object('ok', true, 'code', v_code, 'name', v_name);
end;
$$;
revoke execute on function public.verify_tester(text, text, uuid) from public;
grant execute on function public.verify_tester(text, text, uuid) to anon, authenticated;

-- 6. 세션 요약에 테스터 코드 추가
create or replace view public.session_summary
with (security_invoker = true) as
select
  e.game_id, e.session_id, e.visitor_id,
  min(e.created_at) as started_at,
  max(e.created_at) as last_seen_at,
  max(e.elapsed_ms) as dwell_ms,
  max(e.step) filter (where e.event_type = 'milestone') as max_step,
  (array_agg(e.milestone order by e.step desc nulls last, e.created_at desc)
     filter (where e.event_type = 'milestone'))[1] as last_milestone,
  max(e.device) as device,
  max(e.referrer) as referrer,
  max(e.tester_code) as tester_code
from public.events e
group by e.game_id, e.session_id, e.visitor_id;

-- 7. 플레이어 목록에 테스터 표시 (반환 칸이 바뀌어서 지우고 다시 만듦)
drop function if exists public.analytics_players(text, timestamptz, timestamptz, int);
create function public.analytics_players(p_game text, p_from timestamptz, p_to timestamptz, p_limit int default 2000)
returns table (
  visitor_id uuid, first_seen timestamptz, last_seen timestamptz, sessions bigint,
  total_ms bigint, max_step int, last_milestone text, last_segment_ms bigint,
  device text, referrer text, segments jsonb, tester_code text, tester_name text
)
language sql stable security invoker set search_path = public as $$
  with v as (
    select distinct s.visitor_id from session_summary s
    where s.game_id = p_game and s.started_at >= p_from and s.started_at < p_to
  ),
  e as (
    select ev.* from events ev join v on v.visitor_id = ev.visitor_id
    where ev.game_id = p_game
  ),
  pts as (
    select v.visitor_id, 0 as step, '접속'::text as name, 0::bigint as t from v
    union all
    select e.visitor_id, e.step, (array_agg(e.milestone order by e.created_at))[1], min(e.total_ms)
    from e where e.event_type = 'milestone' and e.step > 0
    group by e.visitor_id, e.step
  ),
  ends as (select e.visitor_id, max(e.total_ms) as t from e group by 1),
  seg as (
    select p.visitor_id, p.step, p.name, p.t,
           lead(p.t) over (partition by p.visitor_id order by p.t, p.step) as next_t,
           row_number() over (partition by p.visitor_id order by p.t, p.step) as ord
    from pts p
  ),
  segj as (
    select s.visitor_id,
           jsonb_agg(jsonb_build_object(
             'step', s.step, 'name', s.name, 'at_ms', s.t,
             'ms', greatest(coalesce(s.next_t, en.t) - s.t, 0),
             'exit', s.next_t is null) order by s.ord) as segments,
           max(case when s.next_t is null then greatest(en.t - s.t, 0) end) as last_seg
    from seg s join ends en on en.visitor_id = s.visitor_id
    group by s.visitor_id
  ),
  agg as (
    select e.visitor_id, min(e.created_at) as first_seen, max(e.created_at) as last_seen,
           count(distinct e.session_id) as sessions, max(e.total_ms) as total_ms,
           max(e.step) filter (where e.event_type = 'milestone' and e.step > 0) as max_step,
           (array_agg(e.milestone order by e.total_ms desc, e.created_at desc)
              filter (where e.event_type = 'milestone' and e.step > 0))[1] as last_milestone,
           mode() within group (order by e.device) as device,
           max(e.referrer) as referrer,
           (array_agg(e.tester_code order by e.created_at desc) filter (where e.tester_code is not null))[1] as tester_code
    from e group by e.visitor_id
  )
  select a.visitor_id, a.first_seen, a.last_seen, a.sessions, a.total_ms, a.max_step,
         a.last_milestone, sj.last_seg, a.device, a.referrer, sj.segments,
         a.tester_code, t.name
  from agg a
  join segj sj on sj.visitor_id = a.visitor_id
  left join testers t on t.code = a.tester_code
  order by a.last_seen desc
  limit least(greatest(p_limit, 1), 5000);
$$;
revoke execute on function public.analytics_players(text, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.analytics_players(text, timestamptz, timestamptz, int) to authenticated;

-- 8. 최근 접속 목록에도 테스터 표시
drop function if exists public.analytics_sessions(text, timestamptz, timestamptz, int);
create function public.analytics_sessions(p_game text, p_from timestamptz, p_to timestamptz, p_limit int default 100)
returns table (session_id uuid, visitor_id uuid, started_at timestamptz, dwell_sec numeric,
               last_milestone text, max_step int, device text, visit_no bigint,
               tester_code text, tester_name text)
language sql stable security invoker set search_path = public as $$
  select s.session_id, s.visitor_id, s.started_at, round(s.dwell_ms / 1000.0, 0),
         s.last_milestone, s.max_step, s.device,
         row_number() over (partition by s.visitor_id order by s.started_at),
         s.tester_code, t.name
  from session_summary s
  left join testers t on t.code = s.tester_code
  where s.game_id = p_game and s.started_at < p_to
  order by s.started_at desc
  limit least(greatest(p_limit, 1), 500);
$$;
revoke execute on function public.analytics_sessions(text, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.analytics_sessions(text, timestamptz, timestamptz, int) to authenticated;

-- 9. 테스터별 게임 기록
create or replace function public.analytics_testers()
returns table (
  code text, name text, memo text, active boolean, created_at timestamptz,
  games jsonb, ok_entries bigint, failed_entries bigint, last_seen timestamptz, total_ms bigint
)
language sql stable security invoker set search_path = public as $$
  with pv as (
    select e.tester_code as code, e.game_id, e.visitor_id,
           max(e.total_ms) as total_ms, min(e.created_at) as first_at, max(e.created_at) as last_at,
           count(distinct e.session_id) as sessions,
           max(e.step) filter (where e.event_type = 'milestone' and e.step > 0) as max_step,
           (array_agg(e.milestone order by e.total_ms desc, e.created_at desc)
              filter (where e.event_type = 'milestone' and e.step > 0))[1] as last_ms
    from events e
    where e.tester_code is not null
    group by 1, 2, 3
  ),
  pg as (
    select pv.code, pv.game_id, sum(pv.total_ms)::bigint as total_ms, min(pv.first_at) as first_at,
           max(pv.last_at) as last_at, sum(pv.sessions)::bigint as sessions, max(pv.max_step) as max_step,
           (array_agg(pv.last_ms order by pv.last_at desc) filter (where pv.last_ms is not null))[1] as last_ms,
           count(*) as devices,
           jsonb_agg(pv.visitor_id order by pv.last_at desc) as visitors
    from pv group by 1, 2
  )
  select t.code, t.name, t.memo, t.active, t.created_at,
         coalesce((select jsonb_agg(jsonb_build_object(
                    'game_id', pg.game_id, 'total_ms', pg.total_ms, 'first_at', pg.first_at,
                    'last_at', pg.last_at, 'sessions', pg.sessions, 'max_step', pg.max_step,
                    'last_milestone', pg.last_ms, 'devices', pg.devices, 'visitors', pg.visitors)
                    order by pg.last_at desc)
                   from pg where pg.code = t.code), '[]'::jsonb),
         (select count(*) from tester_entries x where x.code = t.code and x.ok),
         (select count(*) from tester_entries x where x.code = t.code and not x.ok),
         (select max(pg.last_at) from pg where pg.code = t.code),
         (select sum(pg.total_ms) from pg where pg.code = t.code)::bigint
  from testers t
  order by t.created_at desc, t.code;
$$;
revoke execute on function public.analytics_testers() from public, anon;
grant execute on function public.analytics_testers() to authenticated;

-- 10. 명단에 없는 코드로 들어오려 한 기록 (오타·공유 의심)
create or replace function public.analytics_bad_codes(p_from timestamptz, p_to timestamptz)
returns table (code text, game_id text, tries bigint, visitors bigint, last_at timestamptz)
language sql stable security invoker set search_path = public as $$
  select x.code, x.game_id, count(*), count(distinct x.visitor_id), max(x.created_at)
  from tester_entries x
  where not x.ok and x.created_at >= p_from and x.created_at < p_to
  group by 1, 2
  order by max(x.created_at) desc
  limit 200;
$$;
revoke execute on function public.analytics_bad_codes(timestamptz, timestamptz) from public, anon;
grant execute on function public.analytics_bad_codes(timestamptz, timestamptz) to authenticated;

-- 11. 플레이어 상세에 테스터 정보 추가
create or replace function public.analytics_player_detail(p_game text, p_visitor uuid)
returns jsonb
language sql stable security invoker set search_path = public as $$
  select jsonb_build_object(
    'sessions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'session_id', s.session_id, 'started_at', s.started_at, 'last_seen_at', s.last_seen_at,
               'dwell_ms', s.dwell_ms, 'device', s.device, 'referrer', s.referrer,
               'start_total_ms', (select min(x.total_ms) from events x where x.session_id = s.session_id))
             order by s.started_at)
      from session_summary s where s.game_id = p_game and s.visitor_id = p_visitor), '[]'::jsonb),
    'milestones', coalesce((
      select jsonb_agg(jsonb_build_object(
               'session_id', e.session_id, 'step', e.step, 'name', e.milestone,
               'elapsed_ms', e.elapsed_ms, 'total_ms', e.total_ms, 'at', e.created_at)
             order by e.created_at)
      from events e
      where e.game_id = p_game and e.visitor_id = p_visitor
        and e.event_type = 'milestone' and e.step > 0), '[]'::jsonb),
    'total_ms', (select max(e.total_ms) from events e where e.game_id = p_game and e.visitor_id = p_visitor),
    'tester_code', (select e.tester_code from events e where e.game_id = p_game and e.visitor_id = p_visitor
                      and e.tester_code is not null order by e.created_at desc limit 1),
    'tester_name', (select t.name from testers t where t.code = (
                      select e.tester_code from events e where e.game_id = p_game and e.visitor_id = p_visitor
                        and e.tester_code is not null order by e.created_at desc limit 1))
  );
$$;
