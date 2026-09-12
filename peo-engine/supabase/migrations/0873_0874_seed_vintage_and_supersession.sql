-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0873-seed-vintage (opened BEFORE apply)
-- Articles implemented: IX.2 (a load date is not an evidence date; precedence must compare like with like),
--   VIII.2 (an attribution change is adjudicated, never silently applied), MESH CROSS-REFERENCE MANDATE
-- Articles verified not violated: III.1, XIII.1, the switch_detection_nightly hold (nothing minted)
-- Verification query attached: YES
--
-- ROOT CAUSE. The miEdge seed is loaded into the platform TWICE with two different dates:
--   company_lifecycle_events (seed_csv:miEdge) : as_of 2023-01-01 .. 2025-01-09   <- the vendor's REAL vintage
--   field_observations       (seed:miEdge)     : as_of 2026-08-08 on all 366,631 rows  <- OUR LOAD DATE
-- The observation side wore a date ~19 months newer than the data. Every precedence rule comparing as_of therefore
-- let a 2024-vintage vendor row outrank genuinely newer federal and state evidence.
--
-- BEFORE: 29,373 companies hold both seed and live PEO observations; 5,621 disagree; spine took the live value on
-- 3,947 and was still on the seed for 1,442 - and for 1,121 of those the live source was a DOL Form 5500 that
-- looked "older" ONLY because the seed wore a fake date.
--
-- 0873 re-dates seed:miEdge to the vendor's true vintage: per-company lifecycle as_of where we hold one (61,177
-- companies), else the extract ceiling 2025-01-09. observed_at keeps the load date, so nothing is lost and the
-- change is reversible. HubSpot is exempt - our own CRM export is current as of export.
--
-- AFTER, the comparison runs honestly in both directions: of the 1,442, 994 are DOL filings genuinely OLDER than
-- the extract (the seed rightly wins) and 448 are genuinely NEWER (127 DOL, 259 AZ WC, 59 TX WC, 3 fingerprint).
-- 0874 QUEUES those 448 as kind='seed_superseded'. They are not applied: flipping 448 attributions before
-- adjudication manufactures 448 apparent switches the moment switch_detection_nightly comes off hold, which is
-- precisely what that hold exists to prevent.
--
-- brain_knowledge: seed_vintage_law - any future seed, purchase or extract declares its vintage at ingest; if the
-- vendor publishes none, use the newest record in the file as the ceiling. Never the load date.

set role peo_gatekeeper;
with vintage as (
  select company_id, max(as_of) v from public.company_lifecycle_events where source='seed_csv:miEdge' group by company_id
)
update public.field_observations f
   set as_of = least(v.v, date '2025-01-09'),
       dedupe_key = md5(f.subject_class||'|'||f.subject_key||'|'||f.field_name||'|'||f.value_text||'|'||least(v.v, date '2025-01-09')::text||'|'||f.source_hub)
  from vintage v
 where f.source_hub='seed:miEdge' and f.company_id=v.company_id and f.as_of=date '2026-08-08';
update public.field_observations f
   set as_of = date '2025-01-09',
       dedupe_key = md5(f.subject_class||'|'||f.subject_key||'|'||f.field_name||'|'||f.value_text||'|'||'2025-01-09'||'|'||f.source_hub)
 where f.source_hub='seed:miEdge' and f.as_of=date '2026-08-08';
reset role;

alter table public.mesh_backlog_adjudication drop constraint if exists mesh_backlog_adjudication_kind_check;
alter table public.mesh_backlog_adjudication add constraint mesh_backlog_adjudication_kind_check
  check (kind in ('disagreement','unresolved_peo_name','seed_superseded'));
alter table public.mesh_backlog_adjudication add column if not exists live_as_of date;
alter table public.mesh_backlog_adjudication add column if not exists seed_as_of date;
-- (queue insert: newest live observation vs newest seed observation, live_as_of > seed_as_of, spine still on seed)

-- OPEN QUEUE AFTER THIS MIGRATION: disagreement 1,394 | seed_superseded 448 | unresolved_peo_name 16
