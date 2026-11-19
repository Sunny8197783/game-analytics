-- =====================================================================
--  게임 분석 DB 스키마 (Supabase / Postgres 15+)
--  Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run 하세요.
--  여러 번 실행해도 안전합니다 (idempotent).
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. 이벤트 테이블 : 게임이 보내는 모든 기록 (insert only)
-- ---------------------------------------------------------------------
create table if not exists public.events (
  id          bigint generated always as identity primary key,
  game_id     text        not null check (game_id ~ '^[a-z0-9_-]{1,40}$'),
  visitor_id  uuid        not null,           -- 브라우저마다 고정 (localStorage)
  session_id  uuid        not null,           -- 접속 1회마다 새로 발급
  event_type  text        not null check (event_type in ('session_start','heartbeat','milestone','session_end')),
  milestone   text        check (char_length(milestone) <= 60),
  step        int         check (step between 0 and 10000),
  elapsed_ms  int         not null default 0 check (elapsed_ms between 0 and 86400000),  -- 이번 세션 실제 플레이 시간
  total_ms    bigint      not null default 0 check (total_ms between 0 and 3600000000),  -- 이 사람의 이 게임 누적 플레이 시간
  device      text        check (device in ('mobile','tablet','desktop')),
  referrer    text        check (char_length(referrer) <= 300),
  created_at  timestamptz not null default now()
);

create index if not exists events_game_time_idx    on public.events (game_id, created_at);
create index if not exists events_session_idx      on public.events (session_id);
create index if not exists events_game_visitor_idx on public.events (game_id, visitor_id);

-- ---------------------------------------------------------------------
-- 2. 관리자 테이블 : 대시보드를 볼 수 있는 계정
-- ---------------------------------------------------------------------
create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- ---------------------------------------------------------------------
-- 3. 권한 + RLS
--    게임(anon)  : events 에 INSERT 만 가능. 읽기·수정·삭제 불가.
--    관리자 로그인 : events 읽기 가능 (admins 에 등록된 계정만)
-- ---------------------------------------------------------------------
alter table public.events enable row level security;
alter table public.admins enable row level security;

revoke all on public.events from anon, authenticated;
revoke all on public.admins from anon, authenticated;

-- id, created_at 은 서버가 채움 → 클라이언트가 조작 불가
grant insert (game_id, visitor_id, session_id, event_type, milestone, step,
              elapsed_ms, total_ms, device, referrer)
  on public.events to anon, authenticated;
grant select on public.events to authenticated;
grant select on public.admins to authenticated;

drop policy if exists "games can insert events" on public.events;
create policy "games can insert events" on public.events
  for insert to anon, authenticated
  with check (true);

drop policy if exists "admins can read events" on public.events;
create policy "admins can read events" on public.events
  for select to authenticated
  using (exists (select 1 from public.admins a where a.user_id = (select auth.uid())));

drop policy if exists "admin can see own row" on public.admins;
create policy "admin can see own row" on public.admins
  for select to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 4. 세션 요약 뷰 (security_invoker → RLS 그대로 적용)
--    세션 1개 = 1행 : 시작시각, 체류시간, 도달한 최고 마일스톤
-- ---------------------------------------------------------------------
create or replace view public.session_summary
with (security_invoker = true) as
select
  e.game_id,
  e.session_id,
  e.visitor_id,
  min(e.created_at)                                   as started_at,
  max(e.created_at)                                   as last_seen_at,
  max(e.elapsed_ms)                                   as dwell_ms,
  max(e.step) filter (where e.event_type = 'milestone') as max_step,
  (array_agg(e.milestone order by e.step desc nulls last, e.created_at desc)
     filter (where e.event_type = 'milestone'))[1]    as last_milestone,
  max(e.device)                                       as device,
  max(e.referrer)                                     as referrer
from public.events e
group by e.game_id, e.session_id, e.visitor_id;

revoke all on public.session_summary from anon;
grant select on public.session_summary to authenticated;

