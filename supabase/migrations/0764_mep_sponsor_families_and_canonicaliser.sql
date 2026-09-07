-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-mep-sponsor-adjudication
-- Articles implemented: XIV.1 (registry gate satisfied by research, never bypassed),
--   Mesh Cross-Reference Mandate 1 (canonical resolution)
-- Articles verified not violated: noncompete law, peo_vs_aso_separation_law, Paychex PEP rule
-- Verification query attached: YES

-- ============================================================================
-- 0764  Register the researched PEO families + one canonicaliser (from 0763)
-- ============================================================================

set role peo_gatekeeper;

insert into public.peo_families (alias, family_slug, family_display, mapping_basis)
select distinct on (r.canonical_family_slug)
       r.brand_name, r.canonical_family_slug, r.brand_name, 'MEP_SPONSOR_RESEARCH_0763'
from public.mep_sponsor_registry r
where r.verdict = 'PEO'
  and r.brand_name is not null
  and not exists (select 1 from public.peo_families f where f.family_slug = r.canonical_family_slug)
  and not exists (select 1 from public.peo_families f2 where lower(f2.alias) = lower(r.brand_name))
order by r.canonical_family_slug, r.mep_slug;

insert into public.peo_families (alias, family_slug, family_display, mapping_basis)
select r.mep_slug, r.canonical_family_slug, max(f.family_display), 'MEP_SPONSOR_RESEARCH_0763'
from public.mep_sponsor_registry r
join public.peo_families f on f.family_slug = r.canonical_family_slug
where r.verdict = 'PEO'
  and not exists (select 1 from public.peo_families f2 where lower(f2.alias) = lower(r.mep_slug))
group by r.mep_slug, r.canonical_family_slug;

reset role;

insert into public.peo_profiles (family_slug, display_name, customer_facing_name, website,
                                 website_source, website_as_of, profile_status, notes)
select distinct on (r.canonical_family_slug)
       r.canonical_family_slug, r.brand_name, r.brand_name, r.website,
       'mep_sponsor_research_0763', current_date, 'stub',
       '0763 MEP sponsor adjudication: ' || coalesce(r.evidence,'')
from public.mep_sponsor_registry r
where r.verdict = 'PEO' and r.brand_name is not null
  and not exists (select 1 from public.peo_profiles p where p.family_slug = r.canonical_family_slug)
order by r.canonical_family_slug, r.mep_slug;

create or replace function public.canonical_mep_sponsor_slug(p_slug text)
returns text
language sql
stable
security definer
set search_path to 'public','pg_temp'
as $fn$
  select case
           when r.mep_slug is null then p_slug
           when r.verdict = 'PEO'  then r.canonical_family_slug
           else null
         end
  from (select 1) z
  left join public.mep_sponsor_registry r on r.mep_slug = p_slug;
$fn$;

comment on function public.canonical_mep_sponsor_slug(text) is
  '0763/0764: resolves a Form 5500 MEP sponsor slug to its canonical PEO family. Returns NULL when the sponsor has been adjudicated NOT a PEO (ASO/payroll, association MEP, ordinary operating company, unknown) - callers must treat NULL as a refusal, never as a miss. An unadjudicated slug passes through unchanged and the XIV.1 registry gate still applies.';

revoke all on function public.canonical_mep_sponsor_slug(text) from public;
revoke all on function public.canonical_mep_sponsor_slug(text) from map_reader;

do $verify$
declare v_missing int;
begin
  select count(*) into v_missing
  from public.mep_sponsor_registry r
  where r.verdict='PEO'
    and not exists (select 1 from public.peo_families f where f.family_slug = r.canonical_family_slug);
  if v_missing > 0 then
    raise exception '0764 verification: % PEO sponsors still point at an unregistered family', v_missing;
  end if;
  if (select public.canonical_mep_sponsor_slug('formosaplasticscorporationusa')) is not null then
    raise exception '0764 verification: canonicaliser did not refuse a non-PEO sponsor';
  end if;
  if (select public.canonical_mep_sponsor_slug('thes2hrgroupllc')) <> 'engage' then
    raise exception '0764 verification: canonicaliser did not resolve S2 HR Group to Engage PEO';
  end if;
  if (select public.canonical_mep_sponsor_slug('a_slug_never_seen_before')) <> 'a_slug_never_seen_before' then
    raise exception '0764 verification: unadjudicated slug did not pass through unchanged';
  end if;
  raise notice '0764 OK';
end $verify$;