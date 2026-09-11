-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0838-family-is-not-a-gate
-- Articles implemented: I.1 (observe before labelling), II.4 (evidence behind every determination),
--   VIII.2 (no designation applied to clients before it is vetted)
-- Articles verified not violated: II.2, III.1, XIV.6
-- Verification query attached: YES
--
-- THE WELFARE TELL. Gazz 2026-09-11: a sponsor filing a health & welfare 5500 as well as a pension
-- 5500 is a telltale sign of a PEO. A PEO carries its clients' health plan; a payroll bureau, a
-- software vendor and a plain MEP sponsor do not.
--
--   EmPower HR       welfare 8,955 + pension 12,033   "HEALTH AND WELFARE BENEFIT PLAN"  -> PEO
--   Xenium           welfare 1,420 + pension  3,069   Kaiser NW, Unum                    -> PEO
--   Employco         welfare 1,086 + pension  2,245   "HEALTH AND WELFARE BENEFITS PLAN" -> PEO
--   Lotus HR         welfare   289 + pension    367   group health plan                  -> carries a book
--   Strategic Bnfts  welfare   282 + pension    363   DENTAL + MEDICAL                   -> carries a book
--   Paymaster        pension only (welfare hits were other firms sharing the name)       -> payroll bureau
--   PathMark HR      pension only                                                        -> ASO (self-declared)
--   Nexus HR         pension only                                                        -> ASO
--   AGS Payroll      pension only, 12,826 participants                                   -> payroll/paymaster
--   Wurk             pension only                                                        -> software
--
-- TWO LIMITS, written down so nobody over-reads the test later:
--   * Absence is not proof. A welfare plan under 100 participants is exempt from filing.
--   * Name matching contaminates. "Paymaster" pulled in BC Paymaster and Top Paymaster, unrelated
--     firms. Every welfare hit must be tied back by EIN before it counts.
--
-- AND THE DESIGNATION RULE: a PEO/ASO designation is never applied to a sponsor's CLIENTS until the
-- designation itself is vetted. Paychex is the reason - it runs both a PEO book and an ASO book and
-- does not break them out publicly, so a Paychex client could be either.

alter table public.mep_sponsor_identity
  add column if not exists designation_status text not null default 'provisional',
  add column if not exists welfare_filings int,
  add column if not exists pension_filings int,
  add column if not exists max_welfare_participants int,
  add column if not exists max_pension_participants int,
  add column if not exists clients_may_inherit boolean not null default false;

comment on column public.mep_sponsor_identity.designation_status is
  'provisional = named from evidence but not vetted; vetted = confirmed and safe to apply to clients.';
comment on column public.mep_sponsor_identity.clients_may_inherit is
  'When false, this sponsor service model must NOT be stamped onto its client companies. Default false on purpose.';

create or replace view public.v_sponsor_welfare_signal as
select s.ein as sponsor_ein,
       max(s.sponsor_name) as sponsor_name,
       count(*) filter (where s.benefit_kind = 'welfare') as welfare_filings,
       count(*) filter (where s.benefit_kind = 'pension') as pension_filings,
       max(s.tot_participants) filter (where s.benefit_kind = 'welfare') as max_welfare_participants,
       max(s.tot_participants) filter (where s.benefit_kind = 'pension') as max_pension_participants,
       (count(*) filter (where s.benefit_kind = 'welfare') > 0
        and count(*) filter (where s.benefit_kind = 'pension') > 0) as carries_both,
       string_agg(distinct s.plan_name, ' | ') filter (where s.benefit_kind = 'welfare') as welfare_plans
  from public.efast_5500_staging s
 where s.ein is not null and s.sponsor_name is not null
 group by s.ein;

update public.mep_sponsor_identity set
  sponsor_class='peo', designation_status='vetted', clients_may_inherit=true,
  welfare_filings=8, pension_filings=5, max_welfare_participants=1420, max_pension_participants=3069,
  evidence = evidence || ' WELFARE TELL 2026-09-11: files health & welfare 5500s (Kaiser Foundation Health Plan of the Northwest, Unum life and disability, 1,420 participants) alongside the 401(k) MEP. Carries client health - PEO confirmed.'
 where sponsor_ein='931277996';

update public.mep_sponsor_identity set
  sponsor_class='peo', designation_status='vetted', clients_may_inherit=true,
  welfare_filings=6, pension_filings=5, max_welfare_participants=1086, max_pension_participants=2245,
  evidence = evidence || ' WELFARE TELL 2026-09-11: EMPLOYCO USA, INC. HEALTH AND WELFARE BENEFITS PLAN, 1,086 participants, filed under a second EIN. Carries client health - PEO confirmed.'
 where sponsor_ein='203151312';

update public.mep_sponsor_identity set
  sponsor_class='payroll_bureau', designation_status='vetted', clients_may_inherit=false,
  welfare_filings=0, pension_filings=17, max_pension_participants=662,
  evidence = evidence || ' WELFARE TELL 2026-09-11: no welfare filing under EIN 65-0580656. The welfare hits on the name belong to BC Paymaster LLC and Top Paymaster, unrelated firms. Payroll bureau confirmed - its MEP participants are NOT PEO clients.'
 where sponsor_ein='650580656';

