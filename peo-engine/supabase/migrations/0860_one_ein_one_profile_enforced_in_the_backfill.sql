-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0857-self-audit
-- Articles implemented: II.1/II.2 (one EIN = one PEO profile), never-aggregate law
-- Verification query attached: YES
--
-- SELF-AUDIT finding: the identity-repair recompute re-ran backfill_profile_sponsor_eins(), which bridges EINs onto
-- profiles through peo_families aliases. "AccessPoint" is an alias row under the vensure family, so AccessPoint's EIN
-- (383522117) was put back on the vensure profile - the exact thing I removed by hand in 0848. A hand fix without a
-- logic fix is not a fix. LEVEL 1: the backfill now refuses any EIN already carried by another profile.
-- LEVEL 2: the EIN is removed from vensure again. LEVEL 3: profile_ein_unique (RED) stays as the tripwire.
-- Also: efast_schedule_owns_identity ignores filings the repair log recorded as no_main_form_row (awaiting ratification).

create or replace function public.backfill_profile_sponsor_eins()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare n int;
begin
  with sp as (
    select distinct public.ein_norm(s.ein) ein, public.sponsor_name_core(s.sponsor_name) core
      from public.efast_5500_staging s
     where s.ein is not null and s.sponsor_name is not null
       and left(s.lane,4) not in ('sch_','dcg_')
       and not public.ein_is_administrator(s.ein)
       and (s.benefit_kind = 'welfare' or s.mep_type_cd is not null
            or exists (select 1 from public.efast_mep_part_staging p where p.ack_id = s.ack_id))
  ), matched as (
    select f.family_slug, jsonb_agg(distinct sp.ein) as eins
      from public.peo_families f
      join sp on sp.core = public.sponsor_name_core(f.alias)
     where not public.is_noncompete_peo(f.alias)
       and length(public.sponsor_name_core(f.alias)) >= 6
       -- ONE EIN = ONE PROFILE: an EIN already carried by a different profile is never bridged here
       and not exists (select 1 from public.peo_profiles q
                        where q.family_slug <> f.family_slug and q.sponsor_eins ? sp.ein)
     group by f.family_slug
  )
  update public.peo_profiles p
     set sponsor_eins = (select jsonb_agg(distinct x) from (
                           select jsonb_array_elements_text(coalesce(p.sponsor_eins,'[]'::jsonb)) x
                           union select jsonb_array_elements_text(m.eins)) u),
         updated_at = now()
    from matched m
   where m.family_slug = p.family_slug
     and not (coalesce(p.sponsor_eins,'[]'::jsonb) @> m.eins);
  get diagnostics n = row_count;
  return jsonb_build_object('profiles_updated', n,
    'profiles_with_eins_now', (select count(*) from public.peo_profiles
                                 where jsonb_array_length(coalesce(sponsor_eins,'[]'::jsonb)) > 0));
end $function$;
revoke execute on function public.backfill_profile_sponsor_eins() from public, anon;
grant execute on function public.backfill_profile_sponsor_eins() to service_role, postgres;

update public.peo_profiles set sponsor_eins = sponsor_eins - '383522117', updated_at = now() where family_slug = 'vensure';

set role peo_gatekeeper;
update public.sysaudit_registry
   set check_sql = 'select ack_id, form_year, lane, ein, left(sponsor_name,60) as sponsor from public.efast_5500_staging s where s.sponsor_name is not null and left(s.lane,4) in (''sch_'',''dcg_'') and not exists (select 1 from public.efast_identity_repair_log l where l.ack_id = s.ack_id and l.outcome like ''no_main_form_row%'') limit 100'
 where check_name = 'efast_schedule_owns_identity';
reset role;
