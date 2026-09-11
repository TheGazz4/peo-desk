-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-11-ai-caller-registry (#174)
-- Articles implemented: the registry records VERIFIED state, never a report. Every row changed here
--                       was re-read from the deployed source by me, not accepted from a summary.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; noncompete PEOs
--                       never worked; no lane's behaviour changes beyond the gates deployed today.
-- Verification query attached: YES
--
-- CORRECTION AGAINST MYSELF: 0807 recorded attr-adjudicate as BLIND on the strength of a scan
-- summary. It is NOT. I checked the function body for 'api_spend_ledger' and 'decisions', saw
-- neither, and concluded the cost was discarded - but attr_adjudication_apply() writes the cost to
-- brain_judgments.cost_usd, which platform_spend_mtd() reads. The cost was visible all along. The
-- claim was wrong and is corrected here rather than quietly dropped.
--
-- FIXES DEPLOYED TODAY, each verified against the function source before editing:
--   peo-identity-resolve v5 - was genuinely BLIND: wrote api_spend_ledger columns provider/context
--     that do not exist, omitted module, inside catch(_){}. Now books through log_brain_spend
--     (one priced door) and reports a failed write to edge_debug.
--   lcf-adjudicate v2, calibrate-one v2, calibrate-two v2 - each called a paid model with NO budget
--     check. Cost was visible via decisions.cost_cents, but visibility is not a cap: all three would
--     have kept spending after the governor closed. Each now calls brain_spend_ok() first and checks
--     its cost write instead of ignoring the result.

update public.ai_caller_registry set
  cost_path = 'brain_judgments', is_blind = false,
  ruling = 'CORRECTION 2026-09-11: 0807 recorded this as blind on a scan summary. Re-read: attr_adjudication_apply writes cost to brain_judgments.cost_usd, which platform_spend_mtd reads. Never blind.',
  verified_at = now(), verified_by = 'reread-2026-09-11',
  note = 'cost booked inside attr_adjudication_apply, not in the edge function'
where fn_slug = 'attr-adjudicate';

update public.ai_caller_registry set
  cost_path = 'api_spend_ledger', cost_module = 'peo-identity-resolve', is_blind = false,
  verified_at = now(), verified_by = 'deploy-v5-2026-09-11',
  note = 'v5: books via log_brain_spend; failed write reported to edge_debug (was blind through v4)'
where fn_slug = 'peo-identity-resolve';

update public.ai_caller_registry set
  budget_gated = true, gate_fn = 'brain_spend_ok',
  verified_at = now(), verified_by = 'deploy-v2-2026-09-11',
  note = 'v2: brain_spend_ok gate added; decisions insert result now checked'
where fn_slug in ('lcf-adjudicate', 'calibrate-one', 'calibrate-two');

-- VERIFICATION
-- select fn_slug from ai_caller_registry where calls_llm and is_blind and ruling is null;          -- 0
-- select fn_slug from ai_caller_registry where calls_llm and not budget_gated and ruling is null;  -- 0
-- select count(*) from ai_caller_registry where calls_llm and is_blind;                            -- 0