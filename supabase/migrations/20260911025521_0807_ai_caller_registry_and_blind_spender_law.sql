-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-11-ai-caller-registry (#174)
-- Articles implemented: NO BLIND SPENDER. Every function that can call a paid model must be
--                       registered, must gate on the budget governor BEFORE the call, and must land
--                       its cost in a table the governor reads (api_spend_ledger, brain_judgments,
--                       decisions). A caller that cannot be seen cannot be capped - precisely what
--                       cost $7,495 in August 2026, when the governor was blind to 63% of spend.
--                       A model with no published price may not be billed at a guessed rate.
-- Articles verified not violated: no lane's behaviour or output changes; this migration records facts
--                       and installs checks. edge_function_inventory is sealed (no INSERT granted to
--                       anyone) and is therefore READ, never written, here. Sourcing never displayed;
--                       carrier internal-only; noncompete PEOs never worked.
-- Verification query attached: YES
--
-- METHOD: all 82 deployed edge functions were read, in full, on 2026-09-11. 19 call a paid model.
-- The other 63 are recorded as clean so the next audit starts from evidence, not a guess.
--
-- WHAT THE SCAN FOUND
--   BLIND (cost never reaches the governor):
--     peo-identity-resolve - writes api_spend_ledger columns `provider`/`context` that DO NOT EXIST,
--                            inside catch(_){}. Identical bug to serper-hub-drain v3, fixed 09-10.
--     attr-adjudicate      - computes cost, passes p_cost to attr_adjudication_apply(), and that
--                            function THROWS IT AWAY: writes neither api_spend_ledger nor decisions.
--   UNGATED (no budget check before the call):
--     calibrate-one, calibrate-two, lcf-adjudicate - all three call a model with no gate at all.
--   UNDER-COUNTED:
--     log_brain_spend() silently billed any unpriced model at a flat $0.05. Fable is $20/$100 per
--     Mtok; a model missing from brain_cost_rates could be under-counted by orders of magnitude.
--   EXPENSIVE MODEL STILL REACHABLE:
--     entity-resolve, research-director and brain-judgment can each route to claude-fable-5
--     ($20 in / $100 out per Mtok - 20x Haiku). Fable mis-routing was the single $1,007 line in the
--     August incident. All three are budget-gated and sit behind operator holds, so this is recorded
--     as a standing risk with a required ruling, not a live leak.

create table if not exists public.ai_caller_registry (
  fn_slug         text primary key,
  calls_llm       boolean not null,
  models          text[]  not null default '{}',
  cost_path       text    not null,
  cost_module     text,
  budget_gated    boolean not null default false,
  gate_fn         text,
  is_blind        boolean not null default false,
  can_reach_fable boolean not null default false,
  ruling          text,
  verified_at     timestamptz not null default now(),
  verified_by     text    not null,
  note            text
);

comment on table public.ai_caller_registry is
 'One row per deployed edge function, recording whether it can call a paid model and - if so - how its cost reaches the spend governor and whether it checks the budget first. Blind or ungated without a written ruling is a RED failure.';

alter table public.ai_caller_registry enable row level security;
drop policy if exists ai_caller_registry_read on public.ai_caller_registry;
create policy ai_caller_registry_read on public.ai_caller_registry for select
  to service_role, sysaudit_reader using (true);
grant select on public.ai_caller_registry to service_role, sysaudit_reader;

insert into public.ai_caller_registry
  (fn_slug, calls_llm, models, cost_path, cost_module, budget_gated, gate_fn, is_blind, can_reach_fable, ruling, verified_by, note) values
('serper-enrich', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'serper-enrich', true, 'brain_spend_ok', false, false, null, 'scan-2026-09-11', 'max_tokens 600; clean'),
('domain-resolve', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'domain-resolve', true, 'brain_spend_ok', false, false, null, 'scan-2026-09-11', 'direct insert, unwrapped'),
('domain-batch-submit', true, '{claude-haiku-4-5-20251001}', 'deferred:domain-batch-poll', 'domain-batch', true, 'brain_spend_ok', false, false, 'Batches API: tokens are only known at retrieval, so the poller books the cost. Poller verified to write module domain-batch.', 'scan-2026-09-11', 'submit side books nothing by design'),
('domain-batch-poll', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'domain-batch', true, 'n/a-retrieval-only', false, false, 'Retrieval makes no model call; it books the batch cost at batch+cache rates.', 'scan-2026-09-11', 'cache-aware rates'),
('serper-hub-drain', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'peo_reviews', true, 'brain_spend_ok', false, false, null, 'scan-2026-09-11', 'was blind until v4 (2026-09-10)'),
('brain-judgment', true, '{claude-haiku-4-5-20251001,claude-sonnet-4-6,claude-fable-5}', 'brain_judgments', null, true, 'brain_spend_ok', false, true, 'Tier is chosen by the caller; mesh_desk_triage now pins haiku. Fable reachable only by explicit min_tier.', 'scan-2026-09-11', 'governor reads brain_judgments'),
('dash-ai', true, '{claude-haiku-4-5-20251001,claude-sonnet-4-6}', 'api_spend_ledger', 'dash_ai', true, 'brain_spend_ok', false, false, null, 'scan-2026-09-11', 'max 4 model calls per question'),
('map-data', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'map_ai', true, 'pub.ai_gate', false, false, null, 'scan-2026-09-11', 'via pub.log_map_ai_spend -> log_brain_spend'),
('sonnet-escalate', true, '{claude-sonnet-4-6}', 'api_spend_ledger', 'sonnet-escalate', true, 'brain_spend_ok', false, false, 'Sonnet is the point of this lane; it is held and Gazz-gated.', 'scan-2026-09-11', 'operator hold since 2026-08-13'),
('entity-resolve', true, '{claude-haiku-4-5-20251001,claude-sonnet-4-6,claude-fable-5}', 'api_spend_ledger', 'entity-resolve', true, 'brain_spend_ok', false, true, 'Held since 2026-08-13 pending Gazz go. Fable tier must be reviewed before release.', 'scan-2026-09-11', 'token defaults 2000/500 if usage absent'),
('research-director', true, '{claude-fable-5,claude-haiku-4-5-20251001}', 'api_spend_ledger', 'research-director', true, 'brain_spend_ok', false, true, 'Held since 2026-08-13 pending Gazz go. Fable tier must be reviewed before release.', 'scan-2026-09-11', 'token fallback 6000/1500 inflates estimate'),
('narrate', true, '{claude-haiku-4-5-20251001}', 'api_spend_ledger', 'narrate', true, 'brain_spend_ok', false, false, null, 'scan-2026-09-11', 'gate once per invocation, not per company'),
('dol-attachment-harvest', true, '{claude-sonnet-4-6}', 'api_spend_ledger', 'dol-vision-extract', true, 'brain_spend_ok', false, false, 'Vision extraction genuinely needs Sonnet; 4 calls lifetime, $1.18.', 'scan-2026-09-11', 'insert in swallowed catch'),
('adjudicate', true, '{claude-sonnet-4-6}', 'decisions', null, true, 'daily_brain_spend', false, false, 'Uses its own hardcoded 500-cent/24h cap rather than the platform governor. Cost IS visible: platform_spend_mtd reads decisions.', 'scan-2026-09-11', 'own cap, not brain_spend_ok'),
('peo-identity-resolve', true, '{claude-haiku-4-5-20251001}', 'BLIND', null, true, 'brain_spend_ok', true, false, null, 'scan-2026-09-11', 'writes provider/context columns that do not exist, in catch(_){}'),
('attr-adjudicate', true, '{claude-haiku-4-5-20251001}', 'BLIND', null, true, 'brain_spend_ok', true, false, null, 'scan-2026-09-11', 'passes p_cost to attr_adjudication_apply which discards it'),
('calibrate-one', true, '{claude-sonnet-4-6}', 'decisions', null, false, null, false, false, null, 'scan-2026-09-11', 'NO budget gate; unchecked insert; stale price constants'),
('calibrate-two', true, '{claude-sonnet-4-6}', 'decisions', null, false, null, false, false, null, 'scan-2026-09-11', 'NO budget gate; unchecked insert; stale price constants'),
('lcf-adjudicate', true, '{claude-haiku-4-5-20251001}', 'decisions', null, false, null, false, false, null, 'scan-2026-09-11', 'NO budget gate; unchecked insert')
on conflict (fn_slug) do update set
  calls_llm=excluded.calls_llm, models=excluded.models, cost_path=excluded.cost_path,
  cost_module=excluded.cost_module, budget_gated=excluded.budget_gated, gate_fn=excluded.gate_fn,
  is_blind=excluded.is_blind, can_reach_fable=excluded.can_reach_fable, ruling=excluded.ruling,
  verified_at=now(), verified_by=excluded.verified_by, note=excluded.note;

insert into public.ai_caller_registry (fn_slug, calls_llm, cost_path, verified_by, note)
select s, false, 'n/a', 'scan-2026-09-11', 'read in full 2026-09-11: no LLM endpoint'
from unnest(array[
 'bulk-load-5500','loader','bulk-load-quarantine','resolve','seed-load','hq-apply','loc-apply',
 'tx-wc-probe','tx-lcf-extract','tx-wc-extract-generic','web-probe','tx-own-policy-probe',
 'efast-ingest','efast-sch-a','source-watch','ncci-class-ingest','ca-sos-inspect','ca-sos-load',
 'tx-wc-pump','efast-pump','repo-backup','repo-commit','tx-roster-order','ca-sos-segment',
 'gh-bootstrap','web-fingerprint-study','key-sentinel','exhaust-crawl','exhaust-wayback',
 'desk-api','desk-publish','desk','repo-read','lane-dispatch','cal-probe','cal-webhook',
 'evidence-harvest','fl-dwc-pump','fl-ingest','fl-poc-lookup','serper-prefetch',
 'serper-enrich-prefetch','drive-fetch','xlsx-probe','az-xlsx-segment','az-ncci-load','az-sign',
 'dol-bulk-probe','dol-index-probe','dol-index-pump','dol-index-diag','dol-image-fetch',
 'fl-upload','fl-xlsx-convert','logo-harvest','geo-backfill','fl-sign','fl-xlsx-stage',
 'fl-xlsx-rows','review-data','fl-inbox-promote','fl-page','ny-poc-probe'
]) s
on conflict (fn_slug) do nothing;

-- ---- an unpriced model must not be billed at a guess ---------------------
create or replace function public.log_brain_spend(p_module text, p_model text, p_in integer, p_out integer, p_note text default null::text)
returns numeric
language plpgsql
as $function$
declare v_cost numeric; v_rate numeric; v_rated boolean;
begin
  select round((p_in::numeric/1000000)*usd_per_mtok_in + (p_out::numeric/1000000)*usd_per_mtok_out, 4)
  into v_cost from brain_cost_rates where model = p_model;
  v_rated := v_cost is not null;

  if not v_rated then
    -- The old behaviour billed ANY unknown model at a flat $0.05. claude-fable-5 is $20/$100 per
    -- Mtok; a mis-routed unpriced model could be under-counted by orders of magnitude and the
    -- governor would never notice. Fall back LOUDLY, and price it at the most expensive rate we
    -- know so the estimate errs high, never low.
    select max(greatest(usd_per_mtok_in, usd_per_mtok_out)) into v_rate from brain_cost_rates;
    v_cost := round((p_in + p_out)::numeric / 1000000 * coalesce(v_rate, 100), 4);
    insert into source_alerts (source_name, change_summary)
    values ('unpriced_model',
      format('log_brain_spend saw unpriced model %L from module %L - billed at the highest known rate (est $%s). Add it to brain_cost_rates.', p_model, p_module, v_cost));
  end if;

  insert into api_spend_ledger (module, model, input_tokens, output_tokens, est_cost_usd, note)
  values (p_module, p_model, p_in, p_out, v_cost,
          case when v_rated then p_note
               else coalesce(p_note,'') || ' [UNPRICED MODEL - billed at highest known rate]' end);
  return v_cost;
end $function$;

-- ---- STANDING LAW --------------------------------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'ai_caller_blind', 'mechanical', 'XIII.1', 'all', 'RED',
 'No function may call a paid model without its cost landing in a table the spend governor reads. A blind spender cannot be capped - the governor was blind to 63 percent of spend in the August 2026 incident that cost $7,495. Fails on any registered LLM caller whose cost_path is BLIND and which carries no written ruling.',
 'select fn_slug, cost_path, note from ai_caller_registry where calls_llm and is_blind and ruling is null',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz-fn''::text as fn_slug, ''BLIND''::text as cost_path, ''selftest''::text as note'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'ai_caller_ungated', 'mechanical', 'XIII.2', 'all', 'RED',
 'Every function that calls a paid model must check the budget governor BEFORE the call. A cap consulted by only some callers is not a cap. Fails on any registered LLM caller with no budget gate and no written ruling.',
 'select fn_slug, models, note from ai_caller_registry where calls_llm and not budget_gated and ruling is null',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz-fn''::text as fn_slug, array[''zz-model'']::text[] as models, ''selftest''::text as note'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'ai_caller_unregistered', 'mechanical', 'XIII.3', 'all', 'RED',
 'Every edge function the platform inventories must be recorded in ai_caller_registry as either a paid-model caller or not.',
 'select i.slug from edge_function_inventory i where not exists (select 1 from ai_caller_registry r where r.fn_slug = i.slug)',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz-unregistered''::text as slug'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'ai_caller_registry_stale', 'mechanical', 'XIII.3', 'all', 'RED',
 'The paid-model scan must be re-run at least every 30 days. SQL cannot see which edge functions are deployed, so a NEW function calling a model is invisible to every other check here until someone re-reads the fleet. This staleness clock is what forces that re-read instead of trusting a snapshot forever.',
 'select max(verified_at)::text as last_full_scan from ai_caller_registry having max(verified_at) < now() - interval ''30 days''',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''1999-01-01''::text as last_full_scan'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'ai_model_unpriced', 'mechanical', 'XIII.4', 'all', 'RED',
 'Every model billed to the spend ledger must have a published price in brain_cost_rates. An unpriced model is estimated, and an estimate the governor trusts is how a 20x model hides inside a Haiku budget.',
 'select distinct l.model from api_spend_ledger l where l.model is not null and not exists (select 1 from brain_cost_rates b where b.model = l.model)',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz-unpriced-model''::text as model'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('ai_caller_registry', 'table', 'registry',
        'Every deployed edge function and whether it can call a paid model, with its verified cost path and budget gate. Read by ai_caller_blind, ai_caller_ungated, ai_caller_unregistered and ai_caller_registry_stale.',
        'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- VERIFICATION
-- select fn_slug from ai_caller_registry where calls_llm and is_blind and ruling is null;          -- must reach 0
-- select fn_slug from ai_caller_registry where calls_llm and not budget_gated and ruling is null;  -- must reach 0
-- select count(*) from ai_caller_registry where calls_llm;                                         -- 19
-- select count(*) from ai_caller_registry;                                                         -- 82