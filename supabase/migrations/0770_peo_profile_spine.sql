-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-peo-profile-spine
-- Articles implemented: ENTRY PIPELINE (write through field_observations with provenance and period
--   shape), Mesh Cross-Reference Mandate 1 (canonical resolution), VI.2 (job receipts),
--   want-board loop (a missing field becomes a want the mesh can answer)
-- Articles verified not violated: no sourcing field is marked displayable; WC carrier stays internal;
--   noncompete families are excluded from every want and every shelf
-- Verification query attached: YES

-- ============================================================================
-- 0770  PEO profiles become a first-class subject of the mesh
--
-- Gazz 2026-09-08: "what data are we maintaining for each peo, how are we
-- offering it to the mesh network and how are we updating when appropriate
-- with new found data. PEO profiles should be part of the heart of what we do."
--
-- Before this migration a PEO profile was a side table: 48 columns written
-- directly by one-off enrichment, no provenance, no freshness, no want loop.
-- Companies had all three; PEOs had none. 634,600 company observations against
-- 289 PEO-level observations, and those split across two subject_class spellings.
--
-- This installs, for PEOs, the same spine companies already have:
--   1. A REGISTER of what we maintain per PEO, what may be displayed, which
--      hubs may answer it, and how often it must be re-checked.
--   2. ONE DOOR (apply_peo_profile_field) - every write lands as a
--      field_observation with provenance and stamps peo_profiles.
--   3. FRESHNESS (v_peo_profile_freshness) - per family x field: held? as-of?
--      stale? never-asked?
--   4. A WANT LOOP (enqueue_peo_profile_wants) - anything missing or stale
--      becomes a want_board row the mesh answers, exactly like a company field.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Normalise the subject class. Two spellings, one subject.
-- ---------------------------------------------------------------------------
set role peo_gatekeeper;

update public.field_observations
set subject_class = 'peo_family'
where subject_class = 'peo';

reset role;

-- ---------------------------------------------------------------------------
-- 2. The register: what we maintain for every PEO.
-- ---------------------------------------------------------------------------
create table if not exists public.peo_profile_field_registry (
  field_name       text primary key,
  label            text not null,
  definition       text not null,
  target_column    text,
  displayable      boolean not null,
  answer_hubs      text[] not null,
  refresh_days     int,
  required_tier    text not null check (required_tier in ('core','standard','depth')),
  added_at         timestamptz not null default now()
);

alter table public.peo_profile_field_registry enable row level security;

comment on table public.peo_profile_field_registry is
  '0770: the contract for a PEO profile. One row per field we maintain: what it means, which column holds it, whether it may EVER reach a customer surface, which mesh hubs are allowed to answer it, and how many days before it must be re-checked. required_tier: core = a profile is not a profile without it; standard = expected; depth = enrichment.';

insert into public.peo_profile_field_registry
  (field_name, label, definition, target_column, displayable, answer_hubs, refresh_days, required_tier)
