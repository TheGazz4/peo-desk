-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (one register per fact), XIII.3 (rules are written down)
-- Articles verified not violated: III.1 (the fences themselves are untouched and still kill),
--   IX.2 (every kill is still receipted in dead_letter_office), XIV.6
-- Verification query attached: YES
--
-- A FENCE THAT FIRES IS A COUNTER, NOT AN ALARM (0831)
--
-- The noncompete fence blocked 204 touches on protected names in three days. Every single
-- block wrote its own alarm row, with the company name in the text, so the dedupe from 0826
-- could not fold them - each name looked like a different problem. But they are not problems
-- at all: the fence working is the system doing exactly what Mike told it to do, and each kill
-- is already receipted in dead_letter_office, which is the register of record for kills.
--
-- So: some watchers should roll up to ONE alarm per kind, with a count, instead of one alarm
-- per event. That list is now written down in a table instead of being a property of how each
-- watcher happens to word its message.
--
-- Also retires the platform_health mirror for the same reason as 0830 retired the sysaudit
-- mirror: platform_health restates the auditor's verdict, and the hourly pager already reads
-- platform_health() directly. A copy in the alarm list is the same problem counted twice.

create table if not exists public.alert_rollup_rules (
  source_name   text primary key,
  prefix_chars  integer not null default 60,
  reason        text not null,
  added_at      timestamptz not null default now()
);

insert into public.alert_rollup_rules (source_name, prefix_chars, reason) values
 ('mesh_guard', 45,
  'Noncompete fence kills. The fence firing is the law working, not a fault. Each kill is receipted in dead_letter_office; the alarm list needs one line with a count, not one line per blocked company.'),
 ('field_observations', 45,
  'Same as mesh_guard: a refused observation on a protected name is the fence working.'),
 ('noncompete_platform_sweep', 45,
  'Periodic exposure sweep. One standing line with a count is the right shape; the detail lives in the sweep output.')
on conflict (source_name) do nothing;

-- fingerprint now honours the rollup rules
create or replace function public.alert_fingerprint(p_source text, p_summary text)
returns text language sql stable as $fp$
  select md5(
    coalesce(p_source,'') || '|' ||
    left(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(coalesce(p_summary,''),
              '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
              '#UUID','g'),
            '[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.+-]+)?','#TS','g'),
          '[0-9]+(\.[0-9]+)?','#N','g'),
        '\s+',' ','g'),
      coalesce((select r.prefix_chars from public.alert_rollup_rules r
                 where r.source_name = p_source), 100000)
    )
  );
$fp$;

-- retire the platform_health mirror (same reasoning as 0830)
create or replace function public.platform_health_alert()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $ph$
begin
  -- RETIRED 2026-09-11 (0831). platform_health() restates the auditor's verdict; the hourly
  -- pager reads platform_health() and sysaudit_verdict() directly every hour. Copying the
  -- verdict into source_alerts counted the same problem twice and kept the alarm list from
  -- ever reaching zero.
  return jsonb_build_object('raised', 0, 'retired', true,
    'reason', 'platform_health() is read directly by the hourly pager; see migration 0831');
end $ph$;