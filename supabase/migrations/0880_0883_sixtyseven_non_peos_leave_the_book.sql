-- ===== 0880_sixtyseven_non_peos_the_door_closes =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0880-nonpeo-sweep (opened BEFORE apply)
-- Articles implemented: II.3 (a Gazz ruling is law), CANONICAL RESOLUTION (a non-PEO is never a PEO family),
--   QUARANTINE RULES (aliases are QUARANTINED, never deleted - DELETE is revoked platform-wide),
--   VII.1 (a switch is between two PEOs)
-- Articles verified not violated: III.1, XIII.1, the switch_detection_nightly hold, noncompete fence
-- Verification query attached: YES
--
-- RULING (Gazz, 2026-09-12): \"Execute all as you have proposed\", on a sweep of all 639 PEO families
-- carrying client attributions. PlusOne Solutions (0878/0879) got into the book because miEdge labelled a
-- background-screening vendor as a PEO. This pair of migrations removes the other 67 of the same kind.
-- 0880 shuts the door and retires the identities. 0881 does the backfill across companies and observations.
--
-- WHAT IS BEING REMOVED (Tier 1 - none of these carries any evidence beyond the vendor label):
--   24 staffing agencies        Elite Staffing 331, All Staff Personnel 124, IntelliPro 48, Staffmark, Tradesmen, ...
--    7 insurance agencies/brokers Business Insurers of Georgia 132, J C Barnett 77, United Benefits Consulting 36, ...
--    7 payroll bureaus          Entertainment Partners 96, Cast and Crew, Jacobson Payroll, Paymasters, ...
--    3 transport labor firms    Team One Logistics 46, Transport Labor Holding 34, Premium Transportation 5
--    8 advisory / CPA firms     Leading Edge Leadership 39, MedBest 23, Holthouse Carlin and Van Trigt (a CPA firm) 6, ...
--    5 operating companies      Conduent 38, Solantic urgent care 13, Aramark Processing 12, Minuteman Leasing 4
--    3 insurance carriers       ProAssurance 14, Employers Holdings (the workers comp carrier) 9
--    5 IT / software vendors    IRIS FMP 6, Advantech 3, InfoPro 2, Arkenstone 2, Interlogic 1
--    3 person names             OTTO DAVID, WILSON ROBERT A, WILSON CHRISTOPHER A - not companies at all
--    2 EOR platforms            Bradford Jacobs 3, ShiftPixy 2
--
-- NOT TOUCHED - verified real PEOs behind a generic-looking family name:
--   rippling (alias RIPPLING PEO 1 INC), swbc (SWBC PROFESSIONAL EMPLOYER SERVICES),
--   ocmi (OCMI VI INC, on the Texas TDLR PEO licence), galactic (GALACTIC INC)
--
-- PATTERNS ARE ANCHORED (^...$) on the slug and on every normalized alias, so no substring can ever catch
-- an unrelated company. Generated from peo_families rather than hand-typed.
--
-- THREE EARLIER APPLIES FAILED, each fixed here:
--   1. \"permission denied for table _npeo\" - a temp table is owned by the applying role and the blocks that
--      run as peo_gatekeeper could not read it. Fixed with a grant.
--   2. \"null value in column peo_current\" - peo_current is NOT NULL default false. It goes to false, not null.
--   3. statement timeout inside is_not_a_peo() - 68 anchored regexes evaluated per row over 700k companies and
--      1.2M observations. The bulk predicates are now plain equality against a name set; is_not_a_peo() is kept
--      for the audit check and the ingest door, where it runs on one value at a time.

create table if not exists public.not_a_peo_slugs (
  slug text primary key,
  label text not null,
  what_it_is text not null,
  bucket text not null,
  ruled_by text not null default 'gazz',
  ruled_at timestamptz not null default now()
);
comment on table public.not_a_peo_slugs is
  'Family slugs ruled NOT A PEO. The machine-readable companion to not_a_peo_registry (which holds the name patterns for the ingest door). Backfills join this table by equality instead of running 68 regexes per row.';
alter table public.not_a_peo_slugs enable row level security;
drop policy if exists not_a_peo_slugs_read on public.not_a_peo_slugs;
create policy not_a_peo_slugs_read on public.not_a_peo_slugs for select to authenticated, service_role using (true);
grant select on public.not_a_peo_slugs to service_role, peo_gatekeeper, sysaudit_reader;

