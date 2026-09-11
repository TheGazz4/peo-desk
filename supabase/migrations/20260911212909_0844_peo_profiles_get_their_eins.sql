-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0843-rebrand-signal
-- Articles implemented: II.1 (EIN-first identity - applied to the PEO profile spine itself)
-- Articles verified not violated: III.1 (noncompete names excluded), II.2 (administrator EINs excluded;
--   alias must match exactly, no fuzzy join)
-- Verification query attached: YES
--
-- THE PEO PROFILE SPINE WAS NAME-KEYED. 787 profiles, 7 with a sponsor EIN.
-- Under the EIN-first law that is the gap: a rebrand, a growth figure, a welfare tell, a switch -
-- every EIN-keyed signal built today - had no way to reach the profile it belongs to.
--
-- This is the one-time name-to-EIN bridge: match each profile's registered aliases against Form 5500
-- sponsor names, take the EIN, and from then on the EIN is the key. Administrator EINs are excluded
-- (they belong to nobody), noncompete names are excluded, and the match is exact on the normalised
-- alias - no fuzzy joining onto a profile spine.

create or replace function public.backfill_profile_sponsor_eins()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $b$
declare n int;
begin
  with sp as (
    select distinct public.ein_norm(s.ein) ein, public.name_norm(s.sponsor_name) nm
      from public.efast_5500_staging s
     where s.ein is not null and s.sponsor_name is not null
       and not public.ein_is_administrator(s.ein)
       and (s.benefit_kind = 'welfare'
            or exists (select 1 from public.efast_mep_part_staging p where p.ack_id = s.ack_id))
  ), matched as (
    select f.family_slug, jsonb_agg(distinct sp.ein) as eins
      from public.peo_families f
      join sp on sp.nm = public.name_norm(f.alias)
     where not public.is_noncompete_peo(f.alias)
     group by f.family_slug
  )
  update public.peo_profiles p
     set sponsor_eins = (
           select jsonb_agg(distinct x) from (
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
end $b$;

select public.backfill_profile_sponsor_eins();

-- keep it that way: nightly, after the EIN class refresh, re-bridge, re-detect, re-hold, re-push
select cron.schedule('peo_ein_spine_nightly', '55 4 * * *',
$j$select public.backfill_profile_sponsor_eins(), public.detect_peo_rebrands(),
          public.sync_rebrands_to_profiles(), public.push_rebrands_to_lifecycle()$j$);