-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0878-plusone (opened BEFORE apply)
-- Articles implemented: II.3 (a Gazz ruling is law), CANONICAL RESOLUTION, QUARANTINE RULES (quarantine, never
--   delete), VII.1 (a switch is between two PEOs), fix-at-the-core (logic + backfill + door + check)
-- Articles verified not violated: III.1, XIII.1, the switch_detection_nightly hold
-- Verification query attached: YES
--
-- RULING (Gazz, 2026-09-12): "Throw out PlusOne."
-- I had flagged PlusOne Solutions as the FROM side of five of twelve sampled seed switch groups and suspected a
-- miEdge labelling artifact. Confirmed: PlusOne Solutions (plusonesolutions.net, part of ServicePower) is a
-- CONTRACTOR COMPLIANCE AND BACKGROUND-SCREENING firm. It does not co-employ anyone. It is not a PEO.
--
-- CONTAMINATION FOUND AND REMOVED
--   1,492 companies carried peo_family_slug = plusonesolutions (1,491 also peo_brand_slug)  -> cleared
--      32 field observations                                                               -> superseded
--      14 switch-ledger rows recording a switch FROM PlusOne                               -> retired (see below)
--      16 adjudication-queue rows                                                          -> dismissed
--       1 peo_families alias                                                               -> quarantined
--       1 peo_profiles row                                                                 -> marked RETIRED
--   2,454 seed rows name it as the PEO (left in staging; the door stops them being promoted again)
--   Of the 1,492: 43 hold other PEO evidence (ADP TotalSource 20, G&A 4, Paychex 4, Justworks 4, Insperity 3 ...)
--   and the real PEO can now surface. 1,449 hold none - they were never PEO users, only screening customers.
--
-- THE 14 "SWITCHES" were a screening vendor mistaken for the incumbent PEO. A switch is a client leaving one PEO
-- for another, so none of these were switches. Scope moved off cross_family with the reason on the row, so they
-- can never count as anyone's win or loss. The "to" side (ADP TotalSource 7, Paychex, Prestige, ProService,
-- Rippling, Spirit HR, SWBC, Vensure) is real and keeps its attribution through the normal evidence path.
--
-- THE DOOR, so it cannot come back on the next seed:
--   not_a_peo_registry (pattern, label, what_it_actually_is, basis, ruled_by) + is_not_a_peo(text)
--   a target_exclusion_patterns row, so record_peo_switch_by_ein already refuses it
--   RED check not_a_peo_attributed: nothing in the registry may ever hold a PEO attribution again
--
-- TWO GUARDS CAUGHT ME, both recorded: "delete from peo_families" was refused (DELETE is revoked platform-wide,
-- correctly - the table carries identity_quarantined_at for exactly this), and my first backfill missed 6
-- observations under field_name='mep_matched' plus the 14 ledger rows, found by the verification query.

create table if not exists public.not_a_peo_registry (
  pattern text primary key, label text not null, what_it_actually_is text not null,
  basis text not null, ruled_by text not null, ruled_at timestamptz not null default now());
alter table public.not_a_peo_registry enable row level security;
create policy not_a_peo_registry_read on public.not_a_peo_registry for select to authenticated, service_role using (true);
grant select on public.not_a_peo_registry to service_role, peo_gatekeeper, sysaudit_reader;

insert into public.not_a_peo_registry (pattern, label, what_it_actually_is, basis, ruled_by) values
 ('PLUS ?ONE ?SOLUTIONS|PLUSONESOLUTIONS|PLUS1SOLUTIONS', 'PlusOne Solutions',
  'contractor compliance and background screening (plusonesolutions.net; part of ServicePower) - does not co-employ',
  'Gazz ruling 2026-09-12 "throw out PlusOne"; confirmed from the company''s own site', 'gazz')
on conflict (pattern) do nothing;

create or replace function public.is_not_a_peo(p text)
returns boolean language sql stable as $f$
  select coalesce(bool_or(public.name_norm(p) ~* r.pattern or p ~* r.pattern), false)
    from public.not_a_peo_registry r where p is not null;
$f$;
revoke execute on function public.is_not_a_peo(text) from public, anon;
grant execute on function public.is_not_a_peo(text) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

insert into public.target_exclusion_patterns (pattern, label, category, basis) values
 ('PLUS ?ONE ?SOLUTIONS|PLUSONESOLUTIONS|PLUS1SOLUTIONS', 'PlusOne Solutions', 'not_a_peo',
  'Gazz ruling 2026-09-12: background screening firm, not a PEO. See not_a_peo_registry.') on conflict do nothing;

set role peo_gatekeeper;
update public.companies set peo_family_slug=null, peo_brand_slug=null
 where peo_family_slug='plusonesolutions' or peo_brand_slug='plusonesolutions';
update public.field_observations set resolution_status='superseded'
 where value_text='plusonesolutions' and resolution_status<>'superseded';
update public.peo_families set identity_quarantined_at=now(),
  identity_quarantine_reason='NOT A PEO: background screening / contractor compliance firm. Gazz ruling 2026-09-12 (0878).'
 where family_slug='plusonesolutions';
update public.peo_switch_ledger set switch_scope='intra_family',
  triage_reason = coalesce(triage_reason,'') || ' || 0879: RETIRED - "from" side PlusOne Solutions is not a PEO; never a switch; excluded from win/loss.'
 where from_family_slug='plusonesolutions' or to_family_slug='plusonesolutions';
reset role;

update public.mesh_backlog_adjudication set status='dismissed',
  ruling='PlusOne Solutions is not a PEO (Gazz ruling 2026-09-12, 0878)', ruled_by='gazz', ruled_at=now()
 where status='open' and (held_peo_family_slug='plusonesolutions' or ledger_peo_family_slug='plusonesolutions');
update public.peo_profiles set display_name = display_name || ' [RETIRED: not a PEO - background screening firm, Gazz 2026-09-12]'
 where family_slug='plusonesolutions' and display_name not like '%RETIRED%';

set role peo_gatekeeper;
insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('not_a_peo_attributed','mesh_law','fast','II.3','RED',
 'Nothing listed in not_a_peo_registry may carry a PEO attribution on a company. PlusOne Solutions - a background screening firm - held 1,492 of them until Gazz threw it out on 2026-09-12.',
 'select c.peo_family_slug, count(*)::bigint as n from public.companies c where c.merged_into is null and c.peo_family_slug is not null and public.is_not_a_peo(c.peo_family_slug) group by 1',
 '{"mode":"zero_rows"}'::jsonb, 'select ''x''::text as peo_family_slug, 1::bigint as n', true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description, enabled=true;
reset role;
select public.refresh_peo_win_loss();

-- VERIFIED: 0 companies attributed | 0 live observations | 0 false switches | alias quarantined
--           | doors block all three name forms | check not_a_peo_attributed = PASS
