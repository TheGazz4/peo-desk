-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-switch-dating-authority
-- Articles implemented: writer conformance - every writer of a protected table is a gatekeeper
--   door; VI.2 (reconciliation receipt for the family registrations)
-- Articles verified not violated: no privilege is widened; PUBLIC and map_reader unchanged
-- Verification query attached: YES

-- ============================================================================
-- 0784  The PEO profile door was not a gatekeeper door
--
-- writer_conformance_scan went RED overnight naming apply_peo_profile_field:
-- I created it in 0770 as SECURITY DEFINER but owned by postgres, so it wrote
-- protected tables outside the gatekeeper. The law is "every writer of a
-- protected table is a gatekeeper door, or carries a live exemption" - and a
-- door I built myself was the exception. Ownership moved; nothing else changes.
--
-- Also files the missing reconciliation receipt for the 146 peo_families rows
-- registered by 0764 (MEP sponsor adjudication), which tripped the
-- rowcount-without-reconciliation fence the same morning.
-- ============================================================================

alter function public.apply_peo_profile_field(text,text,text,text,text,date) owner to peo_gatekeeper;
alter function public.enqueue_peo_profile_wants(int) owner to peo_gatekeeper;
alter function public.peo_profile_nightly() owner to peo_gatekeeper;

set role peo_gatekeeper;

revoke all on function public.apply_peo_profile_field(text,text,text,text,text,date) from public;
revoke all on function public.apply_peo_profile_field(text,text,text,text,text,date) from map_reader;
grant execute on function public.apply_peo_profile_field(text,text,text,text,text,date) to service_role;

revoke all on function public.enqueue_peo_profile_wants(int) from public;
revoke all on function public.enqueue_peo_profile_wants(int) from map_reader;
grant execute on function public.enqueue_peo_profile_wants(int) to service_role;

revoke all on function public.peo_profile_nightly() from public;
revoke all on function public.peo_profile_nightly() from map_reader;

insert into public.load_reconciliation
  (load_key, source_id, run_id, target_table, source_total, inserted, quarantined, skipped,
   ruleset_version, verification_query, verification_output, verified_at, created_by)
select 'mep_sponsor_family_registration_0764', 'efast_mep', gen_random_uuid(), 'peo_families',
       166, 146, 0, 20, '0763',
       'select count(*) from peo_families where mapping_basis = ''MEP_SPONSOR_RESEARCH_0763''',
       jsonb_build_object(
         'grain','one source row = one adjudicated Form 5500 MEP sponsor',
         'sponsors_adjudicated', 166,
         'verdict_peo', 96,
         'alias_rows_written', 146,
         'skipped_not_peo', 70,
         'note','A PEO sponsor writes a family alias row and, where the family did not exist, a family row. Non-PEO verdicts write nothing to peo_families by design - they are quarantined in identity_adjudication_queue.'),
       now(), 'instanceA-2026-09-07-mep-sponsor-adjudication'
where not exists (select 1 from public.load_reconciliation where load_key='mep_sponsor_family_registration_0764');

reset role;

do $verify$
declare v_owner text;
begin
  select pg_get_userbyid(proowner) into v_owner from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='apply_peo_profile_field';
  if v_owner <> 'peo_gatekeeper' then
    raise exception '0784 verification: the PEO profile door is owned by %, not the gatekeeper', v_owner;
  end if;

  if has_function_privilege('public','public.apply_peo_profile_field(text,text,text,text,text,date)','execute') then
    raise exception '0784 verification: PUBLIC can execute the PEO profile door';
  end if;
  if has_function_privilege('map_reader','public.apply_peo_profile_field(text,text,text,text,text,date)','execute') then
    raise exception '0784 verification: map_reader can execute the PEO profile door';
  end if;

  -- the door still works after the ownership move
  if public.apply_peo_profile_field('helpside','website','x','web') <> 'refused:noncompete' then
    raise exception '0784 verification: the door stopped refusing noncompete after the ownership move';
  end if;

  if not exists (select 1 from public.load_reconciliation
                 where load_key='mep_sponsor_family_registration_0764' and balanced) then
    raise exception '0784 verification: the family-registration receipt is missing or unbalanced';
  end if;

  raise notice '0784 OK: PEO profile door is a gatekeeper door, receipts filed';
end $verify$;