insert into public.not_a_peo_slugs (slug, label, what_it_is, bucket) values
 ('plusonesolutions','PlusOne Solutions','contractor compliance and background screening firm','screening'),
 ('elitestaffing','Elite Staffing','staffing agency','staffing'),
 ('allstaffpersonnel','All Staff Personnel','staffing agency','staffing'),
 ('intellipro','IntelliPro Group','recruiting and staffing firm','staffing'),
 ('bearstaffingservices','Bear Staffing Services','staffing agency','staffing'),
 ('creativestaffing','Creative Staffing','staffing agency','staffing'),
 ('staffmarkinvestmentllc','Staffmark Investment LLC','staffing agency','staffing'),
 ('staffingsolutionsholdingsinc','Staffing Solutions Holdings','staffing agency','staffing'),
 ('strategicstaffingsolutionsllc','Strategic Staffing Solutions','IT staffing agency','staffing'),
 ('medicalstaffingsolutionsinc','Medical Staffing Solutions','medical staffing agency','staffing'),
 ('innerstaffllc','InnerStaff','staffing agency','staffing'),
 ('corporatetempsinc','Corporate Temps','temporary staffing agency','staffing'),
 ('tpgstaffingllc','TPG Staffing','staffing agency','staffing'),
 ('unitedtechstaffing','United Tech Staffing','staffing agency','staffing'),
 ('tradesmeninternationalllc','Tradesmen International LLC','skilled trades labor supplier','staffing'),
 ('staffmark','StaffMark','staffing agency','staffing'),
 ('hiredynamics','Hire Dynamics','staffing agency','staffing'),
 ('premierstaffinginc','Premier Staffing','staffing agency','staffing'),
 ('tradesmeninternationalc','Tradesmen International','skilled trades labor supplier','staffing'),
 ('agilestaffing','Agile Staffing','staffing agency','staffing'),
 ('staffmarkinvestmentc','Staffmark Investment','staffing agency','staffing'),
 ('aeglestaffingc','Aegle Staffing','staffing agency','staffing'),
 ('arguseventstaffing','Argus Event Staffing','event staffing agency','staffing'),
 ('seacapstaffingllc','Seacap Staffing','staffing agency','staffing'),
 ('staffficialgroup','Staff Financial Group','accounting and finance staffing agency','staffing'),
 ('businessinsurersofgeorgia','Business Insurers of Georgia','insurance agency','broker'),
 ('jcbarnettinsurorsinc','J C Barnett Insurors','insurance agency','broker'),
 ('unitedbenefitsconsultinginc','United Benefits Consulting','employee benefits broker','broker'),
 ('jcbarnett','J C Barnett','insurance agency','broker'),
 ('insuredsolutions','Insured Solutions','insurance program, not a co-employer','broker'),
 ('benefitcompensationconsultants','Benefit Compensation Consultants','benefits consulting firm','broker'),
 ('safebuiltinsuranceservicesinc','SafeBuilt Insurance Services','insurance services firm','broker'),
 ('entertainmentpartners','Entertainment Partners','entertainment payroll bureau','payroll_bureau'),
 ('dalientertainmentpayrollinc','D Ali Entertainment Payroll','entertainment payroll bureau','payroll_bureau'),
 ('castandcrewpayroll','Cast and Crew Payroll','entertainment payroll bureau','payroll_bureau'),
 ('paymasters','Paymasters','payroll bureau','payroll_bureau'),
 ('mbapayrollservices','MBA Payroll Services','payroll bureau','payroll_bureau'),
 ('jacobsonpayrollgroup','Jacobson Payroll Group','payroll bureau','payroll_bureau'),
 ('dalientertainmentpayro','D Ali Entertainment Payro','entertainment payroll bureau','payroll_bureau'),
 ('teamonelogistics','Team One Logistics','trucking and logistics carrier','transport'),
 ('transportlaborholdingcoinc','Transport Labor Holding Co','driver leasing company','transport'),
 ('premiumtransportationstaffinginc','Premium Transportation Staffing','driver staffing agency','transport'),
 ('leadingedgeleadership','Leading Edge Leadership Group','leadership consulting firm','advisory'),
 ('medbest','MedBest Medical Management','executive search firm','advisory'),
 ('smartconsulting','Smart Consulting','consulting firm','advisory'),
 ('clearresult','ClearResult','energy efficiency consulting firm','advisory'),
 ('holthousecarlinvantrigtllp','Holthouse Carlin and Van Trigt LLP','CPA firm','advisory'),
 ('mirageconsultingincoftx','Mirage Consulting Inc of TX','consulting firm','advisory'),
 ('matthewbrownassociatesinc','Matthew Brown and Associates','accounting and consulting firm','advisory'),
 ('buildingtradesconsultants','Building Trades Consultants','consulting firm','advisory'),
 ('conduent','Conduent','business process outsourcer','operating_co'),
 ('solanticcorporation','Solantic Corporation','urgent care clinic operator','operating_co'),
 ('aramarkprocessing','Aramark Processing','Aramark operating unit','operating_co'),
 ('minutemanleasingcompanyinc','Minuteman Leasing Company','equipment leasing company','operating_co'),
 ('minutemanleasing','Minuteman Leasing','equipment leasing company','operating_co'),
 ('proassurancecorporation','ProAssurance Corporation','medical malpractice insurance carrier','insurer'),
 ('employersholdings','Employers Holdings','workers compensation insurance carrier','insurer'),
 ('proassurance','ProAssurance','medical malpractice insurance carrier','insurer'),
 ('irisfmp','IRIS FMP','payroll software vendor','software'),
 ('advantechsolutions','Advantech Solutions','IT services firm','software'),
 ('arkenstonesystemsllc','Arkenstone Systems','IT services firm','software'),
 ('infopro','InfoPro','IT services firm','software'),
 ('interlogicsolutionsinc','Interlogic Solutions','IT services firm','software'),
 ('ottodavid','OTTO DAVID','an individual person name, not a company','junk'),
 ('wilsonroberta','WILSON ROBERT A','an individual person name, not a company','junk'),
 ('wilsonchristophera','WILSON CHRISTOPHER A','an individual person name, not a company','junk'),
 ('bradfordjacobs','Bradford Jacobs','global employer of record platform','eor_platform'),
 ('shiftpixyacorporation','ShiftPixy','gig staffing platform','eor_platform')