update public.mep_sponsor_identity set
  sponsor_class='aso', designation_status='vetted', clients_may_inherit=false,
  welfare_filings=0, pension_filings=4, max_pension_participants=251,
  evidence = evidence || ' WELFARE TELL 2026-09-11: no welfare filing, consistent with its own site calling it an ASO. Keep in the system designated ASO; clients are not PEO clients.'
 where sponsor_ein='814987330';

update public.mep_sponsor_identity set
  sponsor_class='aso', designation_status='provisional', clients_may_inherit=false,
  welfare_filings=0, pension_filings=3, max_pension_participants=227,
  evidence = evidence || ' WELFARE TELL 2026-09-11: no welfare filing. Leans ASO, but the book is small enough that a sub-100-participant welfare plan would be exempt, so absence proves nothing. Provisional.'
 where sponsor_ein='831618245';

update public.mep_sponsor_identity set
  sponsor_class='software', designation_status='vetted', clients_may_inherit=false,
  welfare_filings=0, pension_filings=6, max_pension_participants=7091,
  evidence = evidence || ' WELFARE TELL 2026-09-11: no welfare filing despite 7,091 pension participants. A PEO that size would be carrying health. Technology vendor confirmed.'
 where sponsor_ein='812794951';

update public.mep_sponsor_identity set
  sponsor_class='payroll_bureau', designation_status='vetted', clients_may_inherit=false,
  welfare_filings=0, pension_filings=5, max_pension_participants=12826,
  evidence = evidence || ' WELFARE TELL 2026-09-11: no welfare filing despite 12,826 pension participants - the strongest negative in the set. Payroll/common-paymaster confirmed.'
 where sponsor_ein='832603713';

update public.mep_sponsor_identity set
  sponsor_class='peo', designation_status='provisional', clients_may_inherit=false,
  welfare_filings=6, pension_filings=5, max_welfare_participants=289, max_pension_participants=367,
  evidence = evidence || ' WELFARE TELL 2026-09-11: files a group welfare plan (LOTUS HR / GROUP 78296, 289 participants) every year 2020-2025 alongside a 401(k) with 367. Welfare participants far exceed its own 11-50 headcount, so it is carrying a client book. Upgraded from small HR firm to probable PEO - provisional until co-employment is confirmed.'
 where sponsor_ein='274313896';

update public.mep_sponsor_identity set
  sponsor_class='peo', designation_status='provisional', clients_may_inherit=false,
  welfare_filings=7, pension_filings=1, max_welfare_participants=282, max_pension_participants=363,
  evidence = 'Mississippi. Unidentifiable on the web - no site, no registry hit, no trademark. The welfare tell found it: separate DENTAL and MEDICAL welfare plans (282 participants) across 2 EINs plus a 401(k) with 363. That is a benefits book, not an office of fifteen people. Probable small PEO - provisional until the entity itself is identified.'
 where sponsor_ein='880883913';

insert into public.mep_sponsor_identity
  (sponsor_ein, plan_name, sponsor_name, sponsor_class, is_protected, designation_status,
   clients_may_inherit, welfare_filings, pension_filings, max_welfare_participants,
   max_pension_participants, evidence, decided_by)
values ('454813650','EMPOWER HR RETIREMENT SAVINGS PLAN','EMPOWER HR, LLC','peo',false,'provisional',
  false, 10, 5, 8955, 12033,
  'WELFARE TELL 2026-09-11: EMPOWER HR, LLC. HEALTH AND WELFARE BENEFIT PLAN with 8,955 participants plus a 401(k) with 12,033. A PEO carrying a full client book - this reverses the earlier read of contaminated/unclear. CAUTION: EIN 45-4813650 is shared with eight unrelated sponsors (ABC of Iowa, AGC Mississippi, Caravan Health, Charter School Associates, Junior Achievement USA, Leisure Care, Oklahoma AGC, Builders Exchange of the Southern Tier) - another administrator EIN. EmPower HR is a Vensure acquisition and under standing law keeps its own identity; it is NOT aggregated into Vensure. Provisional until its client rows are separated from the other eight sponsors on that EIN.',
  'instanceA_0839')
on conflict (sponsor_ein, plan_name) do update
  set sponsor_class=excluded.sponsor_class, designation_status=excluded.designation_status,
      clients_may_inherit=excluded.clients_may_inherit, welfare_filings=excluded.welfare_filings,
      pension_filings=excluded.pension_filings,
      max_welfare_participants=excluded.max_welfare_participants,
      max_pension_participants=excluded.max_pension_participants,
      evidence=excluded.evidence, decided_at=now();

insert into public.brain_knowledge (scope, key, content)
values ('doctrine','service_model_designation_law',
 'A sponsor is designated peo, aso, payroll_bureau, software, association_mep, tpa_administrator or single_employer - and that designation is NEVER stamped onto its client companies until designation_status = vetted AND clients_may_inherit = true. Gazz 2026-09-11. The welfare tell is the primary evidence: a sponsor filing a health & welfare 5500 alongside a pension 5500 is carrying client health, which is the PEO signature. Two limits: a welfare plan under 100 participants is exempt from filing so absence never proves "not a PEO", and welfare plans are often filed under a different EIN so the match must be made on name AND tied back by EIN. ASOs stay in the system, designated ASO, with their clients NOT counted as PEO clients. Paychex is the worked example of why vetting comes first: it runs a large PEO book and a large ASO book and does not break them out publicly, so no Paychex client may be assigned a service model from the aggregate.');