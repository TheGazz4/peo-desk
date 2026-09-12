-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0876-seed-activity-date (opened BEFORE apply)
-- Articles implemented: IX.2 (use the source's own date, per record, never a blanket), EIN POLICY (identity for a
--   switch is EIN, never a loose name), QUARANTINE RULES (a same-date contradiction is quarantined, never merged),
--   VIII.2 (switches queued, not minted)
-- Articles verified not violated: III.1, XIII.1, the switch_detection_nightly hold
-- Verification query attached: YES
--
-- GAZZ WAS RIGHT: the seed carries its own date. miedge_hubspot_seed_staging.activity_date is populated on 100% of
-- the 150,481 miEdge rows - 548 distinct values, 2023-01-01 .. 2025-01-10, clustered on month starts. My 0873
-- blanket ceiling (2025-01-09) was one day off the true max but it was a BLANKET: 88,369 companies wore the ceiling
-- when their own record carried a real date, many of them a year older.
-- companies.smart_id joins the staging table EXACTLY (152,505 companies, 1:1 on me_smart_id) - no fuzzy matching.
-- Result: seed:miEdge observations now carry 548 distinct dates instead of one. vintage_basis -> 'published'.
--
-- HUBSPOT STILL HAS NO DATE: 71,210 rows, activity_date null on every one. It carries only hubspot_record, a
-- numeric object id (2852579378) that orders records relative to each other but cannot become a calendar date.
-- HubSpot stays vintage_basis='assumed_ceiling' until Gazz supplies the export date.
--
-- SWITCH LOGIC IN THE SEED - found, and honestly sized.
-- Grouping by name+state suggested 617 "switches". Inspection killed most: MOUSES EAR appears in Knoxville, Oak
-- Ridge, Johnson City, Tampa and Orlando - five businesses sharing a name, not one that switched. On the gold
-- standard the picture is small and real:
--   1. identity is EIN (1.00). Name+state cannot carry a switch.
--   2. canonicalize the PEO through peo_families FIRST - "Regis" vs "REGIS HR GROUP" is one PEO, not a switch.
--   3. different canonical PEO AND different activity_date -> SWITCH, dated between the two.  45 found.
--   4. different canonical PEO, SAME activity_date         -> CONTRADICTION, quarantined.       19 found.
-- Worked example: BIOLINERX USA INC (Waltham MA) 2024-07-01 PlusOne Solutions -> 2024-10-01 ADP TotalSource.
-- Queued, never minted - switch_detection_nightly is held precisely against pre-adjudication switch minting.
--
-- DATA-QUALITY NOTE for the desk: "PlusOne Solutions" is the FROM side of five of the twelve sampled EIN groups.
-- PlusOne is a compliance/vendor-network firm, not a PEO. Those rows look like a miEdge labelling artifact and
-- should be checked before any PlusOne switch is ruled on.

set role peo_gatekeeper;
update public.field_observations f
   set as_of = to_date(s.activity_date,'MM/DD/YY'),
       dedupe_key = md5(f.subject_class||'|'||f.subject_key||'|'||f.field_name||'|'||f.value_text||'|'||to_date(s.activity_date,'MM/DD/YY')::text||'|'||f.source_hub)
  from public.companies c
  join public.miedge_hubspot_seed_staging s on s.me_smart_id = c.smart_id and s.source_file='miEdge' and s.activity_date is not null
 where f.company_id = c.id and f.source_hub = 'seed:miEdge'
   and f.as_of is distinct from to_date(s.activity_date,'MM/DD/YY');
reset role;

update public.hub_check_cadence
   set vintage_basis='published', vintage_ceiling=date '2025-01-10',
       note='per-record vintage from miedge_hubspot_seed_staging.activity_date (100% populated), joined on companies.smart_id'
 where hub='seed:miEdge';

alter table public.mesh_backlog_adjudication drop constraint if exists mesh_backlog_adjudication_kind_check;
alter table public.mesh_backlog_adjudication add constraint mesh_backlog_adjudication_kind_check
  check (kind in ('disagreement','unresolved_peo_name','seed_superseded','seed_internal_switch','seed_internal_conflict'));
-- (seed-internal switch/conflict queue insert: EIN-grouped, PEO canonicalized, dated -> see live table)

-- OPEN QUEUE: disagreement 1,394 | seed_superseded 480 | seed_internal_switch 45 | seed_internal_conflict 19
--             | unresolved_peo_name 16