on conflict (slug) do nothing;

-- Every spelling these families are known by, for equality-based backfills.
create table if not exists public.not_a_peo_names (
  name_raw text primary key,
  slug text not null references public.not_a_peo_slugs(slug)
);
alter table public.not_a_peo_names enable row level security;
drop policy if exists not_a_peo_names_read on public.not_a_peo_names;
create policy not_a_peo_names_read on public.not_a_peo_names for select to authenticated, service_role using (true);
grant select on public.not_a_peo_names to service_role, peo_gatekeeper, sysaudit_reader;

insert into public.not_a_peo_names (name_raw, slug)
select distinct v.nm, n.slug
from public.not_a_peo_slugs n
cross join lateral (
  select n.slug as nm
  union select n.label
  union select upper(n.label)
  union select public.name_norm(n.label)
  union select f.alias from public.peo_families f where f.family_slug = n.slug
  union select public.name_norm(f.alias) from public.peo_families f where f.family_slug = n.slug
  union select f.family_display from public.peo_families f where f.family_slug = n.slug
  union select public.name_norm(f.family_display) from public.peo_families f where f.family_slug = n.slug
) v
where v.nm is not null and btrim(v.nm) <> ''
on conflict (name_raw) do nothing;

-- 1. THE INGEST DOOR. Anchored patterns so no substring can catch an unrelated company.
insert into public.not_a_peo_registry (pattern, label, what_it_actually_is, basis, ruled_by)
select
  '^' || upper(n.slug) || '$' ||
  coalesce((select '|' || string_agg(distinct '^' || public.name_norm(f.alias) || '$', '|')
              from public.peo_families f
             where f.family_slug = n.slug
               and public.name_norm(f.alias) <> ''
               and public.name_norm(f.alias) <> upper(n.slug)), ''),
  n.label,
  n.what_it_is || ' - does not co-employ',
  'Gazz ruling 2026-09-12 \"execute all as you have proposed\", on the non-PEO sweep of all 639 families carrying client attributions (0880). Vendor label only: no Form 5500 run, no observation precedence and no switch-ledger evidence stood behind the attribution.',
  'gazz'
from public.not_a_peo_slugs n
where n.slug <> 'plusonesolutions'
on conflict (pattern) do nothing;

insert into public.target_exclusion_patterns (pattern, label, category, basis)
select r.pattern, r.label, 'not_a_peo',
       'Gazz ruling 2026-09-12 (0880): ' || r.what_it_actually_is || ' See not_a_peo_registry.'
from public.not_a_peo_registry r
where not exists (select 1 from public.target_exclusion_patterns t where t.pattern = r.pattern);

-- 2. Retire the identities. Quarantine, never delete.
set role peo_gatekeeper;

update public.peo_families f
   set identity_quarantined_at = now(),
       identity_quarantine_reason = 'NOT A PEO: ' || n.what_it_is ||
         '. Gazz ruling 2026-09-12 (0880). Never canonicalize an attribution to this alias.'
  from public.not_a_peo_slugs n
 where f.family_slug = n.slug and f.identity_quarantined_at is null;

-- 3. A switch is between two PEOs. None of these legs was ever a switch.
update public.peo_switch_ledger l
   set switch_scope = 'intra_family',
       triage_reason = coalesce(l.triage_reason,'') ||
         ' || 0880: RETIRED - one side is not a PEO (Gazz ruling 2026-09-12). Never a switch; excluded from win/loss.'
 where (exists (select 1 from public.not_a_peo_slugs n where n.slug = l.from_family_slug)
     or exists (select 1 from public.not_a_peo_slugs n where n.slug = l.to_family_slug))
   and l.switch_scope is distinct from 'intra_family';

reset role;

-- 4. Close any open adjudication arguing about one of these.
update public.mesh_backlog_adjudication a
   set status = 'dismissed',
       ruling = 'Not a PEO (Gazz ruling 2026-09-12, 0880)',
       ruled_by = 'gazz', ruled_at = now()
 where a.status = 'open'
   and (exists (select 1 from public.not_a_peo_slugs n where n.slug = a.held_peo_family_slug)
     or exists (select 1 from public.not_a_peo_slugs n where n.slug = a.ledger_peo_family_slug));

-- 5. Retire the profiles so nothing publishes them.
update public.peo_profiles p
   set display_name = p.display_name || ' [RETIRED: not a PEO - ' || n.what_it_is || ', Gazz 2026-09-12]'
  from public.not_a_peo_slugs n
 where p.family_slug = n.slug and p.display_name not like '%RETIRED%';

