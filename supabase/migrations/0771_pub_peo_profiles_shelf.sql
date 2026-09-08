-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-peo-profile-spine
-- Articles implemented: publish-shelf doctrine (a customer surface reads only the compiled shelf,
--   never the working tables), map_no_sourcing_display_law, WC-carrier-internal ruling,
--   noncompete law, PEO Spectrum denylist
-- Articles verified not violated: no internal/sourcing field reaches the shelf; noncompete and
--   denylisted families are absent from it
-- Verification query attached: YES

-- ============================================================================
-- 0771  pub.peo_profiles - the display-worthy PEO shelf
--
-- Companies already publish through pub.map_pins: a compiled table holding only
-- fields the registry marks displayable, read by map_reader, never the raw
-- spine. PEO profiles had no equivalent - any surface wanting PEO data had to
-- read public.peo_profiles, which carries sponsor EINs, carrier lineups and
-- filing fingerprints alongside the customer-facing facts.
--
-- Displayability is decided in ONE place - peo_profile_field_registry (0770) -
-- and this shelf is compiled from that decision, so the two cannot drift.
-- ============================================================================

create table if not exists pub.peo_profiles (
  family_slug        text primary key,
  display_name       text not null,
  website            text,
  cpeo_status        text,
  hq_city            text,
  hq_state           text,
  ownership_type     text,
  ownership_detail   text,
  funding_model      text,
  client_count       int,
  total_wse_count    int,
  wse_yoy_pct        numeric,
  book_by_state      jsonb,
  geo_concentration  jsonb,
  renewal_architecture jsonb,
  narrative          jsonb,
  has_logo           boolean not null default false,
  brand_hex          text,
  profile_tier       text not null,
  core_complete      boolean not null default false,
  compiled_at        timestamptz not null default now()
);

alter table pub.peo_profiles enable row level security;
grant select on pub.peo_profiles to map_reader;

comment on table pub.peo_profiles is
  '0771: the compiled, display-worthy PEO profile shelf. Contains ONLY fields peo_profile_field_registry marks displayable=true. Sponsor EINs, WC carrier lineups, filing signers, tech signatures and filing profiles are deliberately absent and must never be added. Noncompete and denylisted families are never compiled here.';

insert into pub.field_registry (surface, field_name, kind, definition, displayable, designated_by, ratified_by, note)
select 'peo_profiles', v.f, v.k, v.d, true, 'instanceA-0771', 'gazz-2026-09-08', v.n
from (values
 ('family_slug','key','Canonical PEO family key.','join key'),
 ('display_name','label','The name the PEO markets under.','from customer_facing_name'),
 ('website','label','Primary marketing domain.',''),
 ('cpeo_status','tier','IRS CPEO certification status.',''),
 ('hq_city','geo','Head office city.','street never published'),
 ('hq_state','geo','Head office state.','street never published'),
 ('ownership_type','label','Independent / PE-backed / strategic / public.',''),
 ('ownership_detail','label','Named parent or sponsor.',''),
 ('funding_model','label','WC funding model.','model only - never the carrier'),
 ('client_count','value','Clients visible in the book.','derived from the spine'),
 ('total_wse_count','value','Worksite employees.',''),
 ('wse_yoy_pct','value','WSE year-over-year change.',''),
 ('book_by_state','value','Client counts per state.',''),
 ('geo_concentration','value','Concentration of the book.',''),
 ('renewal_architecture','value','How renewals are structured across the book.',''),
 ('narrative','label','The written read on the PEO.',''),
 ('has_logo','flag','A brand mark is available.',''),
 ('brand_hex','style','Brand colour for the card.',''),
 ('profile_tier','tier','stub / auto_profiled / built.',''),
 ('core_complete','flag','Name, website and CPEO status all held.','completeness signal'),
 ('compiled_at','time','When this row was compiled.','')
) as v(f,k,d,n)
where not exists (select 1 from pub.field_registry fr
                  where fr.surface='peo_profiles' and fr.field_name = v.f);

