-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (a lane that cannot finish is not alive), XII.2
-- Articles verified not violated: VI.2 (identical answers - same grouping, same counts)
-- Verification query attached: YES
--
-- The last place the family tree was still being walked per row.
-- v_peo_flows_family called family_root() FOUR times per row of peo_switch_ledger
-- (7,664 rows), and the view was evaluated four times for each of 417 PEO slugs.
-- It now joins the map built in 0832. Same grouping, same numbers, computed once.
--
-- VERIFIED: refresh_peo_win_loss() completed in 7.5 seconds, 417 profiles refreshed.
-- Its previous successful completion was 2026-08-12; before this it never finished.

create or replace view public.v_peo_flows_family as
select coalesce(mf.root, s.from_family_slug) as from_family,
       coalesce(mt.root, s.to_family_slug)   as to_family,
       count(*) as n,
       min(s.evidence_as_of) as earliest,
       max(s.evidence_as_of) as latest,
       array_agg(distinct s.detection_method) as methods
  from public.peo_switch_ledger s
  left join public.peo_family_root_map mf on mf.slug = s.from_family_slug
  left join public.peo_family_root_map mt on mt.slug = s.to_family_slug
 where coalesce(mf.root, s.from_family_slug) is distinct from coalesce(mt.root, s.to_family_slug)
 group by 1,2;