-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-11-audit-scope-false-alarm (#176)
-- Articles implemented: LIKE IS COMPARED WITH LIKE. An audit run must record WHICH SCOPE it ran, so
--                       a run-over-run comparison cannot silently compare a 56-check fast run against
--                       a 212-check full run and call the difference a regression.
-- Articles verified not violated: sysaudit_run() itself is UNTOUCHED - the adopted auditor is wrapped,
--                       never modified; the wrapper returns the identical jsonb so the existing cron
--                       expression (sysaudit_run(...)->>'run_id') keeps working; read-only auditor
--                       path preserved; sourcing never displayed; noncompete PEOs never worked.
-- Verification query attached: YES
--
-- THE FALSE ALARM
-- 2026-09-11 09:59Z the pager fired: "8 -> 43 failing checks". Nothing widened. The 15-minute job
-- runs scope 'fast' = 56 checks and has failed 8 all day. The 09:59 job runs scope 'all' = 212
-- checks and failed 43. Two different populations.
-- Full-run history: 09-08 43/44/45, 09-09 41, 09-10 45, 09-11 43. Today is mid-range and DOWN from
-- yesterday while the check count went UP (207 -> 212, the five checks added by 0807).
-- Day over day, full run to full run: 3 checks FIXED (adopted_mesh_liveness, cron_last_run_failed,
-- domain_batch_submit), 1 NEW (migration_headers_recent).
--
-- WHY IT WILL FIRE AGAIN WITHOUT THIS
-- sysaudit_log has columns id, run_id, module, check_name, article, status, severity, observed,
-- ratified, executed_by, executed_at - and NO scope. Any comparator reading failure counts per
-- run_id is structurally unable to tell a fast run from a full one. It would page every single day
-- at 09:59 forever. Same defect class as the TX and FL liveness alarms: the signal measured the
-- wrong quantity.

create table if not exists public.sysaudit_run_header (
  run_id      uuid primary key,
  scope       text        not null,
  ran_at      timestamptz not null default now(),
  registered  int,
  passed      int,
  failed      int,
  warned      int,
  errored     int,
  info        int,
  elapsed_ms  int,
  balanced    boolean
);

comment on table public.sysaudit_run_header is
 'One row per sysaudit run, recording the SCOPE it ran. sysaudit_log carries no scope, so without this a comparator cannot tell a 56-check fast run from a 212-check full run - which is what produced the false 8 -> 43 page on 2026-09-11.';

create index if not exists ix_sysaudit_run_header_scope_time
  on public.sysaudit_run_header (scope, ran_at desc);

alter table public.sysaudit_run_header enable row level security;
drop policy if exists sysaudit_run_header_read on public.sysaudit_run_header;
create policy sysaudit_run_header_read on public.sysaudit_run_header for select
  to service_role, sysaudit_reader using (true);
grant select on public.sysaudit_run_header to service_role, sysaudit_reader;

-- The adopted auditor is WRAPPED, never edited.
create or replace function public.sysaudit_run_scoped(p_scope text default 'all')
returns jsonb
language plpgsql
as $$
declare v jsonb;
begin
  v := public.sysaudit_run(p_scope);
  begin
    insert into public.sysaudit_run_header
      (run_id, scope, registered, passed, failed, warned, errored, info, elapsed_ms, balanced)
    values (
      (v->>'run_id')::uuid,
      coalesce(v->>'scope', p_scope),
      nullif(v->>'registered','')::int, nullif(v->>'passed','')::int,
      nullif(v->>'failed','')::int,     nullif(v->>'warned','')::int,
      nullif(v->>'errored','')::int,    nullif(v->>'info','')::int,
      nullif(v->>'elapsed_ms','')::int, nullif(v->>'balanced','')::boolean)
    on conflict (run_id) do nothing;
  exception when others then
    -- the header is bookkeeping; it must never cost us the audit run itself
    insert into source_alerts (source_name, change_summary)
    values ('sysaudit_run_header', left('header write failed: '||sqlerrm, 300));
  end;
  return v;   -- identical shape: the cron's ->>'run_id' keeps working
end $$;

-- Backfill what can be known with certainty: scope is recoverable from the check count,
-- because the fast and full populations do not overlap in size.
insert into public.sysaudit_run_header (run_id, scope, ran_at, registered, failed)
select l.run_id,
       case when count(*) > 150 then 'all' else 'fast' end,
       min(l.executed_at),
       count(*),
       count(*) filter (where l.status = 'FAIL')
from public.sysaudit_log l
group by l.run_id
on conflict (run_id) do nothing;

-- What a comparator should read.
create or replace view public.v_sysaudit_run_history as
select h.run_id, h.scope, h.ran_at, h.registered, h.failed, h.warned, h.errored,
       lag(h.failed) over (partition by h.scope order by h.ran_at) as failed_prev_same_scope,
       h.failed - lag(h.failed) over (partition by h.scope order by h.ran_at) as delta_same_scope
from public.sysaudit_run_header h;

comment on view public.v_sysaudit_run_history is
 'Run history with the previous run OF THE SAME SCOPE alongside. delta_same_scope is the only honest run-over-run movement; comparing across scopes is meaningless.';

grant select on public.v_sysaudit_run_history to service_role, sysaudit_reader;

-- Point the crons at the wrapper. Same schedules, same timeouts, same escalation.
select cron.alter_job(jobid,
         command => 'set statement_timeout = ''240s''; select public.sysaudit_escalate((public.sysaudit_run_scoped(''fast'')->>''run_id'')::uuid);')
from cron.job where jobname = 'sysaudit_fast_15min';

select cron.alter_job(jobid,
         command => 'set statement_timeout = ''600s''; select public.sysaudit_escalate((public.sysaudit_run_scoped(''all'')->>''run_id'')::uuid);')
from cron.job where jobname = 'sysaudit_full_daily';

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'audit_run_scope_recorded', 'mechanical', 'XIV.1', 'all', 'RED',
 'Every audit run must record which scope it ran. sysaudit_log carries no scope column, so a run with no header row is a run whose failure count cannot honestly be compared to any other - the gap that produced the false 8 to 43 page on 2026-09-11. Fails on any run from the last 48 hours with no header.',
 'select distinct l.run_id from sysaudit_log l where l.executed_at > now() - interval ''48 hours'' and not exists (select 1 from sysaudit_run_header h where h.run_id = l.run_id)',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''00000000-0000-0000-0000-000000000000''::uuid as run_id'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('sysaudit_run_header', 'table', 'audit',
        'One row per audit run recording its scope and counts. Read by audit_run_scope_recorded and by v_sysaudit_run_history, which is what any pager should compare run over run.',
        'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- VERIFICATION
-- select scope, count(*), max(ran_at) from sysaudit_run_header group by 1;
-- select run_id, scope, failed, failed_prev_same_scope, delta_same_scope
--   from v_sysaudit_run_history order by ran_at desc limit 6;
-- select jobname, command from cron.job where jobname like 'sysaudit%';