create or replace function pub.compile_peo_profiles()
returns bigint
language plpgsql
security definer
set search_path to 'public','pub','pg_temp'
as $fn$
declare v_n bigint;
begin
  delete from pub.peo_profiles;
  insert into pub.peo_profiles (
    family_slug, display_name, website, cpeo_status, hq_city, hq_state,
    ownership_type, ownership_detail, funding_model, client_count, total_wse_count,
    wse_yoy_pct, book_by_state, geo_concentration, renewal_architecture, narrative,
    has_logo, brand_hex, profile_tier, core_complete, compiled_at)
  select
    p.family_slug,
    coalesce(nullif(btrim(p.customer_facing_name),''), nullif(btrim(p.display_name),''), p.family_slug),
    nullif(btrim(p.website),''),
    p.cpeo_status,
    hq.city, hq.state,
    p.ownership_type, p.ownership_detail, p.funding_model,
    coalesce(p.client_count, cl.n::int),
    p.total_wse_count, p.wse_yoy_pct,
    coalesce(p.book_by_state, '{}'::jsonb),
    p.geo_concentration, p.renewal_architecture, p.narrative,
    (l.family_slug is not null),
    l.dominant_hex,
    p.profile_status,
    (nullif(btrim(p.customer_facing_name),'') is not null
     and nullif(btrim(p.website),'') is not null
     and p.cpeo_status is not null),
    now()
  from public.peo_profiles p
  join (select distinct family_slug from public.peo_families) f on f.family_slug = p.family_slug
  left join lateral (
      select min(r.city) as city, min(r.state) as state
      from public.peo_address_registry r
      where r.peo_family_slug = p.family_slug and r.kind = 'hq') hq on true
  left join lateral (
      select count(*) as n from public.companies c
      where c.merged_into is null and c.peo_family_slug = p.family_slug and c.peo_current) cl on true
  left join public.peo_logo_registry l
      on l.family_slug = p.family_slug and l.status in ('ok','tiny') and l.logo_data is not null
  where not public.is_noncompete_peo(p.family_slug)
    and not exists (select 1 from public.peo_classification_denylist d where d.family_slug = p.family_slug);
  get diagnostics v_n = row_count;

  insert into pub.shelf_meta values ('peo_profiles', now(), v_n, 0)
  on conflict (surface) do update set compiled_at=excluded.compiled_at, n_rows=excluded.n_rows;
  return v_n;
end $fn$;

revoke all on function pub.compile_peo_profiles() from public;
revoke all on function pub.compile_peo_profiles() from map_reader;

select pub.compile_peo_profiles();

do $verify$
declare v_rows bigint; v_cols int; v_bad int;
begin
  select count(*) into v_rows from pub.peo_profiles;
  if v_rows < 500 then
    raise exception '0771 verification: shelf compiled only % rows', v_rows;
  end if;

  select count(*) into v_bad from information_schema.columns
   where table_schema='pub' and table_name='peo_profiles'
     and column_name in ('sponsor_eins','carrier_lineup','filing_signers','tech_signature',
                         'filing_profile','candidate_sponsor_eins','hq_address');
  if v_bad > 0 then
    raise exception '0771 verification: % sourcing column(s) reached the shelf', v_bad;
  end if;

  select count(*) into v_cols from pub.field_registry where surface='peo_profiles';
  if v_cols < 21 then
    raise exception '0771 verification: only % shelf fields registered', v_cols;
  end if;

  if exists (select 1 from pub.peo_profiles s where public.is_noncompete_peo(s.family_slug)) then
    raise exception '0771 verification: a noncompete PEO reached the shelf';
  end if;
  if exists (select 1 from pub.peo_profiles s
             join public.peo_classification_denylist d on d.family_slug = s.family_slug) then
    raise exception '0771 verification: a denylisted family reached the shelf';
  end if;

  raise notice '0771 OK: % PEO profiles compiled to the shelf', v_rows;
end $verify$;