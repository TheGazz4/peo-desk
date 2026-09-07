-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-07-mep-sponsor-adjudication
-- Articles implemented: VI.2 (reconciliation receipt), XIV.1 (registry gate honoured, never bypassed),
--   Mesh Cross-Reference Mandate 1 (canonical resolution), 5 (name normalization), 6 (quarantine, never merge)
-- Articles verified not violated: noncompete law (Helpside/Lever1/A Plus/AAA untouched),
--   peo_vs_aso_separation_law (ASO/payroll and association MEPs are NOT promoted as PEO clients),
--   Paychex PEP rule (pooled employer plans never promoted; Oasis is the PEO book, registered separately),
--   vensure aggregation ruling (acquired PEOs keep their own identity)
-- Verification query attached: YES

-- ============================================================================
-- 0763  MEP sponsor adjudication - registry + seed
--
-- 166 Form 5500 multiple-employer plan sponsors were holding 9,064 company
-- records in the XIV.1 registry gate. Every one was researched (company site,
-- NAPEO directory, IRS CPEO list, state PEO / worker-leasing registries).
-- Real PEOs are registered and canonicalised; everything else is quarantined
-- and can never be promoted as a PEO client.
-- ============================================================================

set role peo_gatekeeper;

create table if not exists public.mep_sponsor_registry (
  mep_slug              text primary key,
  verdict               text not null check (verdict in
                          ('PEO','ASO_PAYROLL','ASSOCIATION_MEP','OPERATING_COMPANY','UNKNOWN')),
  canonical_family_slug text,
  brand_name            text,
  website               text,
  evidence              text,
  decided_by            text not null default 'instanceA-2026-09-07-mep-sponsor-adjudication',
  decided_at            timestamptz not null default now(),
  constraint mep_sponsor_registry_peo_needs_family
    check (verdict <> 'PEO' or canonical_family_slug is not null)
);

alter table public.mep_sponsor_registry enable row level security;

comment on table public.mep_sponsor_registry is
  '0763: adjudication of Form 5500 MEP plan sponsors. verdict=PEO means the sponsor is a real professional employer organisation and its participants may be attributed as clients of canonical_family_slug. Any other verdict is a standing refusal: those participants are never promoted as PEO clients (peo_vs_aso_separation_law).';

insert into public.mep_sponsor_registry
  (mep_slug, verdict, canonical_family_slug, brand_name, website, evidence)
