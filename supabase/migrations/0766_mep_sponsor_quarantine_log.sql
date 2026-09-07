-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-mep-sponsor-adjudication
-- Articles implemented: Mesh Cross-Reference Mandate 6 (quarantine and log, never merge)
-- Articles verified not violated: noncompete law, peo_vs_aso_separation_law
-- Verification query attached: YES

-- ============================================================================
-- 0766  Log every not-a-PEO 5500 sponsor as a standing quarantine, with the
--       researched reason, so the refusal is auditable and reversible by ruling.
--       domain='family_attribution' (the refused thing is a PEO attribution).
-- ============================================================================

set role peo_gatekeeper;

insert into public.identity_adjudication_queue
  (domain, subject_table, subject_natural_key, member_count, quarantine_reason,
   evidence, status, created_by, load_key, ruleset_version)
select 'family_attribution', 'form5500_mep_participants', 'mep_sponsor:' || r.mep_slug,
       (select count(distinct c.id) from companies c
         where c.merged_into is null and c.mep_peo_slugs @> array[r.mep_slug]),
       'Q_sponsor_not_peo:' || r.verdict,
       jsonb_build_object('brand', r.brand_name, 'website', r.website,
                          'verdict', r.verdict, 'evidence', r.evidence,
                          'ruling', '0763 MEP sponsor adjudication'),
       'quarantined', 'instanceA-2026-09-07-mep-sponsor-adjudication',
       'mep_sponsor_adjudication_0763', '0763'
from public.mep_sponsor_registry r
where r.verdict <> 'PEO'
  and not exists (select 1 from public.identity_adjudication_queue q
                  where q.subject_natural_key = 'mep_sponsor:' || r.mep_slug);

reset role;

do $verify$
declare v_notpeo int; v_q int;
begin
  select count(*) into v_notpeo from public.mep_sponsor_registry where verdict <> 'PEO';
  select count(*) into v_q from public.identity_adjudication_queue
   where load_key='mep_sponsor_adjudication_0763';
  if v_q <> v_notpeo then
    raise exception '0766 verification: % not-PEO sponsors but % quarantine rows', v_notpeo, v_q;
  end if;
  raise notice '0766 OK: % sponsors quarantined', v_q;
end $verify$;