-- ---------------------------------------------------------------------
-- 5. 분석 함수 (대시보드가 RPC 로 호출)
--    모두 SECURITY INVOKER → 관리자만 결과가 나옴 (그 외엔 빈 결과)
--    p_game 이 null 이면 전체 게임
-- ---------------------------------------------------------------------

-- 5-1. 게임별 개요
create or replace function public.analytics_overview(p_from timestamptz, p_to timestamptz)
returns table (
  game_id text, visitors bigint, sessions bigint, returning_visitors bigint,
  new_visitors bigint, avg_dwell_sec numeric, median_dwell_sec numeric,
  total_play_hours numeric, top_drop_milestone text
)
language sql stable security invoker set search_path = public as $$
  with s as (
    select * from session_summary
    where started_at >= p_from and started_at < p_to
  ),
  per_visitor as (
    select game_id, visitor_id, count(*) as n from s group by 1, 2
  ),
  first_seen as (
    select e.game_id, e.visitor_id, min(e.created_at) as first_at
    from events e
    where e.event_type = 'session_start'
    group by 1, 2
  ),
  -- 이 기간 이 사람의 '마지막 도달 지점' = 이탈 지점
  visitor_last as (
    select distinct on (game_id, visitor_id) game_id, visitor_id, last_milestone
    from s
    order by game_id, visitor_id, max_step desc nulls last, started_at desc
  ),
  drops as (
    select distinct on (game_id) game_id, coalesce(last_milestone, '(마일스톤 전 이탈)') as top_drop
    from (select game_id, last_milestone, count(*) c from visitor_last group by 1, 2) x
    order by game_id, c desc
  )
  select
    s.game_id,
    count(distinct s.visitor_id),
    count(*),
    (select count(*) from per_visitor pv where pv.game_id = s.game_id and pv.n >= 2),
    (select count(*) from first_seen f where f.game_id = s.game_id and f.first_at >= p_from and f.first_at < p_to),
    round(avg(s.dwell_ms) / 1000.0, 1),
    round((percentile_cont(0.5) within group (order by s.dwell_ms) / 1000.0)::numeric, 1),
    round(sum(s.dwell_ms) / 3600000.0, 2),
    (select d.top_drop from drops d where d.game_id = s.game_id)
  from s
  group by s.game_id
  order by count(distinct s.visitor_id) desc;
$$;

-- 5-2. 일별 추이 (한국 시간 기준 날짜)
create or replace function public.analytics_daily(p_game text, p_from timestamptz, p_to timestamptz)
returns table (day date, visitors bigint, sessions bigint, avg_dwell_sec numeric)
language sql stable security invoker set search_path = public as $$
  select (started_at at time zone 'Asia/Seoul')::date,
         count(distinct visitor_id), count(*),
         round(avg(dwell_ms) / 1000.0, 1)
  from session_summary
  where (p_game is null or game_id = p_game)
    and started_at >= p_from and started_at < p_to
  group by 1 order by 1;
$$;

-- 5-3. 마일스톤 퍼널 : 몇 명이 도달했고, 몇 명이 여기서 멈췄나
create or replace function public.analytics_funnel(p_game text, p_from timestamptz, p_to timestamptz)
returns table (step int, milestone text, visitors_reached bigint, visitors_dropped bigint,
               median_total_min numeric)
language sql stable security invoker set search_path = public as $$
  with ss as (
    select session_id, visitor_id from session_summary
    where game_id = p_game and started_at >= p_from and started_at < p_to
  ),
  ms as (   -- 이 기간 세션에서 발생한 마일스톤 (사람별 첫 도달)
    select e.visitor_id, e.step, e.milestone, min(e.total_ms) as total_ms
    from events e join ss on ss.session_id = e.session_id
    where e.game_id = p_game and e.event_type = 'milestone'
    group by 1, 2, 3
  ),
  labels as (   -- step 하나에 이름이 여러 개면 가장 많이 쓰인 이름
    select distinct on (step) step, milestone
    from (select step, milestone, count(*) c from ms group by 1, 2) x
    order by step, c desc
  ),
  maxstep as (
    select v.visitor_id, max(ms.step) as max_step
    from (select distinct visitor_id from ss) v
    left join ms on ms.visitor_id = v.visitor_id
    group by v.visitor_id
  )
  select 0, '접속'::text,
         (select count(*) from maxstep),
         (select count(*) from maxstep where max_step is null),
         null::numeric
  union all
  select l.step, l.milestone,
         (select count(distinct m.visitor_id) from ms m where m.step = l.step),
         (select count(*) from maxstep x where x.max_step = l.step),
         (select round((percentile_cont(0.5) within group (order by m.total_ms) / 60000.0)::numeric, 1)
            from ms m where m.step = l.step)
  from labels l
  order by 1;
