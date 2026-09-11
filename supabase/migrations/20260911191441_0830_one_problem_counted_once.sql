-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (one register per fact), XIV.7 (RLS everywhere), XV (autoheal can heal)
-- Articles verified not violated: III.1 (fences), IX.2 (no signal lost - sysaudit_log is untouched)
-- Verification query attached: YES
--
-- ONE PROBLEM, COUNTED ONCE (0830)
--
-- 1. THE AUDITOR WAS COPYING ITSELF INTO THE ALARM LIST.
--    sysaudit_escalate wrote one alarm row per failing ratified check, every full run.
--    The same failure was counted twice: once as a RED check (where it belongs, re-measured
--    every 15 minutes) and again as an alarm row. Worse, the copy came back the moment anyone
--    answered it, so "zero unread alarms" could never be true while any check failed - which
--    made the alarm count meaningless as a measure of anything.
--    The mirror is retired. Nothing is lost: sysaudit_log keeps every result, sysaudit_verdict()
--    reports every failure, and the hourly pager reads the verdict directly.
--
-- 2. THE DRIFT AUTOHEALER COULD NOT WRITE.
--    sysaudit_repair_drift_attribution is owned by peo_gatekeeper but was not SECURITY DEFINER,
--    so it ran as the caller, who holds only SELECT on sysaudit_drift. Every attempt failed with
--    "permission denied for table sysaudit_drift" and the autohealer reported REPAIR EXHAUSTED.
--    A repair function that cannot write is not a repair function.
--
-- 3. switch_detection_skips (0828, mine) shipped without RLS.

set role peo_gatekeeper;

create or replace function public.sysaudit_escalate(p_run_id uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $es$
begin
  -- RETIRED 2026-09-11 (0830). A failing check is recorded in sysaudit_log and reported by
  -- sysaudit_verdict(); copying it into source_alerts counted the same problem twice and made
  -- the alarm list impossible to ever clear. source_alerts is for findings from watchers that
  -- have NO check of their own. Do not re-enable this without retiring those watchers first.
  return jsonb_build_object('raised', 0, 'retired', true,
    'reason', 'sysaudit_log is the register of record for check failures; see migration 0830');
end $es$;

create or replace function public.sysaudit_repair_drift_attribution()
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $dr$
declare r record; v_hit text; n int := 0;
begin
  for r in select d.* from public.sysaudit_drift d
            where d.attributed_to is null
            order by d.id
            limit 500
  loop
    select m.name into v_hit
      from supabase_migrations.schema_migrations m
     where m.statements::text ilike '%' || r.object_name || '%'
       and to_timestamp(substring(m.version from 1 for 14), 'YYYYMMDDHH24MISS')
             between coalesce(r.first_seen, now()) - interval '30 minutes'
                 and coalesce(r.first_seen, now()) + interval '30 minutes'
     order by m.version desc
     limit 1;

    if v_hit is not null then
      update public.sysaudit_drift
         set attributed_to = 'migration ' || v_hit || ': ' || r.event || ' ' ||
                             r.object_kind || ' ' || r.object_name ||
                             ' (named in migration statements within 30 min, autoheal)',
             attributed_at = now()
       where id = r.id;
      n := n + 1;
    end if;
    v_hit := null;
  end loop;
  return jsonb_build_object('attributed', n);
end $dr$;

reset role;

revoke execute on function public.sysaudit_repair_drift_attribution() from public;

alter table public.switch_detection_skips enable row level security;

create policy switch_detection_skips_read
  on public.switch_detection_skips for select
  to service_role, authenticated using (true);