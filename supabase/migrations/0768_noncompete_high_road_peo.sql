-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-noncompete-high-road
-- Articles implemented: noncompete law (Gazz directive 2026-09-07: "High road and it's clients
--   go into the non compete file"), Mesh Mandate 6 (quarantine, never merge)
-- Articles verified not violated: existing noncompete entries untouched; no client data displayed
-- Verification query attached: YES

-- ============================================================================
-- 0768  High Road PEO joins the noncompete file
--
-- Ruled by Gazz 2026-09-07 after research surfaced a reported 2025 merger with
-- a protected PEO. High Road PEO and every client traceable to it are now
-- permanently withheld - never displayed, profiled, appended or worked.
--
-- Fix at the core, all three levels:
--   1. INGEST  - one pattern row; is_noncompete_peo()/company_is_noncompete()
--                pick it up everywhere, for every future load, with no other change.
--   2. DATA    - the existing traceable rows flagged and the 5500 sponsor
--                adjudication restated as NONCOMPETE.
--   3. DISPLAY - noncompete rows are already excluded from the shelf and the map;
--                rebake run after.
-- ============================================================================

insert into public.noncompete_peo_patterns (pattern, label, basis)
select 'high[ _.-]*road[ _.-]*(peo|mep)', 'High Road PEO',
       'Gazz directive 2026-09-07: High Road and its clients go into the non-compete file (reported 2025 merger with a protected PEO)'
where not exists (select 1 from public.noncompete_peo_patterns where label = 'High Road PEO');

set role peo_gatekeeper;

alter table public.mep_sponsor_registry drop constraint mep_sponsor_registry_verdict_check;
alter table public.mep_sponsor_registry add constraint mep_sponsor_registry_verdict_check
  check (verdict in ('PEO','ASO_PAYROLL','ASSOCIATION_MEP','OPERATING_COMPANY','UNKNOWN','NONCOMPETE'));

update public.mep_sponsor_registry
set verdict = 'NONCOMPETE',
    canonical_family_slug = null,
    evidence = 'Gazz directive 2026-09-07: High Road and its clients go into the non-compete file. Never displayed, profiled, appended or worked.'
where mep_slug = 'highroadpeollc';

update public.identity_adjudication_queue
set quarantine_reason = 'Q_sponsor_noncompete',
    evidence = evidence || jsonb_build_object('verdict','NONCOMPETE',
                 'ruling','Gazz directive 2026-09-07: noncompete file')
where subject_natural_key = 'mep_sponsor:highroadpeollc';

update public.companies c
set noncompete_blocked = true,
    is_noncompete = true,
    last_field_updated = coalesce(c.last_field_updated,'{}'::jsonb)
      || jsonb_build_object('noncompete', jsonb_build_object(
           'at', current_date, 'action','blocked',
           'peo','High Road PEO',
           'law','0768 Gazz directive 2026-09-07'))
where c.merged_into is null
  and public.company_is_noncompete(c.*)
  and not coalesce(c.noncompete_blocked, false);

reset role;

-- ---------------------------------------------------------------------------
-- VERIFICATION
-- ---------------------------------------------------------------------------
do $verify$
declare v_pat int; v_leak int; v_verdict text;
begin
  select count(*) into v_pat from public.noncompete_peo_patterns where label='High Road PEO';
  if v_pat <> 1 then
    raise exception '0768 verification: High Road pattern row count = %', v_pat;
  end if;

  if not public.is_noncompete_peo('highroadpeollc') then
    raise exception '0768 verification: the 5500 sponsor slug is not caught by the pattern';
  end if;
  if not public.is_noncompete_peo('HIGH ROAD PEO, LLC') then
    raise exception '0768 verification: the trading name is not caught by the pattern';
  end if;
  if not public.is_noncompete_peo('HIGH ROAD MEP 401(K) PLAN') then
    raise exception '0768 verification: the plan name is not caught by the pattern';
  end if;
  if public.is_noncompete_peo('HIGH ROAD TRUCKING INC') then
    raise exception '0768 verification: pattern is over-broad (matched an unrelated company)';
  end if;

  select verdict into v_verdict from public.mep_sponsor_registry where mep_slug='highroadpeollc';
  if v_verdict <> 'NONCOMPETE' then
    raise exception '0768 verification: sponsor verdict is %, expected NONCOMPETE', v_verdict;
  end if;

  select count(*) into v_leak from public.companies c
   where c.merged_into is null
     and public.company_is_noncompete(c.*)
     and not coalesce(c.noncompete_blocked,false);
  if v_leak > 0 then
    raise exception '0768 verification: % noncompete rows left unflagged', v_leak;
  end if;

  raise notice '0768 OK: High Road PEO in the noncompete file, all traceable rows flagged';
end $verify$;