$$;

-- 5-4. 체류시간 분포
create or replace function public.analytics_dwell_hist(p_game text, p_from timestamptz, p_to timestamptz)
returns table (bucket_order int, bucket text, sessions bigint)
language sql stable security invoker set search_path = public as $$
  with b(o, label, lo, hi) as (values
    (1,'30초 미만',0,30000),(2,'30초–1분',30000,60000),(3,'1–3분',60000,180000),
    (4,'3–5분',180000,300000),(5,'5–10분',300000,600000),(6,'10–20분',600000,1200000),
    (7,'20–40분',1200000,2400000),(8,'40분 이상',2400000,2147483647))
  select b.o, b.label, count(s.session_id)
  from b left join session_summary s
    on s.dwell_ms >= b.lo and s.dwell_ms < b.hi
   and (p_game is null or s.game_id = p_game)
   and s.started_at >= p_from and s.started_at < p_to
  group by b.o, b.label order by b.o;
$$;

-- 5-5. 방문 횟수 분포 (같은 사람이 몇 번 들어왔나)
create or replace function public.analytics_visit_freq(p_game text, p_from timestamptz, p_to timestamptz)
returns table (bucket_order int, bucket text, visitors bigint)
language sql stable security invoker set search_path = public as $$
  with n as (
    select visitor_id, count(*) c from session_summary
    where (p_game is null or game_id = p_game)
      and started_at >= p_from and started_at < p_to
    group by 1
  ),
  b(o, label, lo, hi) as (values (1,'1회',1,2),(2,'2회',2,3),(3,'3–5회',3,6),(4,'6–10회',6,11),(5,'11회 이상',11,2147483647))
  select b.o, b.label, count(n.visitor_id)
  from b left join n on n.c >= b.lo and n.c < b.hi
  group by b.o, b.label order by b.o;
$$;

-- 5-6. 최근 세션 목록
create or replace function public.analytics_sessions(p_game text, p_from timestamptz, p_to timestamptz, p_limit int default 100)
returns table (session_id uuid, visitor_id uuid, started_at timestamptz, dwell_sec numeric,
               last_milestone text, max_step int, device text, visit_no bigint)
language sql stable security invoker set search_path = public as $$
  select s.session_id, s.visitor_id, s.started_at, round(s.dwell_ms / 1000.0, 0),
         s.last_milestone, s.max_step, s.device,
         row_number() over (partition by s.visitor_id order by s.started_at)
  from session_summary s
  where s.game_id = p_game and s.started_at < p_to
  order by s.started_at desc
  limit least(greatest(p_limit, 1), 500);
$$;

revoke execute on function public.analytics_overview(timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_daily(text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_funnel(text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_dwell_hist(text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_visit_freq(text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.analytics_sessions(text, timestamptz, timestamptz, int) from public, anon;
grant execute on function public.analytics_overview(timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_daily(text, timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_funnel(text, timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_dwell_hist(text, timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_visit_freq(text, timestamptz, timestamptz) to authenticated;
grant execute on function public.analytics_sessions(text, timestamptz, timestamptz, int) to authenticated;

-- ---------------------------------------------------------------------
-- 6. 관리자 등록 (계정 만든 뒤 한 번만 실행)
--    Authentication > Users 에서 내 계정을 만들고, 아래 이메일을 바꿔 실행하세요.
-- ---------------------------------------------------------------------
-- insert into public.admins (user_id)
-- select id from auth.users where email = 'me@example.com'
-- on conflict do nothing;
