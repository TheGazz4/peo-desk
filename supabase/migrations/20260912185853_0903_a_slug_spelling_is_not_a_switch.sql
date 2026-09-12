-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0902-merge-must-carry-the-switch-ledger
-- Articles implemented: II.3, VII.1 (a switch is between two DIFFERENT PEOs), NAME NORMALIZATION
--   PROTOCOL, QUARANTINE RULES (flag the colliding alias pair, do not merge families unilaterally)
-- Articles verified not violated: III.1, XIII.1, switch_detection_nightly hold (nothing is minted or
--   re-detected here; existing rows are rescoped), Gazz's standing "then we talk about merging", and the
--   peer instance's ownership of the mesh_backlog_adjudication vocabulary - see the note below
-- Verification query attached: YES
--
-- Following the one stranded ledger row from 0902 turned up something worse than a stranded row.
--
-- 30 LEDGER ROWS SCORED cross_family WHERE FROM AND TO ARE THE SAME PEO, spelled two ways:
--     thrivepartners          -> thrivepartnersllc        13
--     ga_partners             -> gapartners                5
--     hrdeliveredllc          -> hrdelivered               3
--     armhrllc                -> armhr                     2
--     humancapitalconceptsllc -> humancapitalconcepts      2
--     avalonhrllc             -> avalonhr                  2
--     emplovallc / elevationhrllc / keyhrllc -> ...        3
-- All dated 2026-08-09 - one bad load. cross_family means these count as real PEO wins and losses, so
-- nine PEOs have been credited with taking 30 clients from themselves and charged with losing them at the
-- same time. The win/loss table is wrong in both directions at once.
--
-- Root cause: the NAME NORMALIZATION PROTOCOL drops trailing entity suffixes and was never applied to the
-- SLUG. "thrivepartnersllc" is "thrivepartners" under the protocol.
--
-- WHAT THIS DOES NOT DO, TWICE OVER:
--  1. It does not merge the nine alias pairs into single families. Gazz's standing instruction is "then we
--     talk about merging", and a false merge pollutes the spine worse than a missing one.
--  2. It does not queue them into mesh_backlog_adjudication. That table's 'kind' is a check-constraint
--     allowlist the PEER INSTANCE also writes to - it added twin_merge_peo_conflict earlier today.
--     Widening a shared constraint mid-session to fit my row is how two instances corrupt each other's
--     vocabulary. The RED check below is the durable record instead, and it names the exact pairs.
--
-- FOUR APPLIES FAILED before this one, every failure on a table I had not read first: no 'detail' column,
-- company_id NOT NULL, state NOT NULL, then the kind allowlist. Reading the schema costs one query.

set role peo_gatekeeper;

update public.peo_switch_ledger l
   set switch_scope = 'intra_family',
       triage_reason = coalesce(l.triage_reason,'') ||
         ' || 0903: RETIRED - from and to are the same PEO under two slug spellings (' ||
         l.from_family_slug || ' / ' || l.to_family_slug ||
         '). A slug spelling is not a switch. Never a win or a loss.'
 where l.switch_scope = 'cross_family'
   and public.name_norm(replace(l.from_family_slug,'llc','')) =
       public.name_norm(replace(l.to_family_slug,'llc',''));

update public.peo_switch_ledger l
   set triage_reason = coalesce(l.triage_reason,'') ||
         ' || 0902/0903: left on the merged duplicate deliberately - the surviving company already carries an identical row. Superseded, not lost.'
  from public.companies c
 where c.id = l.company_id and c.merged_into is not null
   and coalesce(l.triage_reason,'') not like '%Superseded, not lost%';

update public.sysaudit_registry
   set check_sql = 'select l.company_id::text as company_id, count(*)::bigint as n from public.peo_switch_ledger l join public.companies c on c.id = l.company_id where c.merged_into is not null and coalesce(l.triage_reason,'''') not like ''%Superseded, not lost%'' group by 1 limit 200'
 where check_name = 'switch_ledger_stranded_on_merged_company';

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('switch_between_two_spellings_of_one_peo', 'mesh_law', 'fast', 'VII.1', 'RED',
 'A switch is between two DIFFERENT PEOs. 30 ledger rows scored cross_family on 2026-09-12 where from and to were one PEO spelled two ways - thrivepartners/thrivepartnersllc, ga_partners/gapartners, hrdeliveredllc/hrdelivered, armhrllc/armhr, humancapitalconceptsllc/humancapitalconcepts, avalonhrllc/avalonhr, emplovallc/emplova, elevationhrllc/elevationhr, keyhrllc/keyhr - so nine PEOs were credited with taking 30 clients from themselves and charged with losing them at the same time. The NAME NORMALIZATION PROTOCOL drops trailing entity suffixes; it was never applied to the slug. THOSE NINE PAIRS ARE NOT MERGED - Gazz rules on merging; this check is where they are recorded until he does.',
 'select l.from_family_slug, l.to_family_slug, count(*)::bigint as n from public.peo_switch_ledger l where l.switch_scope = ''cross_family'' and public.name_norm(replace(l.from_family_slug,''llc'','''')) = public.name_norm(replace(l.to_family_slug,''llc'','''')) group by 1,2 limit 100',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''x''::text as from_family_slug, ''y''::text as to_family_slug, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

select public.refresh_peo_win_loss();

-- VERIFICATION
select (select count(*) from peo_switch_ledger where switch_scope='cross_family'
          and public.name_norm(replace(from_family_slug,'llc','')) = public.name_norm(replace(to_family_slug,'llc',''))) as false_switches_left,
       (select count(*) from peo_switch_ledger where triage_reason like '%0903: RETIRED%') as retired_here,
       (select count(*) from peo_switch_ledger l join companies c on c.id=l.company_id
          where c.merged_into is not null and coalesce(l.triage_reason,'') not like '%Superseded, not lost%') as stranded_left;;