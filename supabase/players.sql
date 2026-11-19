-- =====================================================================
--  플레이어별 · 구간별 분석 함수 (schema.sql 다음에 실행)
--  여러 번 실행해도 안전합니다.
--
--  "구간" = 한 지점(접속 또는 마일스톤)에 처음 도달한 순간부터
--           다음 지점에 처음 도달할 때까지 실제로 플레이한 시간.
--           다음 지점이 없으면 그 사람이 마지막으로 머문 = 나간 구간.
--  시간은 모두 누적 플레이 시간(total_ms) 기준이라
--  여러 번 나눠서 접속해도 구간 시간이 이어서 계산됩니다.
-- =====================================================================

-- 1. 플레이어 목록 (기간 안에 접속한 사람, 기록은 전체 기간 기준)
create or replace function public.analytics_players(p_game text, p_from timestamptz, p_to timestamptz, p_limit int default 2000)
returns table (
  visitor_id uuid, first_seen timestamptz, last_seen timestamptz, sessions bigint,
  total_ms bigint, max_step int, last_milestone text, last_segment_ms bigint,
  device text, referrer text, segments jsonb
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
           max(e.referrer) as referrer
    from e group by e.visitor_id
  )
  select a.visitor_id, a.first_seen, a.last_seen, a.sessions, a.total_ms, a.max_step,
         a.last_milestone, sj.last_seg, a.device, a.referrer, sj.segments
  from agg a join segj sj on sj.visitor_id = a.visitor_id
  order by a.last_seen desc
  limit least(greatest(p_limit, 1), 5000);
$$;

-- 2. 구간별 요약 : 몇 명이 들어왔고, 몇 명이 다음으로 갔고, 얼마나 머물렀나
create or replace function public.analytics_segments(p_game text, p_from timestamptz, p_to timestamptz)
returns table (
  step int, name text, entered bigint, moved_on bigint, exited bigint,
  median_sec numeric, median_moved_sec numeric, median_exited_sec numeric,
  avg_sec numeric, p90_sec numeric
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
           lead(p.t) over (partition by p.visitor_id order by p.t, p.step) as next_t
    from pts p
  ),
  d as (
    select s.step, s.name, s.next_t is not null as moved,
           greatest(coalesce(s.next_t, en.t) - s.t, 0) as ms
    from seg s join ends en on en.visitor_id = s.visitor_id
  )
  select d.step,
         mode() within group (order by d.name),
         count(*),
         count(*) filter (where d.moved),
         count(*) filter (where not d.moved),
         round((percentile_cont(0.5) within group (order by d.ms) / 1000.0)::numeric, 0),
         round((percentile_cont(0.5) within group (order by d.ms) filter (where d.moved) / 1000.0)::numeric, 0),
         round((percentile_cont(0.5) within group (order by d.ms) filter (where not d.moved) / 1000.0)::numeric, 0),
         round(avg(d.ms) / 1000.0, 0),
         round((percentile_cont(0.9) within group (order by d.ms) / 1000.0)::numeric, 0)
  from d
  group by d.step
  order by d.step;
$$;

-- 3. 플레이어 한 명의 전체 기록
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
    'total_ms', (select max(e.total_ms) from events e where e.game_id = p_game and e.visitor_id = p_visitor)
  );
$$;

revoke execute on function public.analytics_players(text, timestamptz, timestamptz, int) from public, anon;
revoke execute on function public.analytics_segments(text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_player_detail(text, uuid) from public, anon;
grant execute on function public.analytics_players(text, timestamptz, timestamptz, int) to authenticated;
grant execute on function public.analytics_segments(text, timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_player_detail(text, uuid) to authenticated;

-- 플레이어 기록 조회를 빠르게
create index if not exists events_game_visitor_type_idx on public.events (game_id, visitor_id, event_type);
