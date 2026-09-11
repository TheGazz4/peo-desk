-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (every lane has a driver), VI.2 (reconciliation), XIII.3 (contracts true)
-- Articles verified not violated: III.1 (fences), II.3/XIV.1 (canonical families)
-- Verification query attached: YES
--
-- TWO DEFECTS THE ALARM LIST WAS SITTING ON:
--
-- 1. AZ STATE FOOTPRINT HAD NO DRIVER.
--    Florida's leg runs on cron (state_footprint_derive_fl, jobid 699). Arizona's
--    derive_state_footprint_az() existed since 0572 and was never scheduled, so
--    1,117 matched Arizona companies had no AZ footprint row and the multi-state
--    view under-counted them. This is the "archive with no promoter" defect class:
--    the work function is correct, nobody ever wired it to a clock.
--    Backfill already run this session: 1,138 AZ rows inserted, 1,111 operating_states synced.
--
-- 2. efast_5500's CONTRACT NAMED A CRON THAT DOES NOT EXIST.
--    data_hubs.contact_crons listed 'source_watch_weekly'. The live job is
--    'source_watch_hourly' (jobid 804) and has been doing the work the whole time.
--    Correcting the contract to the truth; NOT creating a second redundant watcher.

select cron.schedule('state_footprint_derive_az', '11,41 * * * *',
                     'select public.derive_state_footprint_az()');

update public.data_hubs
   set contact_crons = array['efast_pump','source_watch_hourly','efast_url_rotate','efast_intel']
 where hub_slug = 'efast_5500';

-- a state leg with no clock must never again be invisible
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
  'state_footprint_leg_scheduled', 'mechanical', 'XI.1', 'fast', 'RED',
  'Every derive_state_footprint_<state>() function must be attached to an active cron job. A derivation function with no clock is dead code that silently starves the multi-state footprint.',
  'select p.proname as unscheduled_leg from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = ''public'' and p.proname ~ ''^derive_state_footprint_[a-z]{2}$'' and not exists (select 1 from cron.job j where j.active and j.command ilike ''%'' || p.proname || ''%'')',
  '{"mode":"zero_rows"}'::jsonb,
  'select ''derive_state_footprint_zz''::text as unscheduled_leg'
)
on conflict (check_name) do nothing;

reset role;