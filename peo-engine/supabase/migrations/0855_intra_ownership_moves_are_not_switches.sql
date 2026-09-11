-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0855-intra-ownership
-- Articles implemented: VII.1 (a switch is a client choosing a competitor; a parent moving a client between its own brands is not),
--   XIV.4 (win/loss and plays must not count internal moves)
-- Articles verified not violated: III.1, IX.2, never-aggregate law (brands keep their identity; only the SCOPE label changes)
-- Verification query attached: YES
--
-- Gazz 2026-09-11: scope Vensure's 274 brand-to-parent "switches" as intra-ownership.
-- LEVEL 1 (logic): record_peo_switch_by_ein() already labels a move 'intra_family' when family_root(from)=family_root(to)
--   (peo_brand_hierarchy is the ownership map). The mis-scoped rows predate that map (loaded 2026-08-09).
--   'intra_family' IS the platform's intra-ownership scope; no new enum value.
-- LEVEL 2 (backfill): every cross_family row whose two sides share an ownership root -> intra_family
--   (Vensure 303, Paychex 159, Resourcing Edge 5, PEOPLease 4, Simploy 3 = 474). Proven-switcher angles minted from them retired (371).
-- LEVEL 3 (display/audit): new RED check keeps it from recurring; win/loss refreshed.

set role peo_gatekeeper;
update public.peo_switch_ledger s
   set switch_scope = 'intra_family',
       triage_reason = coalesce(triage_reason,'') || ' || 0855: rescoped cross_family -> intra_family (same ownership root '||family_root(from_family_slug)||')'
 where switch_scope = 'cross_family'
   and family_root(from_family_slug) = family_root(to_family_slug);
reset role;

update public.company_angles a
   set status = 'retired'
  from public.peo_switch_ledger s
 where a.angle_type = 'proven_switcher' and a.status = 'live'
   and a.evidence_hash = md5(s.company_id::text||':proven_switcher:'||s.id)
   and s.switch_scope = 'intra_family';

set role peo_gatekeeper;
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('switch_scope_matches_ownership', 'mesh_law', 'fast', 'VII.1', 'RED',
 'A switch between two brands under the same ownership root (peo_brand_hierarchy) must be scoped intra_family, never cross_family. Cross_family here inflates the parent''s wins and the brand''s losses and mints false proven_switcher plays (0855).',
 'select from_family_slug, to_family_slug, count(*)::bigint as n from public.peo_switch_ledger where switch_scope = ''cross_family'' and public.family_root(from_family_slug) = public.family_root(to_family_slug) group by 1,2',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''a''::text as from_family_slug, ''b''::text as to_family_slug, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql = excluded.check_sql, description = excluded.description;
reset role;

insert into public.brain_knowledge(scope, key, content) values ('doctrine','intra_ownership_switch_law',
'A move from one brand to another under the same ownership root (peo_brand_hierarchy -> family_root) is NOT a switch. It is scoped intra_family in peo_switch_ledger, stays in the client''s history as a plan move, is excluded from win/loss and from the proven_switcher play. Only cross_family = a client choosing a competitor. Brands keep their own profiles and clients (never-aggregate law unchanged); only the scope label reflects ownership. Ruled by Gazz 2026-09-11 on Vensure (EmPower HR, Harbor America, Tandem HR, etc.).')
on conflict (scope, key) do update set content = excluded.content;

select public.refresh_peo_win_loss();

-- Verification (result 2026-09-11: still_misscoped 0, intra_family 484, angles_retired 371)
select (select count(*) from public.peo_switch_ledger where switch_scope='cross_family' and family_root(from_family_slug)=family_root(to_family_slug)) as still_misscoped,
       (select count(*) from public.peo_switch_ledger where switch_scope='intra_family') as intra_family_now,
       (select count(*) from public.company_angles where angle_type='proven_switcher' and status='retired') as angles_retired;
