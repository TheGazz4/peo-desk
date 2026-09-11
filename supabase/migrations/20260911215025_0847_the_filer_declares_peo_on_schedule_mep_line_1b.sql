-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0847-filer-declared-peo
-- Articles implemented: I.1 (use the source's own designation before inferring), II.1 (EIN-keyed),
--   II.4 (evidence behind every determination), VIII.2 (conflicts go to vetting, not auto-resolve)
-- Articles verified not violated: III.1 (noncompete excluded), II.2 (name bridge is exact on the
--   normalised core, never fuzzy)
-- Verification query attached: YES
--
-- THE FILER DECLARES IT. Gazz 2026-09-11: "5500 retirement filings have a specific designation or
-- legend that indicates possible co-employment ... just another way of making a determination on
-- PEO vs non-PEO."
--
-- Verified against the 2023 Schedule MEP (Form 5500), Part I, line 1 - "Check the appropriate box
-- to indicate type of multiple-employer pension plan":
--     1a  association retirement plan (29 CFR 2510.3-55)
--     1b  professional employer organization plan (PEO Plan) (29 CFR 2510.3-55)
--     1c  pooled employer plan (PEP) (29 CFR 2510.3-44)
--     1d  other multiple-employer pension plan
-- DOL publishes that checkbox as a code; our loader stores it as mep_type_cd. Confirmed empirically
-- against our own rows: code 2 = ADP TotalSource, TriNet, Justworks, Oasis (PEO); code 3 = Paychex
-- Retirement LLC, Principal, Aon (PEP providers); code 1 = NRECA, YMCA (associations); code 4 =
-- AT&T, GE, Comcast (controlled-group MEPs).
--
-- This is the strongest PEO determinant we hold: the sponsor ticked "PEO Plan" on a federal filing.
-- It outranks the welfare tell (0839) and it outranks our name-based guesses. Where it disagrees with
-- a class we assigned, the row is flagged for vetting - the filer's word is not auto-overridden by
-- ours, and ours is not auto-overridden by theirs without a look.
--
-- Two further code systems, recorded for completeness:
--   * Form 5500 line A, TYPE_PLAN_ENTITY_CD: 2 single-employer, 1 multiemployer (union),
--     3 multiple-employer, 4 DFE. Code 3 is necessary for a PEO plan, not sufficient.
--   * Form 5500 line 2d, BUSINESS_CODE (NAICS): 561330 = Professional Employer Organizations,
--     541214 = Payroll Services, 561320 = Temporary Help, 561311 = Employment Placement.
--     We capture it on the 5500-SF lane only; main lane capture is a loader change (v13, next).
--
-- YIELD OF THE ONE-OFF SEARCH Gazz asked for: 255 sponsor EINs self-declare as PEO plans; 72 were
-- already on an EIN-keyed profile; 181 were not, holding 10,313 client employers - including
-- G&A Partners (1,582 employers), ProService Hawaii (690), Prestige (two EINs), AlphaStaff, Landrum,
-- DecisionHR. Most of those HAVE families; the profile-EIN bridge (0844) matched aliases exactly and
-- missed "ALPHASTAFF GROUP, INC." vs "AlphaStaff". Widened here to the normalised core.

create table if not exists public.peo_filing_designation (
  sponsor_ein        text primary key,
  sponsor_name       text,
  mep_plan_type      text,          -- association | peo | pep | other | mixed
  peo_plan_filings   int not null default 0,
  pep_filings        int not null default 0,
  association_filings int not null default 0,
  other_mep_filings  int not null default 0,
  first_peo_year     int,
  last_peo_year      int,
  business_code      text,          -- NAICS from line 2d when captured
  naics_peo          boolean,       -- business_code = 561330
  max_employers      int,
  max_lives          bigint,
  on_profile         boolean not null default false,
  family_slug        text,
  designation_conflict text,        -- set when the filer's box disagrees with mep_sponsor_identity
  refreshed_at       timestamptz not null default now()
);
alter table public.peo_filing_designation enable row level security;
do $p$ begin
  if not exists (select 1 from pg_policies where tablename='peo_filing_designation' and policyname='peo_filing_designation_read') then
    create policy peo_filing_designation_read on public.peo_filing_designation for select to service_role, authenticated using (true);
  end if;
end $p$;

create or replace function public.refresh_peo_filing_designation()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $r$
declare n int;
begin
  with f as (
    select public.ein_norm(s.ein) as ein,
           max(s.sponsor_name) filter (where s.mep_type_cd='2') as peo_name,
           max(s.sponsor_name) as any_name,
           count(*) filter (where s.mep_type_cd='2') as peo_n,
           count(*) filter (where s.mep_type_cd='3') as pep_n,
           count(*) filter (where s.mep_type_cd='1') as assoc_n,
           count(*) filter (where s.mep_type_cd='4') as other_n,
           min(s.form_year) filter (where s.mep_type_cd='2') as first_peo,
           max(s.form_year) filter (where s.mep_type_cd='2') as last_peo,
           max((select count(distinct p.employer_ein) from public.efast_mep_part_staging p where p.ack_id = s.ack_id)) as employers,
           max(s.tot_participants) as lives
      from public.efast_5500_staging s
     where s.mep_type_cd is not null and s.ein is not null
       and left(s.lane,4) not in ('sch_','dcg_')
       and not public.ein_is_administrator(s.ein)
       and not public.is_noncompete_peo(s.sponsor_name)
     group by 1
  ), bc as (
    select public.ein_norm(ein) as ein, max(business_code) as business_code
      from public.efast_5500_sf_staging where business_code is not null group by 1
  ), ins as (
    insert into public.peo_filing_designation
      (sponsor_ein, sponsor_name, mep_plan_type, peo_plan_filings, pep_filings, association_filings,
       other_mep_filings, first_peo_year, last_peo_year, business_code, naics_peo, max_employers, max_lives,
       on_profile, family_slug, designation_conflict, refreshed_at)
    select f.ein, coalesce(f.peo_name, f.any_name),
           case when f.peo_n > 0 and f.pep_n + f.assoc_n + f.other_n = 0 then 'peo'
                when f.peo_n > 0 then 'mixed'
                when f.pep_n > 0 then 'pep'
                when f.assoc_n > 0 then 'association'
                else 'other' end,
           f.peo_n, f.pep_n, f.assoc_n, f.other_n, f.first_peo, f.last_peo,
           bc.business_code, bc.business_code = '561330',
           f.employers, f.lives,
           exists (select 1 from public.peo_profiles p where p.sponsor_eins ? f.ein),
           (select p.family_slug from public.peo_profiles p where p.sponsor_eins ? f.ein limit 1),
           (select 'filer ticked PEO Plan (1b) but mep_sponsor_identity says '||i.sponsor_class
              from public.mep_sponsor_identity i
             where i.sponsor_ein = f.ein and f.peo_n > 0 and i.sponsor_class <> 'peo' limit 1),
           now()
      from f left join bc on bc.ein = f.ein
    on conflict (sponsor_ein) do update set
      sponsor_name = excluded.sponsor_name, mep_plan_type = excluded.mep_plan_type,
      peo_plan_filings = excluded.peo_plan_filings, pep_filings = excluded.pep_filings,
      association_filings = excluded.association_filings, other_mep_filings = excluded.other_mep_filings,
      first_peo_year = excluded.first_peo_year, last_peo_year = excluded.last_peo_year,
      business_code = excluded.business_code, naics_peo = excluded.naics_peo,
      max_employers = excluded.max_employers, max_lives = excluded.max_lives,
      on_profile = excluded.on_profile, family_slug = excluded.family_slug,
      designation_conflict = excluded.designation_conflict, refreshed_at = now()
    returning 1)
  select count(*) into n from ins;
  return jsonb_build_object('sponsors', n,
    'self_declared_peo', (select count(*) from public.peo_filing_designation where mep_plan_type in ('peo','mixed')),
    'peo_not_on_profile', (select count(*) from public.peo_filing_designation where mep_plan_type in ('peo','mixed') and not on_profile),
    'conflicts', (select count(*) from public.peo_filing_designation where designation_conflict is not null));
end $r$;

-- widen the profile-EIN bridge: exact on the normalised core, not the raw alias string
create or replace function public.backfill_profile_sponsor_eins()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $b$
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
       and length(public.sponsor_name_core(f.alias)) >= 6          -- never bridge on a stub
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
end $b$;

select public.backfill_profile_sponsor_eins() as bridge;
select public.refresh_peo_filing_designation() as designation;

-- into the nightly EIN spine job, and alert on a NEW self-declared PEO the platform does not know
select cron.schedule('peo_filing_designation_nightly', '15 5 * * *',
$j$do $b$ declare r record; begin
  perform public.refresh_peo_filing_designation();
  for r in select sponsor_ein, sponsor_name, max_employers from public.peo_filing_designation
            where mep_plan_type in ('peo','mixed') and not on_profile
              and refreshed_at > now() - interval '1 day'
              and not exists (select 1 from public.peo_families f
                               where public.sponsor_name_core(f.alias) = public.sponsor_name_core(sponsor_name))
            order by max_employers desc nulls last limit 20
  loop
    insert into public.source_alerts (source_name, change_summary)
    values ('peo_filing_designation', 'NEW SELF-DECLARED PEO (Schedule MEP 1b) not on any profile: '||r.sponsor_name||' EIN '||r.sponsor_ein||' employers '||coalesce(r.max_employers::text,'?'));
  end loop; end $b$;$j$);

insert into public.brain_knowledge (scope, key, content) values
('doctrine','filer_declared_peo_law',
 'Schedule MEP (Form 5500, 2023+) Part I line 1 is the filer''s own declaration of plan type: 1a association retirement plan, 1b PROFESSIONAL EMPLOYER ORGANIZATION PLAN (PEO Plan), 1c pooled employer plan (PEP), 1d other multiple-employer plan. Stored as mep_type_cd (1/2/3/4). Code 2 is the strongest PEO determinant the platform holds: the sponsor ticked "PEO Plan" on a federal filing. It outranks the welfare tell (0839) and name inference. Code 3 (PEP) is where Paychex Retirement LLC, Principal and Aon live - a PEP participant is NOT a PEO client (standing Paychex law). Code 4 is controlled-group MEPs (AT&T, GE, Comcast) - never PEOs. Two supporting code systems: line A TYPE_PLAN_ENTITY_CD (3 = multiple-employer, necessary not sufficient) and line 2d BUSINESS_CODE (NAICS 561330 = Professional Employer Organizations; 541214 payroll; 561320 temp help). Where the filer''s box disagrees with a class we assigned, peo_filing_designation.designation_conflict is set and the sponsor goes to vetting - neither side auto-wins. One-off search 2026-09-11: 255 self-declared PEO sponsors, 181 not on an EIN-keyed profile, 10,313 client employers among them. Now a nightly refresh with an alert on any new self-declared PEO the platform does not know.');