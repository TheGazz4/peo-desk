-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-mep-sponsor-adjudication
-- Articles implemented: least privilege on SECURITY DEFINER surface (map_reader_fence)
-- Articles verified not violated: map_reader must never gain execute
-- Verification query attached: YES

-- 0767  promote_initial_attribution is SECURITY DEFINER owned by peo_gatekeeper,
--       so the canonicaliser must be executable BY peo_gatekeeper. PUBLIC and
--       map_reader stay revoked (0764).

grant execute on function public.canonical_mep_sponsor_slug(text) to peo_gatekeeper;
grant execute on function public.canonical_mep_sponsor_slug(text) to service_role;

do $verify$
begin
  if has_function_privilege('map_reader','public.canonical_mep_sponsor_slug(text)','execute') then
    raise exception '0767 verification: map_reader can execute the canonicaliser';
  end if;
  if not has_function_privilege('peo_gatekeeper','public.canonical_mep_sponsor_slug(text)','execute') then
    raise exception '0767 verification: peo_gatekeeper cannot execute the canonicaliser';
  end if;
  raise notice '0767 OK';
end $verify$;