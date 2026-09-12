-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0877-multistate (opened BEFORE apply)
-- Articles implemented: CANONICAL RESOLUTION (one company, every state on its footprint), EIN POLICY,
--   QUARANTINE RULES (never merge on a name alone)
-- Articles verified not violated: III.1, XIII.1, the switch_detection_nightly hold
-- PARALLEL-INSTANCE NOTE: the first apply FAILED because the kind constraint already carried
--   'twin_merge_peo_conflict' (23 rows, 03:36 UTC) added by the PEER INSTANCE in this same table. Its value is
--   preserved in the new constraint and its rows are untouched. Both instances are now writing
--   mesh_backlog_adjudication - worth a coordination call.
-- Verification query attached: YES
--
-- GAZZ: "there is a possibility of multi-state operations and hence why a biz might show up in more than one state."
-- Right, and it invalidates how 0876 labelled the seed findings.
--
--   EMPERION INC, one EIN, four states, all on the same date:
--     Colorado/Denver -> EmPower HR | Georgia/Roswell -> EmPower HR | Missouri/Rolla -> EmPower HR
--     Illinois/Springfield -> Justworks
--   ONE company in four states running two PEOs. Not a contradiction, not a switch.
--   0876 filed it as "seed_internal_conflict". Wrong.
--
-- CORRECTED SHAPE RULE (identity = EIN; PEO canonicalized first):
--   same state,  different date  -> SWITCH                  13
--   multi-state, different date  -> AMBIGUOUS               32   (new state location, or a switch - research)
--   multi-state, same date       -> MULTI-STATE FOOTPRINT   18   (NOT a switch; a consolidation target)
--   same state,  same date       -> CONTRADICTION            1   (quarantine)
-- 0876 reported 45 switches and 19 conflicts. The truth is 13 / 32 / 18 / 1.
-- 43 of the 50 multi-state groups already carry a multi-state company_state_footprint: the machinery was sound,
-- the labelling was not.
--
-- CROSS-STATE DUPLICATES - A SCAN NEVER RUN. dupe_scan grouped by name + STATE, so it could only ever find
-- same-state twins. Across states there are 20,148 distinctive-name groups. In the seed, 17,414 of those carry an
-- arbiter: 12,145 share exactly one EIN, 8,700 exactly one domain, 9,106 exactly one phone; 1,008 carry MULTIPLE
-- domains (different businesses); 3,074 have nothing to arbitrate with. Recorded, not acted on.

alter table public.mesh_backlog_adjudication drop constraint if exists mesh_backlog_adjudication_kind_check;
alter table public.mesh_backlog_adjudication add constraint mesh_backlog_adjudication_kind_check
  check (kind in ('disagreement','unresolved_peo_name','seed_superseded','seed_internal_switch',
                  'seed_internal_conflict','twin_merge_peo_conflict','multi_state_ambiguous','multi_state_footprint'));
alter table public.mesh_backlog_adjudication add column if not exists state_count int;
alter table public.mesh_backlog_adjudication add column if not exists date_count int;
alter table public.mesh_backlog_adjudication add column if not exists states_seen text;
-- (reclassification UPDATE by EIN shape: see live table)

-- brain_knowledge: multi_state_identity_law - shape before verdict; arbiter ladder EIN 1.00 > domain 0.90 >
-- phone 0.85 > nothing; never merge across states on a name alone (MOUSES EAR is five businesses).
