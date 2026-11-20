-- 베타 테스터 30명 코드 만들기 (테스터 01 ~ 30). 이미 있으면 건너뜀.
insert into public.testers (code, name)
select substr(c, 1, 4) || '-' || substr(c, 5, 4), '테스터 ' || lpad(i::text, 2, '0')
from (
  select i, (select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
             from generate_series(1, 8) g where i > 0) as c
  from generate_series(1, 30) i
) x
where not exists (select 1 from public.testers t where t.name = '테스터 ' || lpad(x.i::text, 2, '0'))
on conflict do nothing;