-- VERIFICATION
select (select count(*) from public.not_a_peo_slugs) as slugs_ruled,
       (select count(*) from public.not_a_peo_names) as name_spellings,
       (select count(*) from public.not_a_peo_registry) as door_patterns,
       (select count(*) from public.peo_families f join public.not_a_peo_slugs n on n.slug=f.family_slug
          where f.identity_quarantined_at is null) as aliases_still_live,
       (select count(*) from public.peo_switch_ledger l
          where (exists (select 1 from public.not_a_peo_slugs n where n.slug=l.from_family_slug)
              or exists (select 1 from public.not_a_peo_slugs n where n.slug=l.to_family_slug))
            and l.switch_scope is distinct from 'intra_family') as false_switches_left,
       (select count(*) from public.peo_profiles p join public.not_a_peo_slugs n on n.slug=p.family_slug
          where p.display_name not like '%RETIRED%') as profiles_still_live;"}

-- ===== 0881_non_peo_attributions_leave_every_column =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0880-nonpeo-sweep
-- Articles implemented: II.3, CANONICAL RESOLUTION, fix-at-the-core level 2 (backfill) and level 3 (display)
-- Articles verified not violated: III.1, XIII.1, switch_detection_nightly hold, noncompete fence
-- Verification query attached: YES
--
-- 0880 shut the door and retired the identities. This clears what is already written.
--
-- MY OWN 0878 GAP, FIXED HERE: the PlusOne removal nulled peo_family_slug and peo_brand_slug but left
-- peo_name = 'PlusOne Solutions' on 1,504 companies and peo_prior_family_slug on 14. A customer surface
-- reading peo_name would still have named a background-screening vendor as the PEO. Every identity and
-- dating column now clears, on the current leg and the prior leg, for PlusOne and for all 67 new families.
--
-- peo_current is NOT NULL with default false, so it goes to false - the honest value once no PEO is attributed.
-- Predicates are plain equality against not_a_peo_slugs / not_a_peo_names. An earlier attempt ran
-- is_not_a_peo() per row (68 anchored regexes over 700k companies and 1.2M observations) and timed out.

set role peo_gatekeeper;

-- Current leg
update public.companies c
   set peo_family_slug = null, peo_brand_slug = null, peo_name = null, peo_original = null,
       peo_current = false, peo_current_since = null, peo_current_since_basis = null,
       peo_current_since_precision = null, peo_current_since_censored = null,
       peo_entry_from = null, peo_exit_to = null, peo_switch_as_of = null,
       peo_observation_floor = null, peo_observation_floor_basis = null,
       peo_user_status = null
 where exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_family_slug)
    or exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_brand_slug)
    or exists (select 1 from public.not_a_peo_names m where m.name_raw = c.peo_name)
    or exists (select 1 from public.not_a_peo_names m where m.name_raw = c.peo_current_since_basis and false);

-- Prior leg
update public.companies c
   set peo_prior_family_slug = null, peo_prior_brand_slug = null, peo_prior_name = null,
       peo_prior_since = null, peo_prior_until = null, peo_prior_basis = null,
       peo_prior_since_precision = null, peo_prior_since_censored = null,
       peo_prior_until_precision = null, peo_prior_until_censored = null
 where exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_prior_family_slug)
    or exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_prior_brand_slug)
    or exists (select 1 from public.not_a_peo_names m where m.name_raw = c.peo_prior_name);

-- MEP slug arrays
update public.companies c
   set mep_peo_slugs = nullif((select array_agg(s) from unnest(c.mep_peo_slugs) s
                                where not exists (select 1 from public.not_a_peo_slugs n where n.slug = s)), '{}')
 where c.mep_peo_slugs && (select array_agg(slug) from public.not_a_peo_slugs);

-- Observations that carried the label
update public.field_observations o
   set resolution_status = 'superseded'
 where o.resolution_status <> 'superseded'
   and (exists (select 1 from public.not_a_peo_slugs n where n.slug = o.value_text)
     or exists (select 1 from public.not_a_peo_names m where m.name_raw = o.value_text));

reset role;

select public.refresh_peo_win_loss();

-- VERIFICATION
select (select count(*) from public.companies c where c.merged_into is null
          and (exists (select 1 from public.not_a_peo_slugs n where n.slug=c.peo_family_slug)
            or exists (select 1 from public.not_a_peo_slugs n where n.slug=c.peo_brand_slug))) as companies_left,
       (select count(*) from public.companies c where c.merged_into is null
          and exists (select 1 from public.not_a_peo_names m where m.name_raw=c.peo_name)) as peo_name_residue,
       (select count(*) from public.companies c where c.merged_into is null
          and exists (select 1 from public.not_a_peo_slugs n where n.slug=c.peo_prior_family_slug)) as prior_legs_left,
       (select count(*) from public.field_observations o where o.resolution_status <> 'superseded'
          and exists (select 1 from public.not_a_peo_slugs n where n.slug=o.value_text)) as live_observations_left;"}

