-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0875-hubspot-vintage (opened BEFORE apply)
-- Articles implemented: IX.2 (a load date is never an evidence date; an assumption is labelled as one),
--   XIV.6 (the words on the surface must be true)
-- Articles verified not violated: III.1, XIII.1. observed_at keeps the load date: fully reversible.
-- Verification query attached: YES
--
-- RULING (Gazz, 2026-09-12): "HubSpot is dated. Treat it as old just like seed data."
-- 0873 had exempted HubSpot on my reasoning that a CRM export is current as of export. Gazz says the CRM itself is
-- stale, so that reasoning was wrong. Same correction, same method:
--   seed:HubSpot  122,971 rows / 43,108 companies  all as_of 2026-08-08 (our load date)
--   seed:unknown   12,027 rows /  4,009 companies  all as_of 2026-08-08 (our load date)
--
-- HONEST PROBLEM: neither carries vintage evidence. HubSpot evidence_ref is batch/row numbers
-- ("seed:HubSpot:01:9893"); no HubSpot lifecycle rows exist; no export date anywhere. So the date used is an
-- ASSUMPTION, not a measurement: both arrived in the same 2026-08-08 load as the miEdge extract, whose records top
-- out at 2025-01-09, so that is the ceiling. It is LABELLED as an assumption rather than buried -
-- hub_check_cadence now carries vintage_basis (live | published | derived_from_records | assumed_ceiling |
-- unknown) and vintage_ceiling. If Gazz supplies the real HubSpot export date, one UPDATE replaces it.
--
-- WORDING FIX: with the load date gone, "Vendor records, loaded Aug 2026" would have rendered "loaded Jan 2025",
-- which is false - Jan 2025 is the data's ceiling, not when we loaded it. A snapshot with an assumed vintage now
-- reads "Vendor records, no newer than Jan 2025"; one with a real vintage reads "Vendor records, Mon YYYY".

alter table public.hub_check_cadence add column if not exists vintage_basis text
  check (vintage_basis is null or vintage_basis in ('live','published','derived_from_records','assumed_ceiling','unknown'));
alter table public.hub_check_cadence add column if not exists vintage_ceiling date;
update public.hub_check_cadence set vintage_basis='live' where cadence_days is not null and vintage_basis is null;
update public.hub_check_cadence set vintage_basis='derived_from_records', vintage_ceiling=date '2025-01-09' where hub in ('seed:miEdge','seed_csv:miEdge');
update public.hub_check_cadence set vintage_basis='assumed_ceiling', vintage_ceiling=date '2025-01-09' where hub in ('seed:HubSpot','seed:unknown');
update public.hub_check_cadence set vintage_basis='unknown' where vintage_basis is null;

set role peo_gatekeeper;
update public.field_observations f
   set as_of = date '2025-01-09',
       dedupe_key = md5(f.subject_class||'|'||f.subject_key||'|'||f.field_name||'|'||f.value_text||'|'||'2025-01-09'||'|'||f.source_hub)
 where f.source_hub in ('seed:HubSpot','seed:unknown') and f.as_of = date '2026-08-08';
reset role;

-- company_as_of(): adds as_of_vintage_basis, and the snapshot display no longer says "loaded".
--   not a snapshot          -> the date at its grain
--   assumed_ceiling         -> 'Vendor records, no newer than Mon YYYY'
--   otherwise               -> 'Vendor records, Mon YYYY'
-- (full body live in the database)

-- RESULT, 3,000-company sample: 0 future dates | 1,218 fresh | 197 stale | 1,466 vendor-only
--   (1,100 derived vintage, 366 assumed) | 119 no evidence.
-- Supersession queue after re-dating: disagreement 1,394 | seed_superseded 477 | unresolved_peo_name 16.
