-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: door grant parity - a gatekeeper-owned door is executable by service_role only,
--                       matching apply_peo_profile_field and backfill_seed_observations.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; noncompete PEOs never worked.
-- Verification query attached: YES

set role peo_gatekeeper;
grant execute on function public.promote_fl_raw_coverage(int) to service_role;
reset role;

-- VERIFICATION
-- select proacl::text from pg_proc where proname='promote_fl_raw_coverage';
--   -> {peo_gatekeeper=X/peo_gatekeeper,service_role=X/peo_gatekeeper}