-- ===== 0882_the_one_door_refuses_non_peo_attributions =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0880-nonpeo-sweep
-- Articles implemented: ONE-DOOR LAW (the writer refuses, it does not just record), II.3,
--   fix-at-the-core level 1 (the ingest logic, so it never recurs)
-- Articles verified not violated: III.1, XIII.1, noncompete refusal preserved ahead of this one
-- Verification query attached: YES
--
-- 0878 through 0881 cleaned up 68 non-PEO families and shut the display and target doors. The INGEST door
-- was still open: record_field_observation refused noncompete touches but happily accepted a brand-new
-- observation saying \"Elite Staffing is this company's PEO\". The next miEdge or seed load would have walked
-- the same contamination straight back in. This closes level 1.
--
-- The refusal sits AFTER the noncompete check (which must always win first) and before the insert. It fires
-- only on PEO-attribution fields, so a legitimate observation about one of these firms as a COMPANY
-- (address, EIN, carrier) still records - what is refused is naming it as somebody's PEO.
--
-- TWO APPLIES FAILED FIRST:
--   1. \"must be owner of function record_field_observation\" - both overloads are owned by peo_gatekeeper,
--      so the replacement runs inside set role peo_gatekeeper.
--   2. \"function ... is not unique\" - the verification call matched both overloads. Explicit casts added.

create or replace function public.names_a_non_peo(p text)
returns boolean language sql stable as $f$
  select case
    when p is null or btrim(p) = '' then false
    when exists (select 1 from public.not_a_peo_slugs n where n.slug = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = p) then true
    when exists (select 1 from public.not_a_peo_names m where m.name_raw = public.name_norm(p)) then true
    else public.is_not_a_peo(p)
  end;
$f$;
comment on function public.names_a_non_peo(text) is
  'True when this value names something ruled NOT A PEO. Equality first (cheap), the anchored regex door last. Safe to call per row.';
