-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: current-client gate (client_is_current) applied wherever a surface counts
--   current clients; least privilege on SECURITY DEFINER surface
-- Articles verified not violated: none; this tightens two checks I broke today
-- Verification query attached: YES

-- 0780  Two failures I introduced today, closed at the core.
--   1. v_peo_profile_freshness (0770) counted current clients with a bare
--      peo_current test instead of the ratified client_is_current() gate, so
--      current_client_gate_bypassed went RED. The gate exists precisely so
--      staleness decays an attribution; a profile want must obey it too.
--   2. run_precedence_sweep_chunk (0778) was created owned by peo_gatekeeper
--      but its REVOKEs ran after RESET ROLE, so they silently did nothing and
--      PUBLIC kept EXECUTE - tripping map_reader_fence, secdef_public_execute,
--      secdef_anon_execute and prediction_wall_intact (peo_predictor inherited
--      execute on a SECURITY DEFINER function that writes field_observations).
--      Same lesson as 0748/0761: a revoke on a gatekeeper-owned function must
--      run AS the gatekeeper.

create or replace view public.v_peo_profile_freshness as
select f.family_slug,
       r.field_name,
       r.required_tier,
       r.displayable,
       r.refresh_days,
       (p.field_provenance ? r.field_name) as has_provenance,
       (p.field_provenance -> r.field_name ->> 'as_of')::date as as_of,
       (p.field_provenance -> r.field_name ->> 'source_hub') as source_hub,
       case
         when p.family_slug is null then 'no_profile'
         when not (p.field_provenance ? r.field_name) then 'never_sourced'
         when r.refresh_days is null then 'fresh'
         when (p.field_provenance -> r.field_name ->> 'as_of')::date
              < current_date - r.refresh_days then 'stale'
         else 'fresh'
       end as freshness,
       (select count(*) from public.companies c
         where c.merged_into is null
           and c.peo_family_slug = f.family_slug
           and c.peo_current
           and public.client_is_current(c.attribution_class, c.latest_intel_at, c.created_at)
       ) as current_clients
from (select distinct family_slug from public.peo_families) f
cross join public.peo_profile_field_registry r
left join public.peo_profiles p on p.family_slug = f.family_slug
where not public.is_noncompete_peo(f.family_slug);

comment on view public.v_peo_profile_freshness is
  '0770/0780: one row per PEO family x registered field. freshness = no_profile | never_sourced | stale | fresh. current_clients passes the ratified client_is_current() staleness gate, so a want is only raised for a family whose book is actually live.';

set role peo_gatekeeper;
revoke all on function public.run_precedence_sweep_chunk(int) from public;
revoke all on function public.run_precedence_sweep_chunk(int) from map_reader;
reset role;

do $verify$
begin
  if pg_get_viewdef('public.v_peo_profile_freshness'::regclass) not like '%client_is_current%' then
    raise exception '0780 verification: the current-client gate is still bypassed in the view';
  end if;
  if has_function_privilege('public','public.run_precedence_sweep_chunk(integer)','execute') then
    raise exception '0780 verification: PUBLIC can still execute the chunked sweep';
  end if;
  if has_function_privilege('map_reader','public.run_precedence_sweep_chunk(integer)','execute') then
    raise exception '0780 verification: map_reader can execute the chunked sweep';
  end if;
  if has_function_privilege('peo_predictor','public.run_precedence_sweep_chunk(integer)','execute') then
    raise exception '0780 verification: peo_predictor can execute a fact door';
  end if;
  raise notice '0780 OK';
end $verify$;