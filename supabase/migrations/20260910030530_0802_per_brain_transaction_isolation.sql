-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-brain-worker-split-and-isolation (#168)
-- Articles implemented: BRAIN ISOLATION LAW. Each hub brain runs in its OWN transaction, on its OWN
--                       cron slot, under its OWN statement timeout. One slow or failing brain can no
--                       longer roll back another's receipt or consume another's time.
--                       Every live brain must hold a scheduled slot - a brain that loses its slot is
--                       a silent brain, and silence is not evidence of health (XI.1).
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; gatekeeper ownership
--                       preserved; no change to what any brain does, only to how it is invoked.
-- Verification query attached: YES
--
-- WHY THE PREVIOUS ATTEMPT FAILED (0798, withdrawn in 0799)
-- Setting statement_timeout inside run_hub_brains() does nothing: the timeout is measured against the
-- OUTERMOST statement, so a brain invoked by EXECUTE never sees it. tx_wc ran 54.8s against a
-- declared 20s budget and reported success. The only way to give a brain its own timeout is to make
-- it its own top-level statement. That is what this does.
--
-- The monolithic 'hub_brains' job (one transaction, 15 brains, 50s) is retired. run_hub_brains()
-- is KEPT as a manual all-at-once entry point; it simply no longer runs on cron.

set role peo_gatekeeper;

create or replace function public.run_one_hub_brain(p_hub text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare
  v_fn text; t0 timestamptz := clock_timestamp(); v_ms int; v_ans int := 0;
begin
  select brain_fn into v_fn from data_hubs
   where hub_slug = p_hub and status = 'live' and brain_fn is not null;
  if v_fn is null then
    return jsonb_build_object('hub', p_hub, 'skipped', 'not a live hub with a brain');
  end if;

  begin
    execute format('select %I()', v_fn);
    v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
    insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok)
    values (p_hub, v_fn, v_ms, true);
  exception when others then
    v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
    insert into hub_brain_runs (hub_slug, brain_fn, duration_ms, ok, err)
    values (p_hub, v_fn, v_ms, false, left(sqlerrm, 300));
    insert into source_alerts (source_name, change_summary)
    values ('hub_brain:'||p_hub, left(sqlerrm, 300));
  end;

  begin
    v_ans := hub_brain_answer_wants(p_hub);
  exception when others then
    insert into source_alerts (source_name, change_summary)
    values ('want_answer:'||p_hub, left(sqlerrm, 300));
  end;

  return jsonb_build_object('hub', p_hub, 'brain_fn', v_fn,
                            'duration_ms', v_ms, 'wants_answered', coalesce(v_ans,0));
end $$;

revoke all on function public.run_one_hub_brain(text) from public, anon, authenticated;
grant execute on function public.run_one_hub_brain(text) to service_role;

reset role;

-- ONE SLOT PER BRAIN, spread across the hour, off the congested boundary ----
do $$
declare r record; v_min int; v_job text;
begin
  for r in
    select hub_slug, row_number() over (order by hub_slug) rn
    from data_hubs where status='live' and brain_fn is not null
  loop
    v_min := 2 + ((r.rn - 1) * 4) % 58;
    v_job := 'hub_brain_' || replace(replace(r.hub_slug, ':', '_'), '-', '_');
    begin perform cron.unschedule(v_job); exception when others then null; end;
    perform cron.schedule(
      v_job,
      v_min || ' * * * *',
      format('set statement_timeout = ''30s''; select public.run_one_hub_brain(%L)', r.hub_slug)
    );
  end loop;
end $$;

-- the shared tail of the old monolith gets its own slot too
select cron.schedule('mesh_apply_ein_answers', '34 * * * *', 'select public.mesh_apply_ein_answers()');

-- retire the monolith (the FUNCTION stays, as a manual all-at-once entry point)
do $$ begin perform cron.unschedule('hub_brains'); exception when others then null; end $$;

-- tx_wc no longer needs its debt budget: 40,337ms -> 564ms once the worker moved out (0801)
delete from public.hub_brain_budget where hub_slug = 'tx_wc';

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'hub_brain_scheduled', 'mechanical', 'XII.3', 'all', 'RED',
 'Every live hub with a brain must hold an active cron slot of its own. A brain with no slot never runs, produces no receipt, and looks exactly like a healthy quiet hub - silence is not evidence of health. Catches a slot dropped by hand, by a rename, or by a migration that unscheduled more than it meant to.',
 'select h.hub_slug from data_hubs h where h.status = ''live'' and h.brain_fn is not null and not exists (select 1 from cron.job j where j.active and j.command like ''%run_one_hub_brain%'' and j.command like ''%''''''||h.hub_slug||''''''%'')',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz_unscheduled''::text as hub_slug'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

reset role;

-- VERIFICATION
-- select jobname, schedule from cron.job where command like '%run_one_hub_brain%' order by jobname;   -- 15 rows, distinct minutes
-- select select run_one_hub_brain('tx_wc');
-- select * from cron_minute_load() order by jobs_scheduled desc limit 3;   -- peak still under 29
-- select h.hub_slug from data_hubs h where h.status='live' and h.brain_fn is not null
--   and not exists (select 1 from cron.job j where j.active and j.command like '%run_one_hub_brain%'
--                   and j.command like '%'''||h.hub_slug||'''%');          -- empty