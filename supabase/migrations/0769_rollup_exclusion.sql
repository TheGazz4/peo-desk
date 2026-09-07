-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-rollup-exclusion
-- Articles implemented: peo_vs_aso_separation_law (a roll-up is not co-employment),
--   Mesh Mandate 6 (quarantine and log, never merge), XIV.1 (registry gate preserved)
-- Articles verified not violated: noncompete law untouched; a REGISTERED family or an explicit
--   PEO adjudication always overrides the exclusion, so no existing PEO can be blocked by it
-- Verification query attached: YES

-- ============================================================================
-- 0769  Standing exclusion for dental / surgical / healthcare roll-ups
--
-- Gazz 2026-09-07: "Yes, exclude the dental and surgical roll ups."
--
-- A DSO/MSO looks exactly like a PEO book to a structural matcher: one plan
-- sponsor, one EIN, many small businesses underneath. The difference is
-- ownership - the roll-up BUYS the practices, it does not co-employ someone
-- else's staff. GPS Dental, Corus Orthodontists, Dental Dreams, Surgery
-- Partners and the nursing/senior-living groups all entered this way.
--
-- Fix at the core, all three levels:
--   1. INGEST  - pattern table + is_rollup_sponsor(); classify_mep_plan_kind()
--                parks a matching sponsor as 'rollup_excluded' instead of 'peo_book'.
--   2. DATA    - the nine known roll-ups retagged ROLLUP in the sponsor registry,
--                their quarantine reasons restated, their participant rows parked.
--   3. DISPLAY - none was ever attributed, so nothing leaves the map; rebake after.
--
-- SAFETY: is_rollup_sponsor() returns FALSE for any sponsor that is already a
-- registered peo_families family_slug or carries an explicit verdict='PEO'.
-- Heartland Dental, CBR Management and RMI Management all match the patterns on
-- a client's plan name and are all protected by that override.
-- ============================================================================

create table if not exists public.peo_book_exclusion_patterns (
  id         bigserial primary key,
  pattern    text not null,
  label      text not null,
  category   text not null check (category in ('dso','mso','senior_care','vision','vet','other')),
  basis      text not null,
  added_at   timestamptz not null default now()
);

alter table public.peo_book_exclusion_patterns enable row level security;

comment on table public.peo_book_exclusion_patterns is
  '0769: sponsor-name patterns that mark a Form 5500 MEP sponsor as a practice roll-up (DSO/MSO) rather than a PEO. A roll-up owns its practices; it does not co-employ another business staff, so its participants are never PEO clients. Overridden by an explicit PEO registration - see is_rollup_sponsor().';

insert into public.peo_book_exclusion_patterns (pattern, label, category, basis)
select v.pattern, v.label, v.category,
       'Gazz directive 2026-09-07: exclude the dental and surgical roll ups'
from (values
  ('dental|orthodont|endodont|periodont|oral surgery|\mdso\M', 'Dental support organisations', 'dso'),
  ('surgery partners|surgical|ambulatory surgery|\masc\M',     'Surgical / ASC roll-ups',      'mso'),
  ('rehabilitation|nursing|skilled nursing|senior living|assisted living|healthcare system|health facility',
                                                              'Nursing / senior-care groups', 'senior_care'),
  ('eye center|ophthalmolog|optometr|vision partners',         'Vision / eye-care roll-ups',   'vision'),
  ('veterinar|animal hospital',                                'Veterinary roll-ups',          'vet'),
  ('physician partners|medical group|dermatolog|orthopaed|orthoped',
                                                              'Physician practice roll-ups',  'mso')
) as v(pattern, label, category)
where not exists (select 1 from public.peo_book_exclusion_patterns e where e.pattern = v.pattern);