revoke execute on function public.names_a_non_peo(text) from public, anon;
grant execute on function public.names_a_non_peo(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

create or replace function public.is_peo_attribution_field(p text)
returns boolean language sql immutable as $f$
  select p in ('peo_family_slug','peo_family_slug_sighting','peo_brand_slug','peo_name',
               'peo_prior_family_slug','peo_prior_brand_slug','peo_prior_name',
               'mep_matched','mep_peo_slug','peo_current','peo_original');
$f$;
revoke execute on function public.is_peo_attribution_field(text) from public, anon;
grant execute on function public.is_peo_attribution_field(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

set role peo_gatekeeper;

create or replace function public.record_field_observation(
  p_subject_class text, p_subject_key text, p_field text, p_value text, p_as_of date,
  p_source_hub text, p_evidence_ref text default null, p_valid_through date default null)
returns bigint language plpgsql security definer
set search_path to 'public','app','pg_temp'
as $function$
declare v_id bigint; v_dedupe text; v_prev record; v_child record;
        v_priority int; v_wants int := 0; v_steward text;
begin
  if p_value is null or p_as_of is null then return null; end if;

  if mesh_subject_noncompete(p_subject_class, p_subject_key,
       jsonb_build_object('field', p_field, 'value', p_value)) then
    perform mesh_open_case('quarantine_touch', p_subject_class, p_subject_key,
      'noncompete observation touch',
      jsonb_build_object('hub', p_source_hub, 'field', p_field), p_source_hub);
    insert into source_alerts (source_name, change_summary, acknowledged)
    values ('field_observations',
      format('RED: NONCOMPETE OBSERVATION refused — hub=%s subject=%s/%s',
             p_source_hub, p_subject_class, coalesce(p_subject_key,'?')), false);
    return null;
  end if;

  -- NOT-A-PEO REFUSAL. A screening vendor, staffing agency, broker, payroll bureau or insurance carrier
  -- is never anybody's PEO, no matter which feed says so. Refuse at the door and tell somebody.
  if public.is_peo_attribution_field(p_field) and public.names_a_non_peo(p_value) then
    insert into source_alerts (source_name, change_summary, acknowledged)
    values ('field_observations',
      format('NOT-A-PEO ATTRIBUTION refused — hub=%s field=%s value=%s subject=%s/%s. See not_a_peo_registry.',
             p_source_hub, p_field, p_value, p_subject_class, coalesce(p_subject_key,'?')), false);
    return null;
  end if;

  select value_text, as_of into v_prev
  from field_observations
  where subject_class = p_subject_class and subject_key = p_subject_key
    and field_name = p_field
  order by as_of desc, observed_at desc limit 1;

  v_dedupe := md5(p_subject_class||'|'||p_subject_key||'|'||p_field||'|'||
                  p_value||'|'||p_as_of::text||'|'||p_source_hub);
  insert into field_observations (subject_class, subject_key, field_name,
    value_text, as_of, source_hub, evidence_ref, dedupe_key, valid_through)
  values (p_subject_class, p_subject_key, p_field, p_value, p_as_of,
          p_source_hub, p_evidence_ref, v_dedupe, p_valid_through)
  on conflict (dedupe_key) do update set
    valid_through = greatest(coalesce(field_observations.valid_through,'1900-01-01'),
                             coalesce(excluded.valid_through,'1900-01-01'))
  returning id into v_id;

  if v_id is null then return null; end if;

  update want_board set status = 'cancelled', updated_at = now(),
    detail = detail || jsonb_build_object('resolved_by','fresh observation as_of '||p_as_of::text)
  where status = 'open'
    and subject_class = p_subject_class and subject_key = p_subject_key
    and field_wanted = p_field
    and detail->>'reason' = 'parent_change'
    and p_as_of >= coalesce((detail->>'event_as_of')::date, created_at::date);

  if v_prev is not null
     and p_as_of >= v_prev.as_of
     and p_value is distinct from v_prev.value_text then
    for v_child in
      select d.child_field, coalesce(u.declared_weight, 0.3) as weight
      from field_dependencies d
      left join field_utility u on u.field_name = d.child_field
      where d.parent_field = p_field
    loop
      v_priority := case
        when v_child.weight >= 0.9 then 1
        when v_child.weight >= 0.7 then 2
        when v_child.weight >= 0.5 then 3
        when v_child.weight >= 0.3 then 4
        else 5 end;
      select hub_slug into v_steward from mesh_field_stewards where field_name = v_child.child_field;
      if v_steward is not null and v_steward <> p_source_hub
         and exists (select 1 from want_consumer_registry wcr where wcr.enabled and wcr.want_kind = 'missing_field' and wcr.field_wanted = v_child.child_field) then
      perform mesh_post_want(
        p_source_hub, 'missing_field',
        p_subject_class, p_subject_key, v_child.child_field,
        jsonb_build_object('reason','parent_change','parent',p_field,
                           'old',v_prev.value_text,'new',p_value,
                           'event_as_of',p_as_of::text,
                           'note','spine value presumptively stale; answer only with FRESH source evidence, never by echoing the spine'),
        v_priority, 'record', interval '14 days');
      v_wants := v_wants + 1;
      end if;
    end loop;
    insert into decay_events (subject_class, subject_key, parent_field,
      old_value, new_value, event_as_of, wants_posted)
    values (p_subject_class, p_subject_key, p_field,
            v_prev.value_text, p_value, p_as_of, v_wants);
  end if;

  return v_id;
end $function$;

create or replace function public.record_field_observation(
  p_subject_class text, p_subject_key text, p_field text, p_value text, p_as_of date,
  p_source_hub text, p_evidence_ref text default null)
returns bigint language plpgsql security definer
set search_path to 'public','app','pg_temp'
as $function$
begin
  return public.record_field_observation(p_subject_class, p_subject_key, p_field, p_value,
                                         p_as_of, p_source_hub, p_evidence_ref, null::date);
end $function$;

revoke execute on function public.record_field_observation(text,text,text,text,date,text,text) from public, anon;
revoke execute on function public.record_field_observation(text,text,text,text,date,text,text,date) from public, anon;
grant execute on function public.record_field_observation(text,text,text,text,date,text,text) to service_role, postgres, peo_gatekeeper;
grant execute on function public.record_field_observation(text,text,text,text,date,text,text,date) to service_role, postgres, peo_gatekeeper;

-- Widen the audit check: 0878 only watched peo_family_slug. Now it watches the prior leg and the
-- display name too, which is exactly where my own PlusOne cleanup left 1,504 rows behind.
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_attributed', 'mesh_law', 'fast', 'II.3', 'RED',
 'Nothing ruled NOT A PEO may carry a PEO attribution on a company - on the current leg, the prior leg, or the display name. 68 such firms were removed on 2026-09-12 (0878-0881): a background screening vendor, 24 staffing agencies, 7 insurance agencies, 7 payroll bureaus, 3 insurance carriers, and 3 rows that were a person''s name.',
 'select c.id::text as company_id, coalesce(c.peo_family_slug, c.peo_prior_family_slug, c.peo_name) as offending_value from public.companies c where c.merged_into is null and (exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_family_slug) or exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_brand_slug) or exists (select 1 from public.not_a_peo_slugs n where n.slug = c.peo_prior_family_slug) or exists (select 1 from public.not_a_peo_names m where m.name_raw = c.peo_name) or exists (select 1 from public.not_a_peo_names m where m.name_raw = c.peo_prior_name)) limit 500',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as company_id, ''y''::text as offending_value',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_observation_live', 'mesh_law', 'fast', 'II.3', 'RED',
 'No live field observation may name something ruled NOT A PEO. If one appears, a feed got past the one-door refusal in record_field_observation.',
 'select o.id::text as observation_id, o.value_text as offending_value from public.field_observations o where o.resolution_status <> ''superseded'' and (exists (select 1 from public.not_a_peo_slugs n where n.slug = o.value_text) or exists (select 1 from public.not_a_peo_names m where m.name_raw = o.value_text)) limit 500',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as observation_id, ''y''::text as offending_value',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

-- VERIFICATION: the door actually refuses, and a real PEO still passes.
select public.record_field_observation('company'::text,'__doorprobe_0882__'::text,'peo_family_slug'::text,
         'elitestaffing'::text, current_date::date,'seed:miEdge'::text,'0882 selftest'::text, null::date) as should_be_null,
       (select count(*) from public.field_observations where subject_key='__doorprobe_0882__') as should_be_zero,
       public.names_a_non_peo('Elite Staffing') as name_caught_true,
       public.names_a_non_peo('adp_totalsource') as real_peo_false,
       public.names_a_non_peo('rippling') as rippling_false,
       public.names_a_non_peo('ocmi') as ocmi_false;"}

-- ===== 0883_peo_identity_check_lane =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0880-nonpeo-sweep
-- Articles implemented: NO-BLIND-SPENDER LAW (registered caller, one priced door, hard cap),
--   II.3, MESH CROSS-REFERENCE MANDATE (free evidence first, paid evidence only for what it cannot answer)
-- Articles verified not violated: III.1, XIII.1, switch_detection_nightly hold
-- Verification query attached: YES
--
-- Tier 2 of the non-PEO sweep. 15 families had some evidence behind the attribution and were held back from
-- the 0880/0881 removal. The mesh answered 4 of them for free, from the sworn Schedule MEP box 1b filing that
-- outranks all inference (the 0851 law):
--   TRANSPORT LABOR CONTRACT/ LEASING, INC.  peo, 184 employers, 6,278 lives, 2024  -> IS a PEO, kept
--   STAFFING PLUS, INC                       peo, 7 employers, 393 lives, 2024      -> IS a PEO, kept
--   DEEL PEO, LLC                            peo, 219 employers, 2025               -> IS a PEO, kept
--   EMPLOVA, LLC                             peo, 47 employers, 910 lives, 2024     -> IS a PEO, kept
-- Heartland Dental filed too, but as mep_plan_type 'other' with zero PEO filings - a dental support
-- organization's own multiple-employer plan for the practices it supports. Not a PEO.
--
-- The remaining 11 have NO sworn PEO filing, NO IRS CPEO listing and NO state PEO licence anywhere in the
-- mesh. Absence of evidence is not evidence, so rather than remove 500+ companies on a silence, they go to a
-- capped paid check: 1 Serper search + 1 Haiku grading each, gated by serper_budget_ok and brain_spend_ok,
-- cost booked through log_brain_spend.
--
-- A verdict does NOT remove anything by itself. peo_identity_check_promote() is a separate, explicit call.
-- An LLM should not be able to clear hundreds of live attributions while nobody is looking.

create table if not exists public.peo_identity_web_checks (
  check_id bigserial primary key,
  family_slug text not null,
  family_display text,
  clients_at_queue int,
  why_queued text not null,
  status text not null default 'queued'
    check (status in ('queued','claimed','done','unresolved','error')),
  verdict text check (verdict in ('peo','not_a_peo','unknown')),
  confidence numeric(3,2),
  summary text,
  sources jsonb,
  usage jsonb,
  attempts int not null default 0,
  last_error text,
  promoted_at timestamptz,
  queued_at timestamptz not null default now(),
  claimed_at timestamptz,
  resolved_at timestamptz,
  unique (family_slug)
);
alter table public.peo_identity_web_checks enable row level security;
drop policy if exists peo_identity_web_checks_read on public.peo_identity_web_checks;
create policy peo_identity_web_checks_read on public.peo_identity_web_checks
  for select to authenticated, service_role using (true);
grant select on public.peo_identity_web_checks to service_role, peo_gatekeeper, sysaudit_reader;

-- Queue. Hard cap in SQL, not in the edge function.
create or replace function public.queue_peo_identity_checks(p_slugs text[], p_why text, p_cap int default 15)
returns int language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_n int;
begin
  if p_cap > 15 then p_cap := 15; end if;
  with cand as (
    select s as family_slug,
           (select max(f.family_display) from peo_families f where f.family_slug = s) as disp,
           (select count(*) from companies c where c.merged_into is null and c.peo_family_slug = s) as n
    from unnest(p_slugs) s
    where not exists (select 1 from not_a_peo_slugs n where n.slug = s)
    limit p_cap
  )
  insert into peo_identity_web_checks (family_slug, family_display, clients_at_queue, why_queued)
  select family_slug, disp, n, p_why from cand
  on conflict (family_slug) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $f$;
revoke execute on function public.queue_peo_identity_checks(text[],text,int) from public, anon;
grant execute on function public.queue_peo_identity_checks(text[],text,int) to service_role, postgres, peo_gatekeeper;

create or replace function public.peo_identity_check_next(p_limit int default 5)
returns table (check_id bigint, family_slug text, family_display text, clients int, why_queued text)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
begin
  return query
  update peo_identity_web_checks c
     set status = 'claimed', claimed_at = now(), attempts = c.attempts + 1
   where c.check_id in (
     select k.check_id from peo_identity_web_checks k
      where k.status = 'queued' and k.attempts < 3
      order by k.clients_at_queue desc nulls last, k.check_id
      limit least(p_limit, 5) for update skip locked)
  returning c.check_id, c.family_slug, c.family_display, c.clients_at_queue, c.why_queued;
end $f$;
revoke execute on function public.peo_identity_check_next(int) from public, anon;
grant execute on function public.peo_identity_check_next(int) to service_role, postgres, peo_gatekeeper;

create or replace function public.peo_identity_check_apply(
  p_check_id bigint, p_verdict text, p_confidence numeric, p_sources jsonb, p_summary text, p_usage jsonb)
returns text language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_status text;
begin
  -- A verdict is only usable at 0.70 or better; below that a human decides.
  v_status := case when p_verdict in ('peo','not_a_peo') and coalesce(p_confidence,0) >= 0.70
                   then 'done' else 'unresolved' end;
  update peo_identity_web_checks
     set status = v_status, verdict = p_verdict, confidence = p_confidence,
         sources = p_sources, summary = left(coalesce(p_summary,''), 1000),
         usage = p_usage, resolved_at = now()
   where check_id = p_check_id;
  return v_status;
end $f$;
revoke execute on function public.peo_identity_check_apply(bigint,text,numeric,jsonb,text,jsonb) from public, anon;
grant execute on function public.peo_identity_check_apply(bigint,text,numeric,jsonb,text,jsonb) to service_role, postgres, peo_gatekeeper;

create or replace function public.peo_identity_check_error(p_check_id bigint, p_err text)
returns void language sql security definer set search_path to 'public','pg_temp' as $f$
  update peo_identity_web_checks
     set status = case when attempts >= 3 then 'error' else 'queued' end,
         last_error = left(p_err, 1000)
   where check_id = p_check_id;
$f$;
revoke execute on function public.peo_identity_check_error(bigint,text) from public, anon;
grant execute on function public.peo_identity_check_error(bigint,text) to service_role, postgres, peo_gatekeeper;

-- Promotion is deliberate and separate. It only ever acts on a not_a_peo verdict at 0.80 or better,
-- and it writes the slug, every known spelling and the anchored ingest pattern in one step.
create or replace function public.peo_identity_check_promote(p_min_confidence numeric default 0.80)
returns table (family_slug text, confidence numeric, companies_cleared int)
language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare r record; v_n int;
begin
  for r in
    select c.* from peo_identity_web_checks c
     where c.status = 'done' and c.verdict = 'not_a_peo'
       and c.confidence >= p_min_confidence and c.promoted_at is null
  loop
    insert into not_a_peo_slugs (slug, label, what_it_is, bucket, ruled_by)
    values (r.family_slug, coalesce(r.family_display, r.family_slug),
            left(coalesce(r.summary,'web check found no PEO/co-employer evidence'), 300),
            'web_checked', 'peo-identity-check')
    on conflict (slug) do nothing;

    insert into not_a_peo_names (name_raw, slug)
    select distinct v.nm, r.family_slug from (
      select r.family_slug as nm
      union select r.family_display
      union select public.name_norm(r.family_display)
      union select f.alias from peo_families f where f.family_slug = r.family_slug
      union select public.name_norm(f.alias) from peo_families f where f.family_slug = r.family_slug
    ) v where v.nm is not null and btrim(v.nm) <> ''
    on conflict (name_raw) do nothing;

    insert into not_a_peo_registry (pattern, label, what_it_actually_is, basis, ruled_by)
    select '^' || upper(r.family_slug) || '$' ||
           coalesce((select '|' || string_agg(distinct '^' || public.name_norm(f.alias) || '$', '|')
                       from peo_families f where f.family_slug = r.family_slug
                        and public.name_norm(f.alias) <> '' and public.name_norm(f.alias) <> upper(r.family_slug)), ''),
           coalesce(r.family_display, r.family_slug),
           left(coalesce(r.summary,'no PEO evidence found'), 300),
           'peo-identity-check verdict not_a_peo at confidence ' || r.confidence || ' (0883 lane), under the Gazz non-PEO ruling of 2026-09-12',
           'peo-identity-check'
    on conflict (pattern) do nothing;

    select count(*) into v_n from companies c2
     where c2.merged_into is null and c2.peo_family_slug = r.family_slug;

    update peo_identity_web_checks set promoted_at = now() where check_id = r.check_id;

    family_slug := r.family_slug; confidence := r.confidence; companies_cleared := v_n;
    return next;
  end loop;
end $f$;
revoke execute on function public.peo_identity_check_promote(numeric) from public, anon;
grant execute on function public.peo_identity_check_promote(numeric) to service_role, postgres, peo_gatekeeper;

insert into public.ai_caller_registry (fn_slug, calls_llm, models, cost_path, cost_module, budget_gated, gate_fn, is_blind, can_reach_fable, ruling, verified_at, verified_by, note)
values ('peo-identity-check', true, array['claude-haiku-4-5-20251001'], 'api_spend_ledger', 'peo-identity-check',
        true, 'brain_spend_ok', false, false,
        'Tier 2 of the non-PEO sweep. Answers one question only: is this family a PEO/co-employer, or something else. Free mesh evidence (sworn Schedule MEP 1b, IRS CPEO, state licence) is checked first and only silence reaches this lane.',
        now(), 'deploy-v1-2026-09-12',
        'serper_budget_ok + brain_spend_ok gates; books via log_brain_spend; hard cap 15 in queue_peo_identity_checks and 5 per batch in peo_identity_check_next; a verdict never removes anything - peo_identity_check_promote() is a separate explicit call at 0.80+')
on conflict (fn_slug) do update set note = excluded.note, verified_at = excluded.verified_at, verified_by = excluded.verified_by;

-- Queue the 11 the mesh could not answer for free.
select public.queue_peo_identity_checks(
  array['wesleymedicalstaffinginc','cohesivenetworks','adecco','staffingalternativesinc','eliassengroup',
        'heartlanddental','niural','centurystaffing','unitedtempsinc','arkstaffing','sourceficialstaffing'],
  'Tier 2 non-PEO sweep 2026-09-12: vendor label only, and the mesh holds no sworn Schedule MEP 1b filing, no IRS CPEO listing and no state PEO licence for this name.',
  15) as queued;

select check_id, family_slug, clients_at_queue, status from public.peo_identity_web_checks order by clients_at_queue desc nulls last;"}
