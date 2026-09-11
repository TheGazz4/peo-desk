-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0841-growth-shrinkage
-- Articles implemented: VI.3 (a label must be computable from the numbers shown beside it)
-- Articles verified not violated: II.1, XIV.6
-- Verification query attached: YES
--
-- Two flaws in 0841's trajectory label, caught on the first read of real rows:
--   1. It mixed measures. Employer rosters only exist from 2023, so for 2023 it compared this
--      year's EMPLOYER count against last year's PENSION LIVES and called Xenium "shrinking" on
--      +3.8% growth. Growth is now judged on one measure at a time: employers if both years have
--      it, else pension lives if both years have it. Never across measures.
--   2. It called a year "lapsed" when the pension filing simply had not landed yet (Lotus HR 2025
--      has its welfare filing in but not its 401k). The most recent year with a missing measure is
--      'awaiting_filing', not lapsed. Lapsed means an OLDER year went quiet.

create view public.v_peo_growth as
with pension as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year, sum(s.tot_participants) as pension_lives
    from public.efast_5500_staging s where s.benefit_kind='pension' and s.ein is not null group by 1,2
), welfare as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year, sum(s.tot_participants) as welfare_lives
    from public.efast_5500_staging s where s.benefit_kind='welfare' and s.ein is not null group by 1,2
), employers as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year,
         count(distinct public.ein_norm(p.employer_ein)) as employers
    from public.efast_5500_staging s
    join public.efast_mep_part_staging p on p.ack_id = s.ack_id
   where s.ein is not null and p.employer_ein is not null group by 1,2
), years as (
  select sponsor_ein, form_year from pension
  union select sponsor_ein, form_year from welfare
  union select sponsor_ein, form_year from employers
), base as (
  select y.sponsor_ein, y.form_year, e.employers, p.pension_lives, w.welfare_lives
    from years y
    left join employers e using (sponsor_ein, form_year)
    left join pension   p using (sponsor_ein, form_year)
    left join welfare   w using (sponsor_ein, form_year)
), laged as (
  select b.*,
         lag(employers)     over (partition by sponsor_ein order by form_year) as employers_prior,
         lag(pension_lives) over (partition by sponsor_ein order by form_year) as pension_prior,
         lag(welfare_lives) over (partition by sponsor_ein order by form_year) as welfare_prior,
         lag(form_year)     over (partition by sponsor_ein order by form_year) as prior_year,
         max(form_year)     over (partition by sponsor_ein) as latest_year
    from base b
), judged as (
  select l.*,
         case when l.employers is not null and l.employers_prior is not null then 'employers'
              when l.pension_lives is not null and l.pension_prior is not null then 'pension_lives'
              else null end as trajectory_basis,
         case when l.employers is not null and l.employers_prior is not null
                then l.employers::numeric / nullif(l.employers_prior,0)
              when l.pension_lives is not null and l.pension_prior is not null
                then l.pension_lives::numeric / nullif(l.pension_prior,0)
              else null end as ratio
    from laged l
)
select j.sponsor_ein,
       (select max(s.sponsor_name) from public.efast_5500_staging s
         where public.ein_norm(s.ein) = j.sponsor_ein and s.form_year = j.form_year) as sponsor_name,
       c.ein_class,
       j.form_year, j.prior_year,
       j.employers, j.employers_prior, j.employers - j.employers_prior as employers_delta,
       round(100.0 * (j.employers::numeric / nullif(j.employers_prior,0) - 1), 1) as employers_pct,
       j.pension_lives, j.pension_prior, j.pension_lives - j.pension_prior as pension_delta,
       round(100.0 * (j.pension_lives::numeric / nullif(j.pension_prior,0) - 1), 1) as pension_pct,
       j.welfare_lives, j.welfare_prior, j.welfare_lives - j.welfare_prior as welfare_delta,
       round(100.0 * (j.welfare_lives::numeric / nullif(j.welfare_prior,0) - 1), 1) as welfare_pct,
       j.trajectory_basis,
       case
         when j.prior_year is null then 'new'
         when j.ratio is null and j.form_year = j.latest_year then 'awaiting_filing'
         when j.ratio is null and (j.pension_prior is not null or j.employers_prior is not null) then 'lapsed'
         when j.ratio is null then 'insufficient'
         when j.ratio > 1.05 then 'growing'
         when j.ratio < 0.95 then 'shrinking'
         else 'flat'
       end as trajectory
  from judged j
  left join public.ein_identity_class c on c.ein = j.sponsor_ein;

comment on view public.v_peo_growth is
  'Year-over-year growth/shrinkage per sponsor EIN from Form 5500. employers = client count (pension MEP roster only, 2023+). welfare_lives = covered lives on the health plan, NOT a client count. trajectory compares one measure with itself (trajectory_basis says which); +/-5% = flat; awaiting_filing = latest year not fully filed yet. ein_class = administrator means a TPA EIN mixing unrelated sponsors - do not read as one PEO.';

create view public.v_peo_participant_trend as
select coalesce(f.family_slug, 'other') as family_slug,
       g.form_year,
       sum(g.welfare_lives) as welfare_participants,
       sum(g.pension_lives) as pension_participants
  from public.v_peo_growth g
  left join public.peo_families f on lower(f.alias) = lower(g.sponsor_name)
 where g.ein_class = 'entity'
 group by 1,2;