-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-cron-congestion (#166)
-- Articles implemented: CRON CONGESTION LAW. The scheduler has a finite number of worker slots.
--                       No minute of the hour may be scheduled beyond that capacity, and recurring
--                       */N families must be spread across their own window instead of all landing
--                       on the same boundary minute.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; no job's FREQUENCY
--                       is changed - only its phase within the interval.
-- Verification query attached: YES
--
-- DIAGNOSIS
-- 157 active cron jobs against cron.max_running_jobs = 32.
-- Minute 0 of every hour was scheduled by: 15 fixed-minute-0 jobs + 13 */15 + 11 */5 + 5 */10
-- + 5 */30 + 4 */20 + the */1 and */2 families = well over 50 jobs competing for 32 slots.
-- Every failure carried the same message: "job startup timeout". Nothing was broken; the scheduler
-- simply could not hand out workers fast enough. ~70 failures in an hour, all at :00/:05/:10/:15/:20.
-- Frequency is preserved exactly. Only the PHASE moves: a */15 job still runs 4 times an hour,
-- just at :03/:18/:33/:48 instead of :00/:15/:30/:45.

-- 1. MINUTE-FIELD READER ----------------------------------------------------
create or replace function public.cron_minute_field_matches(p_field text, p_min int)
returns boolean
language plpgsql
immutable
as $$
declare part text; a int; b int; n int;
begin
  foreach part in array string_to_array(btrim(p_field), ',') loop
    part := btrim(part);
    if part = '*' then
      return true;
    elsif part ~ '^\*/\d+$' then
      n := substring(part from '^\*/(\d+)$')::int;
      if n > 0 and p_min % n = 0 then return true; end if;
    elsif part ~ '^\d+-\d+/\d+$' then
      a := substring(part from '^(\d+)-')::int;
      b := substring(part from '^\d+-(\d+)/')::int;
      n := substring(part from '/(\d+)$')::int;
      if n > 0 and p_min between a and b and (p_min - a) % n = 0 then return true; end if;
    elsif part ~ '^\d+-\d+$' then
      a := substring(part from '^(\d+)-')::int;
      b := substring(part from '-(\d+)$')::int;
      if p_min between a and b then return true; end if;
    elsif part ~ '^\d+$' then
      if p_min = part::int then return true; end if;
    end if;
  end loop;
  return false;
end $$;

-- 2. LOAD METER -------------------------------------------------------------
create or replace function public.cron_minute_load()
returns table (minute_of_hour int, jobs_scheduled bigint, slot_capacity int)
language sql
stable
security definer
set search_path to 'public','cron','extensions'
as $$
  select m.minute_of_hour,
         count(j.jobid) as jobs_scheduled,
         coalesce(nullif(current_setting('cron.max_running_jobs', true), '')::int, 32) as slot_capacity
  from generate_series(0, 59) as m(minute_of_hour)
  left join cron.job j
    on j.active
   and public.cron_minute_field_matches(split_part(j.schedule, ' ', 1), m.minute_of_hour)
  group by m.minute_of_hour
  order by m.minute_of_hour
$$;

revoke all on function public.cron_minute_load() from public, anon, authenticated;
grant execute on function public.cron_minute_load() to service_role, sysaudit_reader;

-- 3. STAGGER THE */N FAMILIES ----------------------------------------------
-- Deterministic phase from the job id, so the spread is stable and repeatable.
do $$
declare r record; n int; k int; new_min text;
begin
  for r in
    select jobid, jobname, schedule, split_part(schedule,' ',1) as m
    from cron.job
    where active and split_part(schedule,' ',1) ~ '^\*/\d+$'
  loop
    n := substring(r.m from '^\*/(\d+)$')::int;
    continue when n <= 1;
    k := r.jobid % n;
    new_min := k::text || '-59/' || n::text;
    perform cron.alter_job(
      job_id   => r.jobid,
      schedule => new_min || ' ' || substring(r.schedule from position(' ' in r.schedule) + 1)
    );
  end loop;
end $$;

-- 4. STANDING LAW -----------------------------------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'cron_minute_congestion', 'mechanical', 'XII.1', 'all', 'RED',
 'No minute of the hour may be scheduled with more jobs than the scheduler has worker slots. When it is, pg_cron hands back "job startup timeout" and pumps silently miss ticks - which is what produced roughly 70 failures across 24 jobs on 2026-09-08. Fails at 90 percent of capacity so the pile-up is caught before it starts dropping work.',
 'select minute_of_hour, jobs_scheduled, slot_capacity from cron_minute_load() where jobs_scheduled > (slot_capacity * 0.9)',
 '{"mode":"zero_rows"}'::jsonb,
 'select 0::int as minute_of_hour, 99::bigint as jobs_scheduled, 32::int as slot_capacity'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

reset role;

-- VERIFICATION
-- select * from cron_minute_load() order by jobs_scheduled desc limit 5;   -- peak must fall under 29
-- select count(*) from cron.job_run_details where status='failed'
--   and return_message = 'job startup timeout' and start_time > now() - interval '15 minutes';