values
('alcotthrgroupllc','PEO','alcotthr','Alcott HR','alcotthr.com','NY DOL PEO registry'),
('anthrosinc','PEO','anthros','Anthros','anthrosinc.com','Winter Park FL chamber: professional employer organization'),
('armhrllc','PEO','armhr','ArmHR',null,'NY DOL PEO registry'),
('aspenhrpeollc','PEO','aspenhr','Aspen HR',null,'NY DOL PEO registry'),
('avalonhrllc','PEO','avalonhr','Avalon HR','avalonhr.com','NAPEO member; Oklahoma licensed PEO list'),
('charterhrinc','PEO','charterhr','Charter HR','mycharterhr.com','Site FAQ explains PEO co-employment model'),
('eemployerssolutionsinc','PEO','esi','eEmployers Solutions',null,'KY, NY and CT PEO registries'),
('emplovallc','PEO','emplova','Emplova','emplova.com','KY, NY and CT PEO registries'),
('employeeresourceadministrationlp','PEO','employeeresourceadministration','Employee Resource Administration',null,'StaffMarket PEO profile; Texas PEO directory'),
('employerchoice','PEO','choiceemployersolutions','Choice Employer Solutions',null,'Sponsor Choice Employer Solutions Inc, Tampa; NY/CT PEO registries'),
('extensisgroupllc','PEO','extensishr','ExtensisHR','extensishr.com','Named Top 3 Professional Employer Organization'),
('howardleasinginc','PEO','howardleasing','Howard Leasing','howardleasinginc.com','Bradenton FL PEO; StaffMarket profile'),
('hrdeliveredllc','PEO','hrdelivered','HRDelivered','hrdelivered.com','Site: Your Full-Service PEO Provider'),
('humancapitalconceptsllc','PEO','humancapitalconcepts','Human Capital Concepts','hcchr.com','OneDigital release: PEO and HR consulting firm'),
('keyhrllc','PEO','keyhr','KeyHR','keyhro.com','Dedicated PEO service page; StaffMarket directory'),
('lonestarpeoinc','PEO','lonestarpeo','Lone Star PEO','lonestarpeo.com','Own site sells PEO services; Texas'),
('newtonpeollc','PEO','newtonpeo','Newton PEO',null,'NC DOI active PEO licensee list'),
('paydayinc','PEO','payday','Payday HCM','paydayhcm.com','Registered family; NM HCM/PEO provider'),
('propelpeoinc','PEO','propelhr','Propel HR','propelhr.com','KY and NY PEO registries: Propel PEO Inc dba Propel HR'),
('resourcingedgeillc','PEO','resourcingedge','Resourcing Edge','resourcingedge.com','Site PEO services page; OneDigital PEO vertical'),
('rmpersonnelinc','PEO','rmpersonnel','RMPersonnel','rmpersonnel.com','Dedicated PEO services and company history pages'),
('thes2hrgroupllc','PEO','engage','Engage PEO','engagepeo.com','NY DOL PEO registry: S2 HR Solutions dba Engage PEO'),
('unitedemployeeservicesinc','PEO','unitedemployeeservices','United Employee Services','uespeo.com','Dedicated PEO site, Clearwater FL'),
('alphastaffgroupinc','PEO','alphastaff','AlphaStaff','alphastaff.com','Own site AlphaStaff PEO Services page'),
('decisionhrinc','PEO','decisionhr','DecisionHR',null,'Press: one of five largest privately held PEOs in US'),
('erigoincnorthkeycommunitycare','PEO','erigo','Erigo Employer Solutions','erigoes.com','NAPEO member; site titled PEO'),
('essentialhrinc','PEO','firststarhr','FirstStarHR','firststarhr.com','Site states PEO and ASO with co-employment; Dallas TX'),
('ga_partners','PEO','gapartners','G&A Partners','gnapartners.com','Own site sells PEO services; acquires other PEOs'),
('prosystemscorporation','PEO','proresources','PRO Resources','proresourceshr.com','Site: we operate as a Professional Employment Organization'),
('staffleasingincandaffiliates','PEO','staffleasing','Staff Leasing',null,'NY DOL PEO registry'),
('swbcprofessionalemployerservicesvllc','PEO','swbc','SWBC PEO','swbcpeo.com','DOL MEWA filing SWBC PES V, EIN 27-3708085'),
('thealliancegroup','PEO','alliance','Alliance Group','alliance-peo.com','Site: largest and oldest PEO in Nebraska'),
('throutsourcingllc','PEO','trendhr','TrendHR','trendhr.com','Site: DFW PEO, Staffing and HR Consulting'),
('vestedhriillc','PEO','vestedhr','Vested HR Solutions','vestedhr.com','NAPEO member; Florida PEO co-employment'),
('atxpeoservicesinc','PEO','ataraxis','Ataraxis PEO','ataraxis.com','NY DOL PEO registry; plan name Ataraxis PEO'),
('cornerstoneinnovationsincdbadiversifiedemployeesolutions','PEO','ataraxis','Ataraxis PEO','ataraxis.com','DES/CII rebranded to Ataraxis'),
('simployinc','PEO','simploy','Simploy','simploy.com','KY, NY and CT PEO registries'),
('premployerinc','PEO','premployer','PRemployer','premployerinc.com','CT PEO list; own site markets PEO, Dothan AL'),
('ceohrinc','PEO','ceohr','CEOHR','ceopeo.com','Engage PEO acquired CEOHR 2022; Florida PEO'),
('genesishrsolutionsinc','PEO','genesishr','Genesis HR Solutions','genesishrsolutions.com','KY, NY and CT PEO registries'),
('vensure_family','PEO','vensure','Vensure','vensure.com','Retired slug; canonicalised by ruling 0755'),
('execustaffhrinc','PEO','execustaffhr','Execustaff HR','equityhr.com','San Jose PEO; rebranded EquityHR'),
('landrumprofessionalemployerservicesinc','PEO','landrumhr','LandrumHR','landrumhr.com','IRS Certified Professional Employer Organization'),
('lyonscompanyinc','PEO','lyonshr','Lyons HR','lyonshr.com','Alabama PEO; The Lyons and Company is parent entity'),
('prestigeemployeeadministratorsinc','PEO','prestigepeo','PrestigePEO','prestigepeo.com','NY DOL PEO registry; site markets co-employment'),
('realtimepeoiillc','PEO','realtimepeo','RealTime PEO',null,'StaffMarket PEO directory profile'),
('dynamichumanresourcesinc','PEO','dynamichr','DynamicHR','dynamichr.com','Site: Michigan largest local independent PEO'),
('intandemhumanresourcesllc','PEO','intandemhr','InTANDEM HR',null,'NAPEO member directory; Colorado CPEO'),
('payrollmadeeasyincdbacontinuumhr','PEO','continuumhr','Continuum HR',null,'Florida DBPR licensed Employee Leasing Company Group'),
('oasis','PEO','oasis','Oasis Outsourcing','paychex.com','Paychex acquired Oasis Outsourcing PEO 2018; the Paychex PEO book, not the PEP'),
('cardinalservicesinc','PEO','cardinalservices','Cardinal Services','cardinalservices.com','Own site Co-Employment page; EIN 930985752 matches'),
('employerservicescorporation','PEO','employerservicescorp','Employer Services Corporation',null,'NY DOL PEO registry'),
('workforcebusinessservicesinc','PEO','workforcebusinessservices','Workforce Business Services','gowbs.com','Site: The Leading PEO in the Blue Collar Industry'),
('procarehrcorporationi','PEO','procarehr','ProCare HR',null,'NY DOL PEO registry: PROCare HR Corp II'),
('pandollc','PEO','pando','Pando PEO','pandopeo.com','Own site markets professional employer organization'),
('onondagaemployeeleasingservicesinc','PEO','onondagaemployeeleasing','Onondaga Employee Leasing',null,'NY DOL PEO registry'),
('pbsasollc','PEO','pbspeo','PBS PEO','pbspay.com','Alabama/NY/KY PEO registries; site says As a PEO'),
('pbspeoservicesllc','PEO','pbspeo','PBS PEO','pbspay.com','Legal name contains PEO Services; same brand as PBS ASO'),
('concurrenthrollc','PEO','concurrenthro','Concurrent HRO','concurrenthro.com','KY approved PEO list; acquired by PrestigePEO'),
('intelliproserviceinc','PEO','intellipro','IntelliPro Group','intelliproservices.com','NY registered PEO list; PEO co-employment page'),
('uniquestaffleasingiltd','PEO','uniquehr','UniqueHR','unique-hr.com','NY PEO registry: Unique Staff Leasing III; Texas employee leasing'),
('cspmanagementincdbapartnersolutionsforschools','PEO','partnersolutions','Partner Solutions','mypartnersolutions.com','Site: we co-employ your teachers and staff'),
('exodushrllc','PEO','exodushr','Exodus HR Group','exodushrgroup.com','Site offers PEO vs ASO choice; TN/OK'),
('kimstaffhrinc','PEO','kimstaffhr','KimstaffHR','ktimehr.com','Connecticut PEO registry; California PEO directory'),
('cornerstoneemployersolutionsllcdbasynchronyhr','PEO','synchronyhr','SynchronyHR','synchronyhr.com','Cornerstone Employer Solutions on KY, NY, CT PEO registries'),
('managedbusinessservicesinc','PEO','managedpay','ManagedPAY','managedpay.com','Site lists PEO among HCM offerings'),
('resourcemanagementsystemsi','PEO','resourcemanagementsystems','Resource Management Systems','rms-peo.com','Company website is rms-peo.com; PEO directories'),
('orbisholdingsgroupllc','PEO','orbisholdings','Orbis Holdings Group',null,'StaffMarket PEO profile; benefits, payroll, tax, WC for clients'),
('nexfirmllc','PEO','nexfirm','NexFirm','nexfirm.com','New York State registered PEO list'),
('midwestmanagementgroupinc','PEO','midwestmanagementgroup','Midwest Management Group','midwest-mgt.com','Employee leasing services to charter schools'),
('bearingtreeinc','PEO','bearingtree','Bearing Tree',null,'Kentucky approved PEO and New York PEO registries'),
('permastaffpersonnelsystemsinc','PEO','permastaff','PermaStaff','permastaff.com','Site: the oldest PEO in the Phoenix metropolitan area'),
('sullivansadministrativemanagersllc','PEO','sullivansadmin','Sullivans Administrative Managers','sullivanstaffing.com','HR outsourcing division of The Sullivan Group'),
('nationalemployeemanagementresourcesllc','PEO','nemr','NEMR Total HR','nemrhr.com','NAPEO find-a-PEO member directory; Marlton NJ'),
('teamworksbusinessservicesllc','PEO','teamworksgroup','Teamworks Group','teamworksgroup.com','Utah PEO acquired by G&A Partners 2024'),
('unitedamericanpayrollllc','PEO','unitedamericanpayroll','United American Payroll','uap1.com','Site: A Professional Employer Organization'),
('medbestmedicalmanagementinc','PEO','medbest','MedBest Medical Management','medbest.org','Self-describes as PEO; staff leasing to physician practices'),
('teamworkhumanresourcesinc','PEO','teamworkhr','Teamwork HR',null,'LinkedIn: is a Professional Employer Organization'),
('partnershumanresources','PEO','partnershr','Partners Human Resources','partners-hr.com','A licensed Oklahoma Professional Employer Organization'),
('passiohrinc','PEO','passiohr','PassioHR','passiopeo.com','PEO site passiopeo.com; StaffMarket profile, Denver CO'),
('tandiumcorporation','PEO','tandium','Tandium','tandium.com','Maryland PEO; site is entirely PEO co-employment content'),
('allpeoinc','PEO','allpeo','All PEO',null,'Licensed Oregon worker leasing company; court record confirms'),
('americanpayrollservicellc','PEO','americanpayrollservice','American Payroll Service','apspeo.com','Site states As a PEO; Boardman OH, serves OH/PA/GA'),
('stratuspeo1llc','PEO','stratuspeo','Stratus PEO','stratuspeo.com','Florida registry lists Stratus PEO 1 LLC'),
('impactoutsourcingssolutionsinc','PEO','impactworkforce','Impact Workforce Solutions','impactwfs.com','StaffMarket PEO profile; Griffin GA'),
('proalliancellc','PEO','proalliance','Pro Alliance',null,'Oregon active worker-leasing licence WLC000610, Lehi UT'),
('hrpartnersinc','PEO','hrpartners','HR Partners','gohrp.com','Site: PEO plus ASO/HRO services across 22 states'),
('keystonehrllc','PEO','keystonehr','Keystone HR','keystone-hr.com','Site tagline: An HR Solutions and PEO Company'),
('alohaworkforcemanagementsolutions','PEO','alohawms','Aloha WMS','alohawms.com','StaffMarket PEO profile; Hawaii PEO directory'),
('onesourceemployerservicesinc','PEO','onesourceaz','OneSource Employer Services','onesource-az.com','StaffMarket PEO profile; Arizona PEO'),
('onesourceleasingsolutionsinc','PEO','onesourceleasing','OneSource Leasing Solutions',null,'BBB category Employee Leasing, Wilkes-Barre PA; distinct from OneSource AZ'),
('totalbenefitmanagementinc','PEO','tbmpayroll','TBM Payroll','tbmpayroll.com','Site sells PEO co-employment; Glens Falls NY'),
('ascendhrllc','PEO','ascendhr','AscendHR','ascend-hr.com','Site markets White-Glove PEO Solutions'),
('backofficeriskinc','PEO','borpeo','Back Office Risk','borpeo.com','Site brands as PEO; RGV chamber PEO directory'),
('teamworxprollc','PEO','teamworx','TeamWorx','teamworxpro.com','Site has What is a PEO; Ohio chambers list Teamworx PEO'),
('ameriresourcegroupinc','PEO','ameristaff','AmeriResource Group','ameriresource.com','AmeriStaff is a licensed Professional Employer Organization'),
('xeniumresourcesinc','ASO_PAYROLL',null,'Xenium HR','xeniumhr.com','NOT on Oregon active worker-leasing licence list 9/1/26; site sells HR consulting only. Former PEO pre-2015'),
('agspayrollservicesllc','ASO_PAYROLL',null,'AGS Payroll',null,'Montebello NY payroll provider; absent from NY DOL registered PEO list'),
('pathmarkhrinc','ASO_PAYROLL',null,'Pathmark HR','pathmarkhr.com','Site brands itself An ASO Company; no co-employment'),
('lotushrinc','ASO_PAYROLL',null,'Lotus HR','lotushr.biz','Montgomery AL payroll/benefits admin; no co-employment found'),
('paymasterinc','ASO_PAYROLL',null,'PayMaster','paymaster.com','Florida payroll bureau; no co-employment offering'),
('wurkforceinc','ASO_PAYROLL',null,'Wurk','enjoywurk.com','Cannabis HCM platform; markets itself as a PEO alternative'),
('hrsuitellcdbanexushrservices','ASO_PAYROLL',null,'Nexus HR Services','nexushr.com','Remote HR/payroll outsourcing; not employer of record'),
('connorgallagheronesourceinc','ASO_PAYROLL',null,'Connor and Gallagher OneSource','gocgo.com','Insurance broker/HR outsourcer; markets PEO Alternative'),
('plansourcefinancialservicesinc','ASO_PAYROLL',null,'PlanSource','plansource.com','Benefits administration software/admin; no co-employment'),
('beacontristatesolutionsinc','ASO_PAYROLL',null,'Beacon Tri-State Solutions','beaconstaff.net','Payroll/benefits/WC admin; no co-employment claim'),
('teamahrllc','ASO_PAYROLL',null,'TEAM Risk Management Strategies','teamemployer.com','Household-employee payroll; site states no employer-of-record model'),
('hroneservicesinc','ASO_PAYROLL',null,'HR1 Services','hr1.com','Site calls itself off-site HR department (HRO); no co-employment'),
('outsourcingstrategiesinc','ASO_PAYROLL',null,'Outsourcing Strategies',null,'Westmont IL, payroll-services SIC; no PEO or co-employment source found'),
('medicalmanagementconsultantsinc','ASSOCIATION_MEP',null,'California Farm Bureau member plan / NBS',null,'EIN 20-3886993 is National Benefit Services (Utah TPA), not the named sponsor; plans are the CA Farm Bureau member MEP and a noncompete PEO plan. Mis-join - never promote'),
('employersassociationofnewjerseyiation','ASSOCIATION_MEP',null,'Employers Association of New Jersey','eanj.org','Nonprofit employer trade association member 401k'),
('cooperativebanksemployeesretirementassociation','ASSOCIATION_MEP',null,'CBERA','cbera.com','Retirement association for cooperative/savings bank member employers'),
('utahmanufacturersassociation','ASSOCIATION_MEP',null,'Utah Manufacturers Association',null,'State manufacturers trade association MEP'),
('trusteesofteamstersjointcouncilno73pensiontrustfund','ASSOCIATION_MEP',null,'Teamsters Joint Council No. 73',null,'Union-trusteed multiemployer pension trust fund'),
('ascafoundation','ASSOCIATION_MEP',null,'Ambulatory Surgery Center Association','ascassociation.org','ASCA member retirement plan program'),
('aflcioappalachiancouncilinc','ASSOCIATION_MEP',null,'AFL-CIO Appalachian Council',null,'Regional AFL-CIO labor council body'),
('unitedfederationofteachersanduftwelfarefund','ASSOCIATION_MEP',null,'UFT Welfare Fund','uft.org','Teachers union welfare fund plan for its own staff'),
('pensioncommitteeuftuftwfemployeespensionplan','ASSOCIATION_MEP',null,'UFT and UFT Welfare Fund','uft.org','Union pension committee plan for UFT staff'),
('guidedpracticesolutionsdentalllc','OPERATING_COMPANY',null,'GPS Dental','gps.dental','Dental support organisation, Jonesboro AR; takes equity in practices, not co-employment'),
('empowerhrllc','OPERATING_COMPANY',null,'Charter School Associates','charterschoolassociates.com','FALSE MERGE: sponsor EIN 454813650 is Charter School Associates, Coral Springs FL - NOT EmPower HR (Vensure, WI)'),
('bronxcenterforrehabilitationhealthcare','OPERATING_COMPANY',null,'Bronx Center (Centers Health Care)','centershealthcare.com','Skilled nursing facility group'),
('cassenacarellc','OPERATING_COMPANY',null,'Cassena Care','cassenacare.com','Nursing home and rehabilitation operator, Woodbury NY'),
('corusorthodontistsllc','OPERATING_COMPANY',null,'Corus Orthodontists','corusortho.com','Orthodontic practice partnership network'),
('integracare','OPERATING_COMPANY',null,'IntegraCare','integracare.com','Pennsylvania senior living operator'),
('kosservicesllc','OPERATING_COMPANY',null,'Dental Dreams','dentaldreams.com','Dental service organisation managing its own clinics'),
('thurstoncountytitlecompany','OPERATING_COMPANY',null,'Thurston County Title',null,'Title insurance/escrow company, Olympia WA'),
('surgerypartnersinc','OPERATING_COMPANY',null,'Surgery Partners','surgerypartners.com','Publicly traded surgical facility operator'),
('mortgageconnectlp','OPERATING_COMPANY',null,'Mortgage Connect LP',null,'Title/settlement services provider; controlled-group plan'),
('dcdautomotiveholdingsinc','OPERATING_COMPANY',null,'DCD Automotive Holdings',null,'Auto dealership holding group'),
('wasatchpropertymanagementinc','OPERATING_COMPANY',null,'Wasatch Property Management','wasatchgroup.com','Apartment property management, Salt Lake City'),
('zingermanscommunityofbusinesses','OPERATING_COMPANY',null,'Zingermans Community of Businesses','zingermans.com','Ann Arbor food business group'),
('curtissquireinc','OPERATING_COMPANY',null,'Curtis Squire','curtissquire.com','Private holding company: broadcasting, senior living, real estate'),
('unbridledsolutionsllc','OPERATING_COMPANY',null,'Unbridled','unbridled.com','Denver corporate event-management agency'),
('mortgageresearchcenterllc','OPERATING_COMPANY',null,'Veterans United Home Loans','veteransunited.com','VA mortgage lender, Columbia MO'),
('dobbsmanagementservicellc','OPERATING_COMPANY',null,'Dobbs Companies','dobbsmanagement.com','Memphis family holding company'),
('wileymanagementinc','OPERATING_COMPANY',null,'Wiley Management','wileymanagementinc.com','Wendys franchise operator, Epsom NH'),
('theavemariafoundation','OPERATING_COMPANY',null,'Ave Maria Foundation',null,'Michigan Catholic nonprofit foundation group'),
('imccompaniesllc','OPERATING_COMPANY',null,'IMC Companies','imccompanies.com','Memphis intermodal drayage and logistics group'),
('elementelectronicsholdingsllc','OPERATING_COMPANY',null,'Element Electronics','elementelectronics.com','TV manufacturer, Winnsboro SC'),
('bellhavenmanagemenllcdba','OPERATING_COMPANY',null,'Bellhaven Center','bellhavencenter.com','Medicare-certified nursing home, Brookhaven NY'),
('pgttruckinginc','OPERATING_COMPANY',null,'PGT Trucking','pgttrucking.com','Flatbed trucking carrier, Aliquippa PA'),
('crossovermarketllc','OPERATING_COMPANY',null,'Crossover','crossover.com','Remote-talent marketplace, Austin TX'),
('jakesweeneyautomotiveinc','OPERATING_COMPANY',null,'Jake Sweeney Automotive','jakesweeney.com','Cincinnati car dealership group'),
('princetonacquisitionllc','OPERATING_COMPANY',null,'Princeton Acquisition',null,'Southfield MI property/apartment management'),
('hydromatincofstlouismo','OPERATING_COMPANY',null,'Hydromat','hydromat.com','Machine tool manufacturer, St. Louis MO'),
('innosourceinc','OPERATING_COMPANY',null,'InnoSource','innosource.com','Columbus OH staffing agency; no co-employment offering'),
('formosaplasticscorporationusa','OPERATING_COMPANY',null,'Formosa Plastics Corporation USA','formosaplasticsusa.com','Petrochemical manufacturer'),
('germainautomotivepartnershipinc','OPERATING_COMPANY',null,'Germain Automotive Partnership','germaincars.com','Columbus OH car dealership group'),
('bjuinc','OPERATING_COMPANY',null,'Bob Jones University','bju.edu','Private university, Greenville SC'),
('energynorthinc','OPERATING_COMPANY',null,'Energy North','energytogo.com','Petroleum/propane distributor, Lawrence MA'),
('vogelholdinginc','OPERATING_COMPANY',null,'Vogel Holding','vogelholdinginc.com','Waste hauling and landfill holding company, Mars PA'),
('eyecenterofcolumbusllc','OPERATING_COMPANY',null,'Eye Center of Columbus','eyecenterofcolumbus.com','Ophthalmology practice; participant in an open MEP, not a sponsor'),
('southwestelectricalcontractingservicesltd','OPERATING_COMPANY',null,'Southwest Electrical Contracting Services','swecs.com','Texas electrical contracting firm'),
('ltcaccountingservicesllc','OPERATING_COMPANY',null,'LTC Accounting Services',null,'Accounting/bookkeeping firm, Sallisaw OK'),
('highroadpeollc','UNKNOWN',null,'High Road PEO','highroadpeo.com','Idaho PEO, but 2025 merger with a noncompete PEO reported - held for ruling'),
('regis','UNKNOWN',null,null,null,'Plan name mixes ECM Holding Group and Stratus Solutions; sponsor unresolved'),
('strategicbenefitsplusllc','UNKNOWN',null,'Strategic Benefits Plus',null,'Flowood MS LLC formed 2022; no website or service description'),
('phoenixfinancialservicesllc','UNKNOWN',null,null,null,'Name collides with debt-collection agency and NY wealth firm; no PEO evidence'),
('riverholdingcompany','UNKNOWN',null,'River Holding Company',null,'Wisconsin EIN prefix; no identifying public record'),
('guruprasadsrihari','UNKNOWN',null,null,null,'Individual-named sponsor, PROBUS plan; no corroborating source'),
('mildredclortz','UNKNOWN',null,null,null,'Individual-named sponsor, PROBUS-CAMBRIDGE plan; no corroborating source'),
('sponsor870461751','UNKNOWN',null,null,null,'No plan name; EIN unresolved'),
('sponsor382422062','UNKNOWN',null,null,null,'No plan name; EIN unresolved'),
('sponsor382905930','UNKNOWN',null,null,null,'No plan name; EIN unresolved'),
('sponsor414234758','UNKNOWN',null,null,null,'No plan name; EIN unresolved'),
('sponsor813799174','UNKNOWN',null,null,null,'No plan name; EIN unresolved')
on conflict (mep_slug) do nothing;

reset role;

do $verify$
declare v_total int; v_peo int;
begin
  select count(*) into v_total from public.mep_sponsor_registry;
  select count(*) into v_peo from public.mep_sponsor_registry where verdict='PEO';
  if v_total <> 166 then
    raise exception '0763 verification: expected 166 adjudicated sponsors, found %', v_total;
  end if;
  raise notice '0763 OK: % sponsors adjudicated, % are PEOs', v_total, v_peo;
end $verify$;