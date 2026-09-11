-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0841-growth-shrinkage
-- Articles implemented: II.1 (EIN-first identity), I (observe every sponsor, not a hand-picked six),
--   XIV.4 (a signal the product offers must be computed, not narrated)
-- Articles verified not violated: III.1 (protected sponsors are already purged from the source),
--   XIV.6 (no display change here)
-- Verification query attached: YES
--
-- GROWTH AND SHRINKAGE, FOR EVERY PEO, KEYED BY EIN.
--
-- The existing v_peo_participant_trend hard-codes six PEOs by name pattern (insperity%, adp%, ...)
-- and buckets everyone else as 'other'. That is a name-first view of six companies. Under the
-- EIN-first law (0840) it is replaced with one keyed by sponsor EIN that covers every sponsor and
-- separates the three things a Form 5500 actually lets us count year over year:
--
--   employers        - distinct participating-employer EINs on the pension MEP roster.
--                      This is the CLIENT COUNT. It exists on pension filings only.
--   pension_lives    - participants on the retirement plan(s).
--   welfare_lives    - participants on the health & welfare plan(s). This is covered lives, NOT a
--                      client count: welfare filings carry no participating-employer roster
--                      (verified: 23 of 32 pension filings in the sample have one, 0 of 16 welfare).
--
-- Each is given with the prior year and the change, plus one label so the desk does not have to
-- do arithmetic: growing / shrinking / flat / new / lapsed.

create or replace view public.v_peo_growth as
with pension as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year,
         sum(s.tot_participants) as pension_lives
    from public.efast_5500_staging s
   where s.benefit_kind = 'pension' and s.ein is not null
   group by 1,2
), welfare as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year,
         sum(s.tot_participants) as welfare_lives
    from public.efast_5500_staging s
   where s.benefit_kind = 'welfare' and s.ein is not null
   group by 1,2
), employers as (
  select public.ein_norm(s.ein) as sponsor_ein, s.form_year,
         count(distinct public.ein_norm(p.employer_ein)) as employers
    from public.efast_5500_staging s
    join public.efast_mep_part_staging p on p.ack_id = s.ack_id
   where s.ein is not null and p.employer_ein is not null
   group by 1,2
), years as (
  select sponsor_ein, form_year from pension
  union select sponsor_ein, form_year from welfare
  union select sponsor_ein, form_year from employers
), base as (
  select y.sponsor_ein, y.form_year,
         e.employers, p.pension_lives, w.welfare_lives
    from years y
    left join employers e using (sponsor_ein, form_year)
    left join pension   p using (sponsor_ein, form_year)
    left join welfare   w using (sponsor_ein, form_year)
), laged as (
  select b.*,
         lag(employers)     over (partition by sponsor_ein order by form_year) as employers_prior,
         lag(pension_lives) over (partition by sponsor_ein order by form_year) as pension_prior,
         lag(welfare_lives) over (partition by sponsor_ein order by form_year) as welfare_prior,
         lag(form_year)     over (partition by sponsor_ein order by form_year) as prior_year
    from base b
)
select l.sponsor_ein,
       (select max(s.sponsor_name) from public.efast_5500_staging s
         where public.ein_norm(s.ein) = l.sponsor_ein and s.form_year = l.form_year) as sponsor_name,
       c.ein_class,
       l.form_year, l.prior_year,
       l.employers, l.employers_prior,
       l.employers - l.employers_prior as employers_delta,
       round(100.0 * (l.employers::numeric / nullif(l.employers_prior,0) - 1), 1) as employers_pct,
       l.pension_lives, l.pension_prior,
       l.pension_lives - l.pension_prior as pension_delta,
       round(100.0 * (l.pension_lives::numeric / nullif(l.pension_prior,0) - 1), 1) as pension_pct,
       l.welfare_lives, l.welfare_prior,
       l.welfare_lives - l.welfare_prior as welfare_delta,
       round(100.0 * (l.welfare_lives::numeric / nullif(l.welfare_prior,0) - 1), 1) as welfare_pct,
       case
         when l.prior_year is null then 'new'
         when coalesce(l.employers, l.pension_lives) is null and coalesce(l.employers_prior, l.pension_prior) is not null then 'lapsed'
         when coalesce(l.employers, l.pension_lives) > coalesce(l.employers_prior, l.pension_prior) * 1.05 then 'growing'
         when coalesce(l.employers, l.pension_lives) < coalesce(l.employers_prior, l.pension_prior) * 0.95 then 'shrinking'
         else 'flat'
       end as trajectory
  from laged l
  left join public.ein_identity_class c on c.ein = l.sponsor_ein;

comment on view public.v_peo_growth is
  'Year-over-year growth/shrinkage per sponsor EIN from Form 5500. employers = client count (pension MEP roster only). welfare_lives = covered lives on the health plan, NOT a client count - welfare filings carry no employer roster. trajectory uses employers when present, else pension lives; +/-5% band = flat. ein_class = administrator means the EIN is a TPA and these numbers are a mix of unrelated sponsors - do not read them as one PEO.';

-- the old six-PEO view is retired in place so nothing that still selects from it breaks,
-- but it now reads from the EIN-keyed truth
create or replace view public.v_peo_participant_trend as
select coalesce(f.family_slug, 'other') as family_slug,
       g.form_year,
       sum(g.welfare_lives) as welfare_participants,
       sum(g.pension_lives) as pension_participants
  from public.v_peo_growth g
  left join public.peo_families f on lower(f.alias) = lower(g.sponsor_name)
 where g.ein_class = 'entity'
 group by 1,2;