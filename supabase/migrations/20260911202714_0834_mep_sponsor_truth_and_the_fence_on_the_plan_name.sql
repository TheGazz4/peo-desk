-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0834-mep-sponsor-truth
-- Articles implemented: II.1 (resolve to the real entity), III.1 (fences at the door),
--   VI.1 (visible quarantine), XI.1 (one door)
-- Articles verified not violated: II.2 (no merge on a colliding name), XIV.6, IX.2 (nothing deleted)
-- Verification query attached: YES
--
-- THE MEP LANE WAS CREDITING PLAN ADMINISTRATORS WITH OTHER PEOPLE'S CLIENT BOOKS
--
-- The PEO's identity was taken from sponsor_ein. That is wrong: the EIN on a Form 5500 filing is
-- often the THIRD-PARTY ADMINISTRATOR'S, not the sponsor's, and one administrator files for dozens
-- of unrelated plans. EIN 20-3886993 is National Benefit Services, LLC, a Utah retirement-plan TPA
-- (370 staff, 6,000 plans, 20,000 employers - not a PEO). Under that one EIN our loader found a
-- dozen unrelated plans and credited ALL of their participating employers to one name it happened
-- to pick: "Medical Management Consultants, Inc", a Los Angeles medical group with its own 401(k).
-- MMC appeared to have 562 client companies. It has about 100, and they are its own employees'
-- employers, not PEO clients.
--
-- 78 of 264 sponsor slugs and 12,931 of 54,455 client EINs sit on a filing EIN that carries more
-- than one distinct sponsor name. Those are the rows whose PEO identity cannot be trusted.
--
-- WORSE: one plan swept up this way is HELPSIDE INC. 401(K) PLAN - 400 employers in 2024.
-- Helpside is noncompete-protected. is_noncompete_peo('HELPSIDE INC. 401(K) PLAN') already returns
-- TRUE - the fence was simply never asked. The loader tested only the derived slug
-- ("medicalmanagementconsultantsinc"), which is not a protected name, so the fence never fired.
--
-- This migration flags the untrustworthy rows, fences the protected plans, and records what each
-- sponsor actually is. It DELETES NOTHING. Purging the protected rows is Gazz's call, filed as a ruling.

create table if not exists public.mep_sponsor_identity (
  sponsor_ein     text not null,
  plan_name       text not null,
  sponsor_name    text,
  sponsor_class   text not null,
  is_protected    boolean not null default false,
  evidence        text,
  decided_by      text not null,
  decided_at      timestamptz not null default now(),
  primary key (sponsor_ein, plan_name)
);

alter table public.mep_sponsor_identity enable row level security;

do $p$
begin
  if not exists (select 1 from pg_policies where tablename='mep_sponsor_identity' and policyname='mep_sponsor_identity_read') then
    create policy mep_sponsor_identity_read on public.mep_sponsor_identity
      for select to service_role, authenticated using (true);
  end if;
end $p$;

-- mep_peo_book is a view over form5500_mep_participants; flag on the base table
alter table public.form5500_mep_participants
  add column if not exists identity_trust text;

with norm as (
  select ein as sponsor_ein,
         regexp_replace(upper(regexp_replace(coalesce(sponsor_name,''),'[^A-Za-z0-9 ]','','g')),'\s+',' ','g') nm
    from public.efast_5500_staging
   where sponsor_name is not null and ein is not null
), multi as (
  select sponsor_ein from norm group by 1 having count(distinct nm) > 1
)
update public.form5500_mep_participants m
   set identity_trust = 'UNTRUSTED: filing EIN carries plans for more than one sponsor; PEO identity must be re-derived at the plan grain (0834)'
  from multi x
 where x.sponsor_ein = m.sponsor_ein
   and m.identity_trust is null;

update public.form5500_mep_participants m
   set identity_trust = 'PROTECTED: this plan belongs to a noncompete-listed organisation. Never display, profile, append or work. It reached this table because the fence was tested on the derived slug, not the plan name (0834).'
 where public.is_noncompete_peo(m.plan_name);

