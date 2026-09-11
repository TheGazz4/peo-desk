-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-11-user-grade-bar (#179)
-- Articles implemented: THE BAR IS A NUMBER, NOT A FEELING. Owner ruling, Mike, 2026-09-11:
--                       "user grade is 0 Red and 0 open tasks for at least 3 days consecutive."
--                       Recorded here so the finish line is measurable, dated, and cannot drift.
-- Articles verified not violated: this migration MEASURES; it changes no data, no lane, no gate.
--                       Nothing here can make a failing check pass. Sourcing never displayed;
--                       carrier internal-only; noncompete PEOs never worked.
-- Verification query attached: YES
--
-- WHY THIS EXISTS
-- Every previous attempt to say "is the platform healthy" compared numbers that were not comparable
-- or counted things nobody had defined. The owner has now set an explicit bar. This turns it into
-- one row: today passes or it does not, and how many consecutive days it has passed.
--
-- WHAT COUNTS AS AN OPEN TASK - stated plainly so it can be argued with:
--   COUNTED (work that is stuck and needs somebody to decide):
--     exception_desk open/escalated .............. cases the desk has not ruled on
--     attribution_adjudication needs_gazz ........ explicitly escalated to the owner
--     identity_adjudication quarantined .......... identities parked, no drain, oldest 2026-08-19
--     domain_resolution awaiting_adjudication .... evidence bought and never judged
--     source_alerts unacknowledged ............... alarms nobody has read
--   NOT COUNTED (work in flight by design):
--     want_board open ............................ the mesh asking itself questions. A live system
--                                                  always has some; zero here would mean the mesh
--                                                  had stopped thinking, not that it was healthy.
--     operator_holds .............................. the owner's own deliberate pauses.
-- If the owner disagrees with either exclusion, change this view - the bar lives here, in one place.

create or replace view public.v_user_grade_today as
with red as (
  select coalesce((
    select count(*) from sysaudit_log l
    join sysaudit_registry r on r.check_name = l.check_name
    where l.run_id = (select h.run_id from sysaudit_run_header h
                      where h.scope = 'all' order by h.ran_at desc limit 1)
      and l.status = 'FAIL' and r.severity = 'RED'), 0) as red_fails
),
tasks as (
  select
    (select count(*) from exception_desk where status in ('open','escalated'))                as desk_open,
    (select count(*) from attribution_adjudication_queue where status = 'needs_gazz')         as needs_owner,
    (select count(*) from identity_adjudication_queue where status = 'quarantined')           as identity_parked,
    (select count(*) from domain_resolution_queue where status = 'awaiting_adjudication')     as evidence_unjudged,
    (select count(*) from source_alerts where not coalesce(acknowledged,false))               as alerts_unread
)
select current_date                                    as as_of,
       r.red_fails,
       t.desk_open, t.needs_owner, t.identity_parked, t.evidence_unjudged, t.alerts_unread,
       (t.desk_open + t.needs_owner + t.identity_parked + t.evidence_unjudged + t.alerts_unread) as open_tasks,
       (r.red_fails = 0
        and t.desk_open + t.needs_owner + t.identity_parked + t.evidence_unjudged + t.alerts_unread = 0)
                                                       as passes_bar
from red r, tasks t;

comment on view public.v_user_grade_today is
 'Owner bar, 2026-09-11: user grade = 0 RED failing checks AND 0 open tasks, three consecutive days. One row: does today pass.';

-- A day only counts once, and only from a recorded observation - not from a live re-read that
-- could be taken at a convenient moment.
create table if not exists public.user_grade_day (
  as_of             date primary key,
  red_fails         int  not null,
  open_tasks        int  not null,
  desk_open         int,
  needs_owner       int,
  identity_parked   int,
  evidence_unjudged int,
  alerts_unread     int,
  passes_bar        boolean not null,
  observed_at       timestamptz not null default now()
);

alter table public.user_grade_day enable row level security;
drop policy if exists user_grade_day_read on public.user_grade_day;
create policy user_grade_day_read on public.user_grade_day for select
  to service_role, sysaudit_reader using (true);
grant select on public.user_grade_day to service_role, sysaudit_reader;

create or replace function public.user_grade_observe()
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare v record;
begin
  select * into v from public.v_user_grade_today;
  insert into public.user_grade_day
    (as_of, red_fails, open_tasks, desk_open, needs_owner, identity_parked,
     evidence_unjudged, alerts_unread, passes_bar)
  values (v.as_of, v.red_fails, v.open_tasks, v.desk_open, v.needs_owner,
          v.identity_parked, v.evidence_unjudged, v.alerts_unread, v.passes_bar)
  on conflict (as_of) do update set
    red_fails = excluded.red_fails, open_tasks = excluded.open_tasks,
    desk_open = excluded.desk_open, needs_owner = excluded.needs_owner,
    identity_parked = excluded.identity_parked,
    evidence_unjudged = excluded.evidence_unjudged, alerts_unread = excluded.alerts_unread,
    -- a day that ever failed stays failed: the streak cannot be rescued by a later re-read
    passes_bar = public.user_grade_day.passes_bar and excluded.passes_bar,
    observed_at = now();
  return to_jsonb(v);
end $$;

revoke all on function public.user_grade_observe() from public, anon, authenticated;
grant execute on function public.user_grade_observe() to service_role;

-- Consecutive passing days, counted back from today.
create or replace function public.user_grade_streak()
returns int
language sql
stable
as $$
  with d as (
    select as_of, passes_bar,
           (current_date - as_of) as days_back,
           row_number() over (order by as_of desc) - 1 as rn
    from public.user_grade_day
    where as_of <= current_date
  )
  select coalesce(count(*), 0)::int
  from d
  where passes_bar
    and days_back = rn
    and not exists (select 1 from d f where f.rn < d.rn and not f.passes_bar)
$$;

select cron.schedule('user_grade_observe', '11 10 * * *', 'select public.user_grade_observe()');

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'user_grade_bar', 'mechanical', 'XV.1', 'all', 'AMBER',
 'Owner bar set 2026-09-11: user grade is 0 RED failing checks and 0 open tasks, sustained three consecutive days. AMBER, not RED, on purpose - this check reports distance to the goal and must never itself become one of the REDs it is counting. Fails while the bar is not met.',
 'select red_fails, open_tasks from v_user_grade_today where not passes_bar',
 '{"mode":"zero_rows"}'::jsonb,
 'select 99::int as red_fails, 99::int as open_tasks'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('user_grade_day', 'table', 'audit',
        'One row per day recording whether the platform met the owner bar (0 RED, 0 open tasks). A day that ever failed stays failed, so the three-day streak cannot be rescued by a convenient re-read.',
        'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- VERIFICATION
-- select * from v_user_grade_today;
-- select user_grade_observe();
-- select user_grade_streak();   -- 0 today; must reach 3