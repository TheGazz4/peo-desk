-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0845-schedule-never-owns-identity
-- Articles implemented: II.1 (EIN-first identity), XI.1 (one door, main form is the door for identity),
--   VI.2 (repair is measured before and after), XIII.3 (the rule has a check)
-- Articles verified not violated: III.1, II.2, IX.2 (nothing deleted - rows are re-keyed, with a log)
-- Verification query attached: YES
--
-- A SCHEDULE NEVER OWNS IDENTITY.
--
-- WHAT WE THOUGHT: "the EIN on a Form 5500 is often the third-party administrator's."
-- WHAT IS TRUE: the EIN on the MAIN FORM (line 2b, SPONS_DFE_EIN) is the sponsor's. Our loader
-- reads that column correctly. The corruption came from a different file entirely: the Schedule MEP
-- dataset, which DOL publishes as its own file and which our loader ingests as its own lane
-- (sch_mep_2023, sch_mep_2024, sch_mep_2025). In that file the EIN column carries, in practice,
-- the FILER'S EIN - the TPA that prepared the schedule - and one TPA prepares dozens of them.
-- Proof in our own rows: sch_mep_2023 has 2,287 rows but only 232 distinct EINs, about ten plans
-- per EIN, and admin_name is the same TPA on every one.
--
-- HOW IT GOT INTO OUR IDENTITY COLUMN: efast-pump v11 let the Schedule MEP lane INSERT the row
-- first, writing that filer EIN into `ein`. When the main form arrived for the same filing, the
-- null-enrichment rule coalesce(existing.ein, excluded.ein) kept the first value and threw away
-- the sponsor's real EIN. 546 filings, 200 filer EINs, 311 real sponsors - including
-- HELPSIDE INC. 401(K) PLAN, stamped with National Benefit Services' EIN. That is the whole
-- Helpside incident, the MMC "562 clients" mirage, and most of the 855 "administrator EINs".
--
-- FIXED AT THE DOOR: efast-pump v12 (deployed 2026-09-11). flushMepHdr never writes `ein`;
-- flushMain overwrites `ein` when the existing row was created by a schedule lane and takes lane
-- ownership. main_2023/2024/2025 have been forced to re-read now instead of next week.
--
-- THIS MIGRATION: the measured repair, the re-key of everything downstream that consumed the
-- bad EIN, and the check that makes a recurrence a RED.

-- ---------------------------------------------------------------- repair finish (run when lanes are idle)
create or replace function public.efast_identity_repair_finish()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_repaired int := 0; v_rekeyed int := 0; v_pending int; v_lanes_busy int;
        v_identity_rekeyed int := 0;