-- the fence gets asked properly from now on: slug OR plan name OR sponsor name
create or replace function public.mep_row_is_protected(p_slug text, p_plan_name text, p_sponsor_name text)
returns boolean language sql stable as $mp$
  select coalesce(public.is_noncompete_peo(p_slug), false)
      or coalesce(public.is_noncompete_peo(p_plan_name), false)
      or coalesce(public.is_noncompete_peo(p_sponsor_name), false);
$mp$;

insert into public.mep_sponsor_identity
  (sponsor_ein, plan_name, sponsor_name, sponsor_class, is_protected, evidence, decided_by)
values
 ('203886993','HELPSIDE INC. 401(K) PLAN','HELPSIDE INC.','peo',true,
  'Form 5500 sponsor is HELPSIDE INC., Lindon UT, 11,702 participants (2024). Filed under TPA EIN 20-3886993 (National Benefit Services). Helpside is noncompete-protected: never display, profile, append or work. In form year 2022 this plan filed under Helpside own EIN 87-0476353.','instanceA_0834'),
 ('203886993','MMC 401(K) SAVINGS AND RETIREMENT PLAN','MEDICAL MANAGEMENT CONSULTANTS, INC','single_employer',false,
  'Los Angeles CA medical group, dba MMC, about 1,981 participants (2024). Its own 401(k); filed in 2022 under its own EIN 95-3879274. Not a PEO. The 562 clients credited to it were other plans sharing the TPA filing EIN.','instanceA_0834'),
 ('203886993','CALIFORNIA FARM BUREAU MEMBER EMPLOYER RETIREMENT PLAN (MEP)','CALIFORNIA FARM BUREAU FEDERATION','association_mep',false,
  'Sacramento CA trade association MEP for member farms. Not a PEO.','instanceA_0834'),
 ('203886993','MANUFACTURERS RETIREMENT & SAVINGS PLAN','NATIONAL ASSOCIATION OF MANUFACTURERS','association_mep',false,
  'Trade association MEP. Not a PEO.','instanceA_0834'),
 ('203886993','MRA MEMBER 401(K) PLAN','MASSACHUSETTS RESTAURANT ASSOCIATION','association_mep',false,
  'Trade association MEP. Not a PEO.','instanceA_0834'),
 ('203886993','THE ASSOCIATION 401(K) PLAN','LAS VEGAS METRO CHAMBER OF COMMERCE','association_mep',false,
  'Chamber of commerce MEP. Not a PEO.','instanceA_0834'),
 ('203886993','ASSOCIATED BUILDERS AND CONTRACTORS, INC UTAH CHAPTER MEP','ASSOCIATED BUILDERS AND CONTRACTORS INC - UTAH CHAPTER','association_mep',false,
  'Trade association MEP. Not a PEO.','instanceA_0834'),
 ('203886993','WESTERN REGIONS NECA 401(K) PLAN','BOARD OF TRUSTEES, WESTERN REGIONS NECA 401(K) PLAN','association_mep',false,
  'Union/trade board MEP. Not a PEO.','instanceA_0834'),
 ('203886993','THE ACCESS POOLED EMPLOYER PLAN - SERIES 1','ACCESS PLANS LLC','tpa_administrator',false,
  'Pooled employer plan provider, Wylie TX. A PEP is not a PEO.','instanceA_0834'),
 ('203886993','STAGWELL GLOBAL 401(K) PLAN','STAGWELL GLOBAL LLC','single_employer',false,
  'Marketing holding company own plan. Not a PEO.','instanceA_0834'),
 ('203886993','THE WINDERMERE 401(K) PLAN','WINDERMERE REAL ESTATE SERVICES COMPANY','single_employer',false,
  'Real estate franchisor own plan. Not a PEO.','instanceA_0834'),
 ('203886993','NBS RETIREMENT READINESS PLAN','NATIONAL BENEFIT SERVICES, LLC','tpa_administrator',false,
  'National Benefit Services LLC, Salt Lake City UT, founded 1986: third-party administrator and recordkeeper for retirement plans, FSA/HSA and COBRA. 370+ staff, 6,000+ plans, 20,000+ employers. Administers plans; does not co-employ. This is the EIN that was being read as a PEO.','instanceA_0834'),
 ('203886993','NATIONAL BENEFIT SERVICES, LLC WELFARE BENEFIT PLAN','NATIONAL BENEFIT SERVICES, LLC','tpa_administrator',false,
  'Same administrator, welfare plan. Not a PEO.','instanceA_0834'),
 ('931277996','XENIUM 401(K) RETIREMENT SAVINGS PLAN','XENIUM RESOURCES, INC','peo',false,
  'Xenium HR, Tualatin OR (xeniumhr.com). Genuine PEO/ASO: about 425 clients, 18,000+ worksite employees, 50 states. Founded about 1998 out of Express Employment Professionals, independent since 2000, owned by The Stoller Group. Not on the IRS CPEO list. 182 client EINs observed here.','instanceA_0834'),
 ('203151312','OUTSOURCING STRATEGIES, INC. 401(K) PROFIT SHARING PLAN','OUTSOURCING STRATEGIES, INC','peo',false,
  'Legal entity behind EMPLOYCO USA, Westmont IL (employco.com). Genuine PEO - markets co-employment plus benefits and risk administration; owns the EMPLOYCO trademark (filed 2000). About 30 years operating. Not on the IRS CPEO list. 60 client EINs observed here.','instanceA_0834'),
 ('650580656','PAYMASTER, INC. MULTIPLE EMPLOYER 401(K) PLAN','PAYMASTER, INC','payroll_bureau',false,
  'PayMaster Payroll Service, Boynton Beach FL (paymaster.com), founded 1995. Independent payroll bureau, SOC 1 Type II, IPPA member. It sponsors a multiple-employer 401(k), which is why it looks PEO-shaped in 5500 data, but it does not co-employ. Do not treat its plan participants as PEO clients.','instanceA_0834'),
 ('814987330','PATHMARK HR, INC. 401(K) PSP','PATHMARK HR, INC','aso',false,
  'Westerville OH (pathmarkhr.com). Self-describes as an ASO (administrative services organization), explicitly not co-employment. Adjacent to the PEO market but not a PEO.','instanceA_0834'),
 ('812794951','WURK 401(K) PLAN','WURKFORCE, INC','software',false,
  'Wurk / enjoywurk.com, Denver CO. Cannabis-industry HCM software with managed payroll and benefits. A technology vendor, not a co-employer.','instanceA_0834'),
 ('832603713','AGS PAYROLL SERVICES LLC 401K PLAN','AGS PAYROLL SERVICES, LLC','payroll_bureau',false,
  'Montebello NY. No public website and no PEO marketing; appears to be an in-house common-paymaster entity for an affiliated home-care/nursing group. Not a PEO selling co-employment.','instanceA_0834'),
 ('831618245','HR SUITE, LLC DBA NEXUS HR SERVICES RETIREMENT SAVINGS PLAN','HR SUITE, LLC DBA NEXUS HR SERVICES','aso',false,
  'Nexus HR, Sacramento CA (nexushr.com), founded 2019, 11-50 staff. Outsourced HR/payroll/recruiting on PrismHR. Does not market co-employment. Treat as ASO, not PEO, unless better evidence arrives.','instanceA_0834'),
 ('274313896','LOTUS HR, INC. 401(K) PLAN','LOTUS HR, INC','aso',false,
  'Montgomery AL (lotushr.biz). Small HR services firm - payroll, benefits admin, compliance. Does not claim PEO status. Unrelated to the UK/Canada Lotus HR consultancy.','instanceA_0834'),
 ('880883913','STRATEGIC BENEFITS PLUS, LLC 401(K) PLAN','STRATEGIC BENEFITS PLUS, LLC','unknown',false,
  'UNRESOLVED. No website, no state registry hit, no trademark. EIN prefix 88 suggests registration about 2022 or later. 15 client EINs. Needs a state-registry or full Form 5500 pull before it is classified.','instanceA_0834')
on conflict (sponsor_ein, plan_name) do update
  set sponsor_class = excluded.sponsor_class,
      is_protected  = excluded.is_protected,
      evidence      = excluded.evidence,
      decided_by    = excluded.decided_by,
      decided_at    = now();