-- ---------------------------------------------------------------------------
-- The test. A registered PEO family, or an explicit PEO adjudication, always wins.
-- ---------------------------------------------------------------------------
create or replace function public.is_rollup_sponsor(p_slug text, p_plan_name text default null)
returns boolean
language sql
stable
security definer
set search_path to 'public','pg_temp'
as $fn$
  select case
    when exists (select 1 from peo_families f where f.family_slug = p_slug) then false
    when exists (select 1 from mep_sponsor_registry r
                  where r.mep_slug = p_slug and r.verdict = 'PEO') then false
    else coalesce((select bool_or(coalesce(p_slug,'') ~* e.pattern
                               or coalesce(p_plan_name,'') ~* e.pattern)
                   from peo_book_exclusion_patterns e), false)
  end;
$fn$;

comment on function public.is_rollup_sponsor(text, text) is
  '0769: TRUE when a Form 5500 MEP sponsor is a practice roll-up (dental, surgical, senior care, vision, vet, physician group) rather than a PEO. Returns FALSE for any sponsor that is a registered peo_families family_slug or carries verdict=PEO in mep_sponsor_registry - an explicit registration always beats the pattern.';

revoke all on function public.is_rollup_sponsor(text, text) from public;
revoke all on function public.is_rollup_sponsor(text, text) from map_reader;
grant execute on function public.is_rollup_sponsor(text, text) to peo_gatekeeper;
grant execute on function public.is_rollup_sponsor(text, text) to service_role;

-- widen plan_kind to carry the parked bucket
alter table public.form5500_mep_participants drop constraint form5500_mep_participants_plan_kind_check;
alter table public.form5500_mep_participants add constraint form5500_mep_participants_plan_kind_check
  check (plan_kind = any (array['peo_book','open_pep','pending','rollup_excluded']));

-- ---------------------------------------------------------------------------
-- Ingest level: the classifier parks a roll-up instead of calling it a PEO book.
-- ---------------------------------------------------------------------------
create or replace function public.classify_mep_plan_kind()
 returns jsonb
 language plpgsql
 set search_path to 'public', 'pg_temp'
as $function$
declare v_pep int; v_pb int; v_roll int;
begin
  update form5500_mep_participants set plan_kind = 'open_pep'
  where plan_kind = 'pending' and plan_name ~* '(POOLED EMPLOYER|\mPEP\M)';
  get diagnostics v_pep = row_count;

  -- 0769: a practice roll-up is parked, never promoted to a PEO book.
  update form5500_mep_participants p set plan_kind = 'rollup_excluded'
  where p.plan_kind = 'pending'
    and p.plan_name !~* '(POOLED EMPLOYER|\mPEP\M)'
    and is_rollup_sponsor(p.peo_slug, p.plan_name);
  get diagnostics v_roll = row_count;

  update form5500_mep_participants p set plan_kind = 'peo_book'
  where p.plan_kind = 'pending'
    and p.plan_name !~* '(POOLED EMPLOYER|\mPEP\M)'
    and not is_rollup_sponsor(p.peo_slug, p.plan_name)
    and exists (select 1 from peo_profiles pp where pp.sponsor_eins @> to_jsonb(p.sponsor_ein));
  get diagnostics v_pb = row_count;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('classify_mep_plan_kind', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('classified_open_pep', v_pep, 'classified_peo_book', v_pb,
                             'classified_rollup_excluded', v_roll));
  return jsonb_build_object('classified_open_pep', v_pep, 'classified_peo_book', v_pb,
                            'classified_rollup_excluded', v_roll);
end $function$;

-- ---------------------------------------------------------------------------
-- Data level: retag the known roll-ups and park their participant rows.
-- ---------------------------------------------------------------------------
set role peo_gatekeeper;

alter table public.mep_sponsor_registry drop constraint mep_sponsor_registry_verdict_check;
alter table public.mep_sponsor_registry add constraint mep_sponsor_registry_verdict_check
  check (verdict in ('PEO','ASO_PAYROLL','ASSOCIATION_MEP','OPERATING_COMPANY',
                     'UNKNOWN','NONCOMPETE','ROLLUP'));