begin
  select count(*) into v_lanes_busy from public.efast_load_state
   where lane in ('main_2023','main_2024','main_2025') and status <> 'idle';

  -- 1. mark rows the loader has already corrected
  with fixed as (
    update public.efast_identity_repair_log l
       set ein_after = s.ein, repaired_at = now()
      from public.efast_5500_staging s
     where s.ack_id = l.ack_id
       and l.repaired_at is null
       and left(s.lane,4) not in ('sch_','dcg_')
       and s.ein is distinct from l.ein_before
    returning 1)
  select count(*) into v_repaired from fixed;

  -- 2. re-key the promoted participant rows that carried the filer EIN
  with fixed as (
    select l.ack_id, l.form_year, l.ein_before, s.ein as ein_after, s.sponsor_name
      from public.efast_identity_repair_log l
      join public.efast_5500_staging s on s.ack_id = l.ack_id
     where l.repaired_at is not null and l.ein_after is not null
  ), rk as (
    update public.form5500_mep_participants m
       set sponsor_ein = f.ein_after,
           peo_slug = lower(regexp_replace(f.sponsor_name, '[^A-Za-z0-9]', '', 'g')),
           identity_trust = 'REKEYED (0845): sponsor EIN was the schedule filer''s ('||f.ein_before||'); now the main-form sponsor EIN'
      from fixed f
      join public.efast_mep_part_staging p on p.ack_id = f.ack_id
     where m.sponsor_ein = f.ein_before
       and m.filing_year = f.form_year
       and public.ein_norm(m.ein) = public.ein_norm(p.employer_ein)
    returning 1)
  select count(*) into v_rekeyed from rk;

  -- 3. the sponsor-identity ledger: move rows keyed on a filer EIN onto the sponsor's real EIN
  with fixed as (
    select distinct l.ein_before, s.ein as ein_after, s.plan_name
      from public.efast_identity_repair_log l
      join public.efast_5500_staging s on s.ack_id = l.ack_id
     where l.repaired_at is not null and l.ein_after is not null
  ), mv as (
    update public.mep_sponsor_identity i
       set sponsor_ein = f.ein_after,
           evidence = coalesce(i.evidence,'') || ' [0845: re-keyed from filer EIN '||f.ein_before||' to sponsor EIN '||f.ein_after||']'
      from fixed f
     where i.sponsor_ein = f.ein_before and i.plan_name = f.plan_name
       and not exists (select 1 from public.mep_sponsor_identity x where x.sponsor_ein = f.ein_after and x.plan_name = f.plan_name)
    returning 1)
  select count(*) into v_identity_rekeyed from mv;

  select count(*) into v_pending from public.efast_identity_repair_log where repaired_at is null;

  -- 4. everything derived from staging EINs is recomputed
  if v_lanes_busy = 0 and v_pending = 0 then
    refresh materialized view concurrently public.ein_identity_class;
    perform public.backfill_profile_sponsor_eins();
    perform public.detect_peo_rebrands();
    perform public.sync_rebrands_to_profiles();
  end if;

  return jsonb_build_object('lanes_still_reading', v_lanes_busy, 'rows_repaired_this_call', v_repaired,
    'participant_rows_rekeyed', v_rekeyed, 'identity_ledger_rekeyed', v_identity_rekeyed,
    'rows_still_pending', v_pending, 'downstream_recomputed', (v_lanes_busy = 0 and v_pending = 0));
end $f$;
revoke execute on function public.efast_identity_repair_finish() from public;

-- run it every 10 minutes until the log is clear, then it is a harmless no-op
select cron.schedule('efast_identity_repair_finish', '*/10 * * * *', 'select public.efast_identity_repair_finish()');

-- ---------------------------------------------------------------- the check
set role peo_gatekeeper;
insert into public.sysaudit_registry
 (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'efast_schedule_owns_identity','mechanical','II.1/XI.1','fast','RED',
 'A Form 5500 filing''s sponsor identity (the ein column) must come from the MAIN form, never from a schedule. Any staged filing that has a sponsor name but whose row is still owned by a sch_* or dcg_* lane carries a filer/administrator EIN in place of the sponsor''s. This is the mechanism behind the Helpside incident (0845).',
 'select ack_id, form_year, lane, ein, left(sponsor_name,60) as sponsor from public.efast_5500_staging where sponsor_name is not null and left(lane,4) in (''sch_'',''dcg_'') limit 100',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''selftest''::text as ack_id, 2024 as form_year, ''sch_mep_2024''::text as lane, ''000000000''::text as ein, ''x''::text as sponsor')
on conflict (check_name) do nothing;
reset role;
select public.sysaudit_ratify('check','efast_schedule_owns_identity','gazz');

insert into public.brain_knowledge (scope, key, content)
values ('doctrine','form5500_identity_source_law',
 'The sponsor EIN of a Form 5500 filing comes from the MAIN form (line 2b, SPONS_DFE_EIN) and from nowhere else. DOL publishes each schedule (MEP, A, C, DCG...) as its own dataset, and the EIN column on a schedule file is, in practice, the FILER''s EIN - the TPA that prepared it - which one firm reuses across dozens of unrelated plans (sch_mep_2023: 2,287 rows, 232 EINs). A schedule lane may enrich a filing (plan type, participating employers, carriers) but may never create or overwrite its identity. In the loader this means: schedule lanes never write ein; the main form overwrites ein on any row a schedule created. Guarded by check efast_schedule_owns_identity. Discovered 2026-09-11 while tracing how a protected PEO''s client roster entered the platform under a Utah TPA''s EIN.');