values
 ('customer_facing_name','Customer-facing name','The name the PEO markets under - what a client would say out loud.','customer_facing_name',true,array['peo_intel','web','irs_cpeo','state_registry'],365,'core'),
 ('website','Website','Primary marketing domain. The anchor for every web-sourced field.','website',true,array['web','serper','peo_intel'],180,'core'),
 ('cpeo_status','IRS CPEO status','certified / not_certified / revoked / suspended on the IRS public CPEO list.','cpeo_status',true,array['irs_cpeo'],90,'core'),
 ('hq_city_state','HQ city and state','Head office city and state. Street is held internally and never displayed.','hq_address',true,array['web','serper','state_registry','efast_5500'],365,'standard'),
 ('ownership_type','Ownership','Independent, PE-backed, strategic-owned, public. Who ultimately owns the PEO.','ownership_type',true,array['web','news','peo_intel'],365,'standard'),
 ('ownership_detail','Owner','The named parent or sponsor when ownership is not independent.','ownership_detail',true,array['web','news','peo_intel'],365,'standard'),
 ('funding_model','WC funding model','Guaranteed cost, large deductible, captive, self-insured.','funding_model',true,array['peo_intel','state_registry','web'],365,'depth'),
 ('client_count','Client count','Clients we can see in the book. Derived, refreshed from the spine.','client_count',true,array['derived'],30,'standard'),
 ('total_wse_count','Worksite employees','Published or filed WSE count.','total_wse_count',true,array['efast_5500','web','news','peo_intel'],180,'standard'),
 ('wse_yoy_pct','WSE year-over-year','Growth or contraction in worksite employees.','wse_yoy_pct',true,array['derived','efast_5500'],180,'depth'),
 ('book_by_state','Book by state','Client counts per state - the PEO footprint.','book_by_state',true,array['derived'],30,'standard'),
 ('geo_concentration','Geographic concentration','How concentrated the book is; top states and share.','geo_concentration',true,array['derived'],90,'depth'),
 ('renewal_architecture','Renewal architecture','How the PEO structures WC and health renewals across its book.','renewal_architecture',true,array['derived','peo_intel'],180,'depth'),
 ('narrative','Narrative','The written read on the PEO - what they are and how they compete.','narrative',true,array['derived','peo_intel','web','news'],180,'depth'),
 ('logo','Logo','Brand mark for the map and the profile card.','',true,array['web','serper'],365,'standard'),
 ('review_ratings','Public reviews','Aggregated public review score and volume.','',true,array['web','serper'],180,'depth'),
 -- INTERNAL: held, used, never displayed on a customer surface
 ('sponsor_eins','Sponsor EINs','Filing EINs that identify this PEO federally. SOURCING - never displayed.','sponsor_eins',false,array['efast_5500','irs_cpeo','state_registry'],365,'standard'),
 ('carrier_lineup','WC carriers','Carriers behind the book. INTERNAL ONLY by standing ruling - never displayed.','carrier_lineup',false,array['state_registry','peo_intel'],180,'depth'),
 ('filing_signers','Filing signers','Names signing the 5500s - a fingerprint. SOURCING - never displayed.','filing_signers',false,array['efast_5500'],365,'depth'),
 ('tech_signature','Tech signature','PrismHR/other platform fingerprint. SOURCING - never displayed.','tech_signature',false,array['web','serper'],180,'depth'),
 ('filing_profile','Filing profile','Shape of the PEO federal filings. SOURCING - never displayed.','filing_profile',false,array['efast_5500'],180,'depth')
on conflict (field_name) do nothing;

-- ---------------------------------------------------------------------------
-- 3. Provenance column, then ONE DOOR for every PEO profile write.
-- ---------------------------------------------------------------------------
alter table public.peo_profiles
  add column if not exists field_provenance jsonb not null default '{}'::jsonb;

comment on column public.peo_profiles.field_provenance is
  '0770: per-field provenance stamped by apply_peo_profile_field(): {field: {as_of, source_hub, evidence_ref, at}}. A field with no entry here was written before the door existed.';