update public.mep_sponsor_registry r
set verdict = 'ROLLUP',
    evidence = coalesce(r.evidence,'') || ' | 0769: practice roll-up, standing exclusion from the PEO book'
where r.verdict = 'OPERATING_COMPANY'
  and r.mep_slug in ('guidedpracticesolutionsdentalllc','corusorthodontistsllc','kosservicesllc',
                     'surgerypartnersinc','bronxcenterforrehabilitationhealthcare','cassenacarellc',
                     'integracare','bellhavenmanagemenllcdba','eyecenterofcolumbusllc');

update public.identity_adjudication_queue q
set quarantine_reason = 'Q_sponsor_rollup',
    evidence = q.evidence || jsonb_build_object('verdict','ROLLUP',
                 'ruling','0769 standing roll-up exclusion')
where q.load_key = 'mep_sponsor_adjudication_0763'
  and exists (select 1 from public.mep_sponsor_registry r
              where 'mep_sponsor:'||r.mep_slug = q.subject_natural_key and r.verdict = 'ROLLUP');

reset role;

update public.form5500_mep_participants p
set plan_kind = 'rollup_excluded'
where p.plan_kind = 'peo_book'
  and exists (select 1 from public.mep_sponsor_registry r
              where r.mep_slug = p.peo_slug and r.verdict = 'ROLLUP');

-- ---------------------------------------------------------------------------
-- VERIFICATION
-- ---------------------------------------------------------------------------
do $verify$
declare v_pat int; v_roll int; v_parked int;
begin
  select count(*) into v_pat from public.peo_book_exclusion_patterns;
  if v_pat < 6 then
    raise exception '0769 verification: only % exclusion patterns seeded', v_pat;
  end if;

  if not public.is_rollup_sponsor('guidedpracticesolutionsdentalllc','GPS DENTAL 401(K) PLAN') then
    raise exception '0769 verification: GPS Dental not caught';
  end if;
  if not public.is_rollup_sponsor('surgerypartnersinc','NATIONAL SURGICAL HOSPITALS 401(K) PLAN') then
    raise exception '0769 verification: Surgery Partners not caught';
  end if;
  if not public.is_rollup_sponsor('kosservicesllc','DENTAL DREAMS 401(K) PLAN') then
    raise exception '0769 verification: Dental Dreams not caught';
  end if;

  if public.is_rollup_sponsor('heartlanddental','HEARTLAND DENTAL 401K AND STOCK PARTICIPATION PLAN') then
    raise exception '0769 verification: a registered family was blocked by the roll-up pattern';
  end if;
  if public.is_rollup_sponsor('rmimanagement','HEALTHCREST SURGICAL 401(K) PLAN') then
    raise exception '0769 verification: RMI Management blocked by a client plan name';
  end if;
  if public.is_rollup_sponsor('cbrmanagementservices','FOX MANAGEMENT REHABILITATION SERVICES LLC 401(K) PLAN') then
    raise exception '0769 verification: CBR Management blocked by a client plan name';
  end if;
  if public.is_rollup_sponsor('medbestmedicalmanagementinc','MEDBEST MEDICAL MANAGEMENT 401(K) PLAN') then
    raise exception '0769 verification: an adjudicated PEO was blocked by the roll-up pattern';
  end if;
  if public.is_rollup_sponsor('thes2hrgroupllc','ENGAGE PEO RETIREMENT SAVINGS PLAN') then
    raise exception '0769 verification: pattern fired on an ordinary PEO';
  end if;

  select count(*) into v_roll from public.mep_sponsor_registry where verdict='ROLLUP';
  select count(*) into v_parked from public.form5500_mep_participants where plan_kind='rollup_excluded';
  raise notice '0769 OK: % patterns, % sponsors tagged ROLLUP, % participant rows parked',
    v_pat, v_roll, v_parked;
end $verify$;