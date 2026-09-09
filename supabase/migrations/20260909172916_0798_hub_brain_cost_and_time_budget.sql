-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-09-hub-brain-timeout (#167)
-- Articles implemented: HUB BRAIN COST LAW. A hub brain is a REPORTER, not a worker: it must run
--                       inside a time budget, an expensive gate must be applied to the smallest set
--                       possible, and one slow brain must never take the whole run down with it.
-- Articles verified not violated: noncompete protection is UNCHANGED in strength - company_is_noncompete
--                       still gates every row, it is simply evaluated after the cheap filters instead
--                       of before; sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked, profiled or appended.
-- Verification query attached: YES
--
-- DIAGNOSIS
-- hub_brains cron failed at 15:50 and 16:50 UTC with "canceling statement due to statement timeout"
-- inside is_noncompete_peo, called from hub_brain_seed. Cause: the backlog count applied
-- company_is_noncompete() - which calls is_noncompete_peo() up to 6 times, each scanning the
-- 5-row pattern table - to all 196,917 companies carrying a seed PEO string. Roughly 5.9 million
-- regex evaluations every hour.
-- The cheap part of that same query (the seed-observation anti-join) runs in 130 ms and leaves 251 rows.
-- Nothing regressed; the seed backfill simply grew the corpus until the hourly reporter no longer fit.

-- 1. PRICE THE GATE so the planner defers it everywhere, not just here.
alter function public.is_noncompete_peo(text)              cost 500;
alter function public.company_is_noncompete(public.companies) cost 5000;

-- 2. APPLY THE GATE LAST -----------------------------------------------------
-- Same rows, same protection, evaluated on 251 candidates instead of 196,917.
create or replace function public.hub_brain_seed()
returns jsonb
language sql
stable
security definer
set search_path to 'public','pg_temp'
as $function$
  with cheap as materialized (
    select c.*
    from companies c
    where c.merged_into is null
      and nullif(btrim(c.peo_original), '') is not null
      and not exists (select 1 from field_observations o
                      where o.company_id = c.id
                        and o.source_hub like 'seed:%'
                        and o.field_name = 'peo_name')
  )
  select jsonb_build_object(
    'hub','seed',
    'kind','static vendor file - no polling; reports coverage of what the seed already delivered',
    'records_with_seed_peo', (select count(*) from companies c
        where c.merged_into is null and nullif(btrim(c.peo_original),'') is not null),
    'with_observation', (select count(distinct o.company_id) from field_observations o
        where o.source_hub like 'seed:%' and o.field_name='peo_name'),
    'backlog', (select count(*) from cheap c where not company_is_noncompete(c)),
    'backlog_withheld_noncompete', (select count(*) from cheap c where company_is_noncompete(c)),
    'at', now());
$function$;

-- 3. ONE SLOW BRAIN MUST NOT KILL THE RUN -----------------------------------
create table if not exists public.hub_brain_runs (
  id          bigserial primary key,
  hub_slug    text        not null,
  brain_fn    text        not null,
  ran_at      timestamptz not null default now(),
  duration_ms integer,
  ok          boolean     not null,
  err         text
);
create index if not exists ix_hub_brain_runs_recent on public.hub_brain_runs (hub_slug, ran_at desc);
alter table public.hub_brain_runs enable row level security;
drop policy if exists hub_brain_runs_read on public.hub_brain_runs;
create policy hub_brain_runs_read on public.hub_brain_runs for select
  to service_role, sysaudit_reader using (true);
grant select on public.hub_brain_runs to service_role, sysaudit_reader;

create or replace function public.run_hub_brains()
returns void
language plpgsql
as $function$
declare
  r record; v int := 0; v_ans int := 0; v_ans_total int := 0; v_applied int := 0;
  t0 timestamptz; v_ms int;
begin
  for r in select hub_slug, brain_fn from data_hubs where brain_fn is not null and status='live'
  loop
    t0 := clock_timestamp();
    begin
      -- per-brain budget: a reporter that cannot answer in 20s is a defect, not a wait.
      set local statement_timeout = '20s';
      execute format('select %I()', r.brain_fn);
      v := v + 1;
      v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
      insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok)
      values (r.hub_slug, r.brain_fn, v_ms, true);
    exception when others then
      v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
      insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok, err)
      values (r.hub_slug, r.brain_fn, v_ms, false, left(sqlerrm, 300));
      insert into source_alerts (source_name, change_summary)
      values ('hub_brain:'||r.hub_slug, left(sqlerrm, 300));
    end;
    begin
      set local statement_timeout = '20s';
      v_ans := hub_brain_answer_wants(r.hub_slug);
      v_ans_total := v_ans_total + coalesce(v_ans, 0);
    exception when others then
      insert into source_alerts (source_name, change_summary)
      values ('want_answer:'||r.hub_slug, left(sqlerrm, 300));
    end;
  end loop;

  begin
    set local statement_timeout = '60s';
    v_applied := mesh_apply_ein_answers();
  exception when others then
    insert into source_alerts (source_name, change_summary)
    values ('mesh_apply_ein_answers', left(sqlerrm, 300));
  end;

  reset statement_timeout;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brains', gen_random_uuid(), now(), now(), true,
    jsonb_build_object('brains_run', v, 'wants_answered', v_ans_total,
                       'ein_applied', v_applied, 'rail', 'mandate2_0305'));
end $function$;

-- 4. STANDING LAW -----------------------------------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'hub_brain_time_budget', 'mechanical', 'XII.2', 'all', 'RED',
 'A hub brain is a reporter, not a worker. Its most recent run must have succeeded and must have finished inside the 20 second budget. Fails when a live hub brain last errored or last took more than 15 seconds - the early warning that a reporter is drifting toward the timeout that killed the hub_brains cron on 2026-09-09, when hub_brain_seed applied the noncompete regex gate to 196,917 rows.',
 'select h.hub_slug, x.duration_ms, x.ok, left(coalesce(x.err,''''),120) as err from data_hubs h join lateral (select * from hub_brain_runs b where b.hub_slug = h.hub_slug order by b.ran_at desc limit 1) x on true where h.status = ''live'' and h.brain_fn is not null and (x.ok = false or x.duration_ms > 15000)',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz''::text as hub_slug, 99999::int as duration_ms, false as ok, ''selftest''::text as err'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

reset role;

-- VERIFICATION
-- select hub_brain_seed();                       -- returns in well under a second
-- select run_hub_brains();
-- select hub_slug, duration_ms, ok from hub_brain_runs order by ran_at desc limit 20;