create or replace function public.apply_peo_profile_field(
  p_family_slug  text,
  p_field        text,
  p_value        text,
  p_source_hub   text,
  p_evidence_ref text default null,
  p_as_of        date default current_date
) returns text
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_reg record; v_canon text; v_col text; v_sql text; v_existing text;
begin
  -- canonical family, always
  v_canon := coalesce(public.canonical_family_slug(p_family_slug), p_family_slug);

  if not exists (select 1 from peo_families f where f.family_slug = v_canon) then
    return 'refused:unregistered_family';
  end if;

  -- noncompete PEOs are never profiled, appended or worked
  if public.is_noncompete_peo(v_canon) then
    return 'refused:noncompete';
  end if;

  select * into v_reg from peo_profile_field_registry r where r.field_name = p_field;
  if not found then
    return 'refused:unregistered_field';
  end if;

  if not (p_source_hub = any (v_reg.answer_hubs)) then
    return 'refused:hub_not_permitted';
  end if;

  if nullif(btrim(p_value),'') is null then
    return 'refused:empty_value';
  end if;

  -- the observation is the record of truth; the profile is the compiled answer
  insert into field_observations
    (subject_class, subject_key, field_name, value_text, as_of, source_hub, evidence_ref,
     observed_at, dedupe_key, resolution_status)
  values ('peo_family', v_canon, p_field, btrim(p_value), p_as_of, p_source_hub,
          coalesce(p_evidence_ref, p_source_hub||':'||v_canon||':'||p_field),
          now(), 'peo_profile:'||v_canon||':'||p_field||':'||p_source_hub||':'||p_as_of, 'resolved')
  on conflict (dedupe_key) do nothing;

  -- ensure a profile row exists
  insert into peo_profiles (family_slug, display_name, profile_status)
  select v_canon, coalesce((select f.family_display from peo_families f where f.family_slug=v_canon limit 1), v_canon), 'stub'
  where not exists (select 1 from peo_profiles p where p.family_slug = v_canon);

  -- write the compiled value into its column when the registry names one
  v_col := nullif(btrim(coalesce(v_reg.target_column,'')),'');
  if v_col is not null then
    execute format('select (%I)::text from peo_profiles where family_slug = $1', v_col)
      into v_existing using v_canon;
    if v_existing is distinct from btrim(p_value) then
      if v_col in ('sponsor_eins','carrier_lineup','filing_signers','tech_signature',
                   'filing_profile','book_by_state','geo_concentration','narrative',
                   'renewal_architecture','hq_address') then
        v_sql := format('update peo_profiles set %I = $2::jsonb, updated_at = now() where family_slug = $1', v_col);
      elsif v_col in ('client_count','total_wse_count') then
        v_sql := format('update peo_profiles set %I = $2::int, updated_at = now() where family_slug = $1', v_col);
      elsif v_col = 'wse_yoy_pct' then
        v_sql := format('update peo_profiles set %I = $2::numeric, updated_at = now() where family_slug = $1', v_col);
      else
        v_sql := format('update peo_profiles set %I = $2, updated_at = now() where family_slug = $1', v_col);
      end if;
      execute v_sql using v_canon, btrim(p_value);
    end if;
  end if;

  -- provenance, always, even when the value did not move
  update peo_profiles
  set field_provenance = coalesce(field_provenance,'{}'::jsonb)
        || jsonb_build_object(p_field, jsonb_build_object(
             'as_of', p_as_of, 'source_hub', p_source_hub,
             'evidence_ref', p_evidence_ref, 'at', now())),
      updated_at = now()
  where family_slug = v_canon;

  -- close any open want for this field
  update want_board
  set status = 'satisfied', answers_count = coalesce(answers_count,0) + 1, updated_at = now()
  where subject_class = 'peo_family' and subject_key = v_canon
    and field_wanted = p_field and status = 'open';

  return 'applied:'||p_field;
end $fn$;

comment on function public.apply_peo_profile_field(text,text,text,text,text,date) is
  '0770: the ONE door for PEO profile data. Canonicalises the family, refuses a noncompete PEO, refuses an unregistered field or a hub not permitted to answer it, writes a field_observation with provenance, compiles the value into peo_profiles, stamps field_provenance and satisfies any open want. Nothing should write peo_profiles directly.';

revoke all on function public.apply_peo_profile_field(text,text,text,text,text,date) from public;
revoke all on function public.apply_peo_profile_field(text,text,text,text,text,date) from map_reader;
grant execute on function public.apply_peo_profile_field(text,text,text,text,text,date) to service_role;
grant execute on function public.apply_peo_profile_field(text,text,text,text,text,date) to peo_gatekeeper;

-- ---------------------------------------------------------------------------
-- 4. Freshness: per family x field, what we hold and how old it is.
-- ---------------------------------------------------------------------------
create or replace view public.v_peo_profile_freshness as
select f.family_slug,
       r.field_name,
       r.required_tier,
       r.displayable,
       r.refresh_days,
       (p.field_provenance ? r.field_name) as has_provenance,
       (p.field_provenance -> r.field_name ->> 'as_of')::date as as_of,
       (p.field_provenance -> r.field_name ->> 'source_hub') as source_hub,
       case
         when p.family_slug is null then 'no_profile'
         when not (p.field_provenance ? r.field_name) then 'never_sourced'
         when r.refresh_days is null then 'fresh'
         when (p.field_provenance -> r.field_name ->> 'as_of')::date
              < current_date - r.refresh_days then 'stale'
         else 'fresh'
       end as freshness,
       (select count(*) from public.companies c
         where c.merged_into is null and c.peo_family_slug = f.family_slug and c.peo_current) as current_clients
from (select distinct family_slug from public.peo_families) f
cross join public.peo_profile_field_registry r
left join public.peo_profiles p on p.family_slug = f.family_slug
where not public.is_noncompete_peo(f.family_slug);

comment on view public.v_peo_profile_freshness is
  '0770: one row per PEO family x registered field. freshness = no_profile | never_sourced | stale | fresh. This is what the want generator reads and what the auditor measures.';

