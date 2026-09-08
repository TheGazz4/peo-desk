-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-fl-promotion-gap-and-intake-conformance (#165)
-- Articles implemented: every public table carries RLS and a semantic role; a new law table must
--                       itself satisfy the laws it joins.
-- Articles verified not violated: sourcing never displayed; carrier internal-only; noncompete PEOs
--                       never worked; gatekeeper ownership of sysaudit tables respected.
-- Verification query attached: YES
--
-- 0794 added mesh_intake_parity_registry without RLS or a semantic role. rls_on_every_public_table
-- caught it on the very next audit run - it was the ONLY table in public without RLS. Logged here
-- rather than quietly patched: the auditor caught my own new table, which is the intended behaviour.

alter table public.mesh_intake_parity_registry enable row level security;

drop policy if exists mesh_intake_parity_registry_read on public.mesh_intake_parity_registry;
create policy mesh_intake_parity_registry_read
  on public.mesh_intake_parity_registry for select
  to service_role, sysaudit_reader using (true);

set role peo_gatekeeper;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('mesh_intake_parity_registry', 'table', 'registry',
        'Declares, per live state, how many distinct employers the source carries as a co-employment relationship. Read by mesh_intake_parity_law and mesh_intake_parity_coverage.',
        'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('wcio_leasing_policy_codes', 'table', 'registry',
        'WCIO Employee Leasing Policy Type codes 1-9 with published meaning and source URL. Cited by the TX projection and by the TX intake parity declaration.',
        'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- VERIFICATION
-- select relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
--  where n.nspname='public' and c.relkind='r' and not c.relrowsecurity;   -- must be empty