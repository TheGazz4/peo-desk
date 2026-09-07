-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-mep-sponsor-adjudication
-- Articles implemented: XIV.1 (registry gate preserved), Mesh Mandate 1 (canonical resolution),
--   6 (a not-a-PEO sponsor is refused, never merged)
-- Articles verified not violated: noncompete law, peo_vs_aso_separation_law, Paychex PEP rule
-- Verification query attached: YES

-- ============================================================================
-- 0765  promote_initial_attribution canonicalises the 5500 sponsor slug through
--       mep_sponsor_registry (0763) and treats a not-a-PEO verdict as a standing
--       refusal (sponsor_not_peo_refused) rather than an unregistered-family hold.
--       Body otherwise unchanged from 0734.
-- ============================================================================

set role peo_gatekeeper;

create or replace function public.promote_initial_attribution()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_promoted int := 0; v_ambiguous int := 0; v_guarded int := 0; v_pep_held int := 0; v_unreg_held int := 0;
        v_not_peo int := 0;
        v_unreg jsonb := '{}'::jsonb; r record; v_winner record; v_slug text;
begin
  for r in
    select c.id, c.ein from companies c
    where c.peo_family_slug is null
      and exists (select 1 from field_observations fo
                  where fo.subject_class = 'company' and fo.subject_key = c.ein and fo.field_name='peo_family_slug'
                    and fo.source_hub='efast_5500' and fo.resolution_status='resolved')
  loop
    if exists (select 1 from companies c2 where c2.id = r.id and company_is_noncompete(c2))
       or is_target_excluded((select coalesce(peo_original,'') from companies where id = r.id)) then
      v_guarded := v_guarded + 1; continue;
    end if;
    select value_text, max(as_of) as latest into v_winner from (
      select fo.value_text, fo.as_of,
             rank() over (order by fo.as_of desc) rnk
      from field_observations fo
      where fo.subject_class = 'company' and fo.subject_key = r.ein and fo.field_name='peo_family_slug'
        and fo.source_hub='efast_5500' and fo.resolution_status='resolved') x
    where rnk = 1 group by value_text;
    if (select count(distinct value_text) from (
          select fo.value_text, rank() over (order by fo.as_of desc) rnk
          from field_observations fo
          where fo.subject_class = 'company' and fo.subject_key = r.ein and fo.field_name='peo_family_slug'
            and fo.source_hub='efast_5500' and fo.resolution_status='resolved') y where rnk=1) > 1 then
      v_ambiguous := v_ambiguous + 1; continue;
    end if;
    if is_noncompete_peo(v_winner.value_text) or is_target_excluded(v_winner.value_text) then
      v_guarded := v_guarded + 1; continue;
    end if;
    if not exists (select 1 from mep_peo_book mb where mb.peo_slug = v_winner.value_text and mb.ein = r.ein) then
      v_pep_held := v_pep_held + 1; continue;
    end if;
    v_slug := canonical_mep_sponsor_slug(v_winner.value_text);
    if v_slug is null then
      v_not_peo := v_not_peo + 1; continue;
    end if;
    if not exists (select 1 from peo_families f where f.family_slug = v_slug) then
      v_unreg_held := v_unreg_held + 1;
      v_unreg := v_unreg || jsonb_build_object(v_slug, coalesce((v_unreg->>v_slug)::int, 0) + 1);
      continue;
    end if;
    if is_noncompete_peo(v_slug) or is_target_excluded(v_slug) then
      v_guarded := v_guarded + 1; continue;
    end if;
    update companies set peo_family_slug = v_slug, attribution_class = 'verified_filing'
    where id = r.id and peo_family_slug is null;
    v_promoted := v_promoted + 1;
    insert into signals (company_ein, signal_type, source, value, confidence, population, observed_at)
    values (r.ein, 'peo_attribution_initial', 'efast_wring',
            jsonb_build_object('family', v_slug, 'raw_sponsor', v_winner.value_text, 'as_of', v_winner.latest,
              'basis','resolved sole-source EFAST winner with peo_book support, sponsor adjudicated PEO (0763); attribution_class=verified_filing (staleness-decayed)'),
            0.7, 'mep_matched', now());
  end loop;
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('promote_initial_attribution', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('promoted', v_promoted, 'ambiguous_skipped', v_ambiguous,
            'guard_blocked', v_guarded, 'pep_or_pending_held', v_pep_held,
            'sponsor_not_peo_refused', v_not_peo,
            'family_unregistered_held', v_unreg_held, 'family_unregistered_by_slug', v_unreg));
  return jsonb_build_object('promoted', v_promoted, 'ambiguous_skipped', v_ambiguous,
    'guard_blocked', v_guarded, 'pep_or_pending_held', v_pep_held,
    'sponsor_not_peo_refused', v_not_peo,
    'family_unregistered_held', v_unreg_held, 'family_unregistered_by_slug', v_unreg);
end $function$;

reset role;

do $verify$
begin
  if pg_get_functiondef('public.promote_initial_attribution()'::regprocedure)
       not like '%canonical_mep_sponsor_slug%' then
    raise exception '0765 verification: promoter is not calling the canonicaliser';
  end if;
  if pg_get_functiondef('public.promote_initial_attribution()'::regprocedure)
       not like '%sponsor_not_peo_refused%' then
    raise exception '0765 verification: promoter is not reporting the refusal count';
  end if;
  raise notice '0765 OK';
end $verify$;