-- ---------------------------------------------------------------------------
-- 5. The want loop: anything missing or stale becomes a want the mesh answers.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_peo_profile_wants(p_limit int default 2000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_n int;
begin
  with cand as (
    select f.family_slug, f.field_name, f.required_tier, f.freshness, f.current_clients,
           r.answer_hubs
    from v_peo_profile_freshness f
    join peo_profile_field_registry r on r.field_name = f.field_name
    where f.freshness in ('no_profile','never_sourced','stale')
      and f.current_clients > 0
    order by (f.required_tier = 'core') desc, f.current_clients desc
    limit p_limit
  ), ins as (
    insert into want_board
      (hub_slug, want_scope, want_kind, subject_class, subject_key, field_wanted,
       detail, priority, status, expires_at, dedupe_key)
    select 'mesh', 'peo_family', 'field', 'peo_family', c.family_slug, c.field_name,
           jsonb_build_object('tier', c.required_tier, 'reason', c.freshness,
                              'answer_hubs', c.answer_hubs, 'clients', c.current_clients,
                              'law','0770 peo_profile_spine'),
           case when c.required_tier='core' then 90
                when c.required_tier='standard' then 60 else 30 end,
           'open', now() + interval '90 days',
           'peo_profile:'||c.family_slug||':'||c.field_name
    from cand c
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into v_n from ins;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('enqueue_peo_profile_wants', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('wants_opened', v_n, 'limit', p_limit));
  return jsonb_build_object('wants_opened', v_n);
end $fn$;

comment on function public.enqueue_peo_profile_wants(int) is
  '0770: turns every missing or stale PEO profile field into a want_board row (subject_class=peo_family) so the mesh answers it the same way it answers a company field. Core fields first, then by book size. Noncompete families are excluded by the view.';

revoke all on function public.enqueue_peo_profile_wants(int) from public;
revoke all on function public.enqueue_peo_profile_wants(int) from map_reader;
grant execute on function public.enqueue_peo_profile_wants(int) to service_role;

-- ---------------------------------------------------------------------------
-- VERIFICATION
-- ---------------------------------------------------------------------------
do $verify$
declare v_fields int; v_disp int; v_internal int; v_obs int; v_r text;
begin
  select count(*) into v_fields from public.peo_profile_field_registry;
  select count(*) into v_disp from public.peo_profile_field_registry where displayable;
  select count(*) into v_internal from public.peo_profile_field_registry where not displayable;
  if v_fields < 21 then
    raise exception '0770 verification: only % fields registered', v_fields;
  end if;
  if v_internal < 5 then
    raise exception '0770 verification: sourcing fields are not marked internal';
  end if;

  -- WC carrier must never be displayable
  if (select displayable from public.peo_profile_field_registry where field_name='carrier_lineup') then
    raise exception '0770 verification: carrier_lineup is marked displayable';
  end if;
  if (select displayable from public.peo_profile_field_registry where field_name='sponsor_eins') then
    raise exception '0770 verification: sponsor_eins is marked displayable';
  end if;

  -- subject_class normalised
  select count(*) into v_obs from public.field_observations where subject_class = 'peo';
  if v_obs > 0 then
    raise exception '0770 verification: % observations still carry subject_class=peo', v_obs;
  end if;

  -- the door refuses what it must
  select public.apply_peo_profile_field('helpside','website','x','web') into v_r;
  if v_r <> 'refused:noncompete' then
    raise exception '0770 verification: door did not refuse a noncompete PEO (got %)', v_r;
  end if;
  select public.apply_peo_profile_field('trinet','not_a_real_field','x','web') into v_r;
  if v_r <> 'refused:unregistered_field' then
    raise exception '0770 verification: door did not refuse an unregistered field (got %)', v_r;
  end if;
  select public.apply_peo_profile_field('trinet','cpeo_status','certified','web') into v_r;
  if v_r <> 'refused:hub_not_permitted' then
    raise exception '0770 verification: door let a hub answer a field it may not (got %)', v_r;
  end if;
  select public.apply_peo_profile_field('a_family_that_does_not_exist','website','x','web') into v_r;
  if v_r <> 'refused:unregistered_family' then
    raise exception '0770 verification: door did not refuse an unregistered family (got %)', v_r;
  end if;

  raise notice '0770 OK: % fields registered (% displayable, % internal), door refusing correctly',
    v_fields, v_disp, v_internal;
end $verify$;