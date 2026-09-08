-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: checks_have_authored_selftests / selftest_staleness - a check that has
--   never been proven to fire is not a check
-- Articles verified not violated: none; registry row only
-- Verification query attached: YES

-- 0781  peo_profile_law (0772) was registered with a vacuous selftest
--       ("select 1 where false"), so sysaudit_selftest reported NOT PROVEN: the
--       check had never been shown to fail on a violating shape. Authored one
--       that returns the violating shape, matching the convention used by
--       peo_name_law and shelf_conformance.

set role peo_gatekeeper;

update public.sysaudit_registry
set selftest_sql = $q$select 'synthetic_family' as family_slug, 7 as clients$q$
where check_name = 'peo_profile_law';

reset role;

do $verify$
declare v jsonb; v_proved boolean;
begin
  select public.sysaudit_selftest() into v;
  select (elem->>'proved')::boolean into v_proved
  from jsonb_array_elements(v->'detail') elem
  where elem->>'check' = 'peo_profile_law';
  if v_proved is not true then
    raise exception '0781 verification: peo_profile_law selftest still not proven';
  end if;
  raise notice '0781 OK: peo_profile_law selftest proven, not_proved=%', v->>'not_proved';
end $verify$;