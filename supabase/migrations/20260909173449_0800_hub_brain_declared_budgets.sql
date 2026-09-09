-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-09-hub-brain-timeout (#167)
-- Articles implemented: DECLARED BUDGET LAW - same shape as the intake parity law. A hub that needs
--                       more than the default budget must DECLARE it with a written basis; a hub that
--                       drifts past what it declared fails RED. Silence gets the strict default.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; client street
--                       addresses never displayed; noncompete PEOs never worked; RLS on new tables;
--                       semantic role drawn from the permitted vocabulary.
-- Verification query attached: YES
--
-- Fixing hub_brain_seed exposed the real shape of the problem: hub_brain_tx_wc is not a reporter at
-- all. It builds temp tables, matches names, renames companies and answers wants - 40s of work every
-- hour under the label "brain". A flat 15s budget would just sit red forever and teach everyone to
-- ignore it. So the budget is declared per hub, with a basis, and the exception is written down as
-- an exception instead of being absorbed silently.

create table if not exists public.hub_brain_budget (
  hub_slug    text primary key,
  budget_ms   integer not null default 15000,
  basis       text    not null,
  declared_at timestamptz not null default now()
);

comment on table public.hub_brain_budget is
 'Per-hub time budget for its brain. Hubs with no row here are held to the 15s default. A larger budget must carry a written basis - it is an admission of debt, not a free pass.';

alter table public.hub_brain_budget enable row level security;
drop policy if exists hub_brain_budget_read on public.hub_brain_budget;
create policy hub_brain_budget_read on public.hub_brain_budget for select
  to service_role, sysaudit_reader using (true);
grant select on public.hub_brain_budget to service_role, sysaudit_reader;

insert into public.hub_brain_budget (hub_slug, budget_ms, basis) values
('tx_wc', 45000,
 'DEBT, NOT DESIGN. hub_brain_tx_wc is worker-shaped: it builds temp tables, matches arch names, renames companies and answers wants inside the hourly brain slot. Measured 54.8s before the LCF index (0799), 40.3s after. Budget set just above current cost so any further drift fails immediately. The fix is to split the worker out of the brain, not to keep raising this number.'),
('peo_intel', 15000,
 'Standard reporter budget. Measured 7.3s - roughly half its budget, and worth watching.')
on conflict (hub_slug) do update
  set budget_ms = excluded.budget_ms, basis = excluded.basis, declared_at = now();

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'hub_brain_time_budget', 'mechanical', 'XII.2', 'all', 'RED',
 'Every live hub brain must have succeeded on its most recent run and finished inside its declared budget - 15 seconds by default, or whatever hub_brain_budget declares with a written basis. This is the early warning that a reporter is drifting toward the timeout that killed the hub_brains cron on 2026-09-09, when hub_brain_seed applied the noncompete regex gate to 196,917 rows.',
 'select h.hub_slug, x.duration_ms, coalesce(b.budget_ms, 15000) as budget_ms, x.ok, left(coalesce(x.err,''''),120) as err from data_hubs h join lateral (select * from hub_brain_runs r where r.hub_slug = h.hub_slug order by r.ran_at desc limit 1) x on true left join hub_brain_budget b on b.hub_slug = h.hub_slug where h.status = ''live'' and h.brain_fn is not null and (x.ok = false or x.duration_ms > coalesce(b.budget_ms, 15000))',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz''::text as hub_slug, 99999::int as duration_ms, 15000::int as budget_ms, false as ok, ''selftest''::text as err'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('hub_brain_budget', 'table', 'registry',
        'Per-hub declared time budget for its brain, with the basis for any budget above the 15s default. Read by hub_brain_time_budget.', 'peo_gatekeeper'),
       ('hub_brain_runs', 'table', 'audit',
        'Per-brain execution record: duration, success, error. Written by run_hub_brains, read by hub_brain_time_budget.', 'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- VERIFICATION
-- select * from hub_brain_budget;
-- select count(*) from data_hubs h join lateral (select * from hub_brain_runs r where r.hub_slug=h.hub_slug order by r.ran_at desc limit 1) x on true
--   left join hub_brain_budget b on b.hub_slug=h.hub_slug
--  where h.status='live' and h.brain_fn is not null and (x.ok=false or x.duration_ms > coalesce(b.budget_ms,15000));  -- 0