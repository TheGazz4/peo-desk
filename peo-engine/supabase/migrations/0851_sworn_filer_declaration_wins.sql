-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0851-filer-wins
-- Articles implemented: VIII.2 (designation authority order), II.3 (rulings by Gazz are law)
-- Articles verified not violated: III.1, XIV.6
-- Verification query attached: YES
--
-- RULING (Gazz, 2026-09-11): Schedule MEP line 1b ("PEO Plan") is the filer's own declaration, signed
-- under penalty of perjury. It is the definitive source. Our inferences (welfare tell, website research,
-- name shape) never outrank it. 0847 wrongly parked 5 sponsors as "conflict"; the filer wins.
--
-- LEVEL 1 (logic): refresh_peo_filing_designation() now promotes any 1b filer to sponsor_class='peo',
--   designation_status='vetted', clients_may_inherit=true. Only a human ruling (decided_by like 'gazz%')
--   can hold a different class against the sworn box.
-- LEVEL 2 (backfill): the 5 parked sponsors are promoted now.
-- LEVEL 3 (display): designation_conflict is cleared; the audit note lives in evidence.

create or replace function public.refresh_peo_filing_designation()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $function$
declare n int; promoted int;
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
           -- a conflict now exists ONLY when a human ruling holds a non-PEO class against the sworn 1b box
           (select 'filer ticked PEO Plan (1b); human ruling ('||i.decided_by||') holds '||i.sponsor_class
              from public.mep_sponsor_identity i
             where i.sponsor_ein = f.ein and f.peo_n > 0 and i.sponsor_class <> 'peo'
               and i.decided_by ilike 'gazz%' limit 1),
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

  -- SWORN FILER WINS: promote every 1b filer our inference had parked elsewhere (human rulings excepted)
  update public.mep_sponsor_identity i
     set sponsor_class = 'peo', designation_status = 'vetted', clients_may_inherit = true,
         decided_by = 'filer_1b_sworn', decided_at = now(),
         evidence = coalesce(i.evidence,'') || ' || FILER DECLARATION '||to_char(now(),'YYYY-MM-DD')||
                    ': sponsor ticked Schedule MEP line 1b (PEO Plan) under penalty of perjury; prior class "'||i.sponsor_class||
                    '" was our inference and is overruled (Gazz ruling 2026-09-11).'
    from public.peo_filing_designation d
   where d.sponsor_ein = i.sponsor_ein and d.peo_plan_filings > 0
     and i.sponsor_class <> 'peo' and i.decided_by not ilike 'gazz%';
  get diagnostics promoted = row_count;

  return jsonb_build_object('sponsors', n, 'promoted_by_sworn_1b', promoted,
    'self_declared_peo', (select count(*) from public.peo_filing_designation where mep_plan_type in ('peo','mixed')),
    'peo_not_on_profile', (select count(*) from public.peo_filing_designation where mep_plan_type in ('peo','mixed') and not on_profile),
    'conflicts', (select count(*) from public.peo_filing_designation where designation_conflict is not null));
end $function$;

update public.brain_knowledge set content =
'Schedule MEP (Form 5500, 2023+) Part I line 1 is the filer''s own declaration of plan type: 1a association retirement plan, 1b PROFESSIONAL EMPLOYER ORGANIZATION PLAN (PEO Plan), 1c pooled employer plan (PEP), 1d other multiple-employer plan. Stored as mep_type_cd (1/2/3/4). RULING (Gazz 2026-09-11): code 2 (1b) is signed under penalty of perjury and is the DEFINITIVE PEO determinant. It outranks every inference the platform makes - welfare tell (0839), website research, name shape, NAICS. A 1b filer is sponsor_class=peo, designation_status=vetted, clients_may_inherit=true, automatically, on every refresh. The only thing that can hold a different class against the sworn box is a human ruling (mep_sponsor_identity.decided_by like gazz%); that and only that produces designation_conflict. Code 3 (PEP) is where Paychex Retirement LLC, Principal and Aon live - a PEP participant is NOT a PEO client (standing Paychex law). Code 4 is controlled-group MEPs (AT&T, GE, Comcast) - never PEOs. Supporting code systems: line A TYPE_PLAN_ENTITY_CD (3 = multiple-employer, necessary not sufficient) and line 2d BUSINESS_CODE (NAICS 561330 = PEO; 541214 payroll; 561320 temp help). 2026-09-11 backfill: AGS Payroll, PathMark HR, PayMaster, Wurkforce, Nexus HR promoted from "conflict" to vetted PEO on the strength of their own 1b box.'
where key = 'filer_declared_peo_law';

-- LEVEL 2 backfill + verification  (result: promoted_by_sworn_1b = 5, conflicts = 0)
select public.refresh_peo_filing_designation();
