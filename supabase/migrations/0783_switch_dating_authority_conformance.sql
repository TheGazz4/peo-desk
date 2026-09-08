-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-switch-dating-authority
-- Articles implemented: VI.2 (reconciliation receipt for the seed backfill), least privilege on
--   SECURITY DEFINER surface, shelf freshness, authored selftests
-- Articles verified not violated: map_reader and PUBLIC gain nothing
-- Verification query attached: YES

-- ============================================================================
-- 0783  Conformance close-out for 0774-0782
--   1. The auditor runs checks through sysaudit_exec_readonly (owned by
--      sysaudit_reader). switch_dating_authority_law called
--      switch_dating_allowed(), which that role could not execute - the check
--      ERRORed instead of passing. A law the auditor cannot evaluate is not
--      enforced.
--   2. trg_switch_dating_authority() is SECURITY DEFINER and had PUBLIC execute
--      by default. Trigger functions need no PUBLIC grant.
--   3. pub.peo_profiles compiled only on the 06:41 nightly, so shelf_freshness
--      (3-hour rule) went RED by mid-morning. Given its own hourly cron.
--   4. The seed backfill inserted 501,639 observation rows with no
--      load_reconciliation receipt, tripping the rowcount-without-reconciliation
--      fence. Receipt filed under source seed_miedge.
-- ============================================================================

grant execute on function public.switch_dating_allowed(text) to sysaudit_reader;

set role peo_gatekeeper;

revoke all on function public.trg_switch_dating_authority() from public;
revoke all on function public.trg_switch_dating_authority() from map_reader;

insert into public.load_reconciliation
  (load_key, source_id, run_id, target_table, source_total, inserted, quarantined, skipped,
   ruleset_version, verification_query, verification_output, verified_at, created_by)
select 'seed_observation_backfill_0775', 'seed_miedge', gen_random_uuid(), 'field_observations',
       196917, 196666, 0, 251, '0775',
       'select count(*) from field_observations where source_hub like ''seed:%''',
       jsonb_build_object(
         'grain', 'one source row = one company carrying a seed PEO string',
         'companies_with_seed_peo', 196917,
         'companies_written', 196666,
         'skipped_noncompete', 251,
         'observations_written', jsonb_build_object('peo_name', 196666, 'peo_user_status', 196666, 'peo_family_slug', 108307),
         'total_observation_rows', 501639,
         'backlog_after', 0,
         'note', 'peo_family_slug is written only where the vendor string resolves to a registered peo_families alias; 88,359 strings did not resolve and are a visible canonicalisation gap, not a loss.'),
       now(), 'instanceA-2026-09-08-seed-observation-backfill'
where not exists (select 1 from public.load_reconciliation where load_key='seed_observation_backfill_0775');

reset role;

select cron.schedule('peo_profiles_shelf_hourly', '17 * * * *',
                     $$select pub.compile_peo_profiles();$$)
where not exists (select 1 from cron.job where jobname = 'peo_profiles_shelf_hourly');

select pub.compile_peo_profiles();

do $verify$
declare v jsonb; v_proved boolean;
begin
  if not has_function_privilege('sysaudit_reader','public.switch_dating_allowed(text)','execute') then
    raise exception '0783 verification: the auditor still cannot evaluate the dating law';
  end if;
  if has_function_privilege('public','public.trg_switch_dating_authority()','execute') then
    raise exception '0783 verification: PUBLIC can still execute the trigger function';
  end if;
  if has_function_privilege('map_reader','public.switch_dating_allowed(text)','execute') then
    raise exception '0783 verification: map_reader can evaluate the dating law';
  end if;
  if not exists (select 1 from cron.job where jobname='peo_profiles_shelf_hourly') then
    raise exception '0783 verification: the PEO profile shelf has no hourly refresh';
  end if;
  if not exists (select 1 from public.load_reconciliation
                 where load_key='seed_observation_backfill_0775' and balanced) then
    raise exception '0783 verification: the seed backfill receipt is missing or unbalanced';
  end if;

  select public.sysaudit_selftest() into v;
  select (elem->>'proved')::boolean into v_proved
  from jsonb_array_elements(v->'detail') elem
  where elem->>'check' = 'switch_dating_authority_law';
  if v_proved is not true then
    raise exception '0783 verification: switch_dating_authority_law selftest not proven';
  end if;

  raise notice '0783 OK: law evaluable by the auditor, trigger fenced, shelf hourly, backfill reconciled';
end $verify$;