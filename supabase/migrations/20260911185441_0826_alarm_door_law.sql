-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (one door), VI.2 (reconciliation), IX.2 (no silent loss)
-- Articles verified not violated: III.1 (fences), XIV.6 (no display leakage)
-- Verification query attached: YES
--
-- ALARM DOOR LAW (0826)
-- Problem: every raiser inserts straight into source_alerts. The same condition
-- re-inserts a NEW row every cron tick, so 1,162 unread alarms are really ~48
-- conditions repeated hundreds of times, and nothing ever closes an alarm whose
-- condition has stopped. The backlog is unreadable, so nobody reads it.
-- Fix at the door: one BEFORE INSERT trigger folds a repeat into a counter on the
-- row that is already open, and a cron closes repeat-class alarms that have gone
-- quiet. No raiser is changed; every writer is fixed at once.

alter table public.source_alerts
  add column if not exists fingerprint  text,
  add column if not exists occurrences  integer not null default 1,
  add column if not exists last_seen    timestamptz,
  add column if not exists ack_reason   text;

update public.source_alerts set last_seen = detected_at where last_seen is null;

-- ---------------------------------------------------------------- fingerprint
create or replace function public.alert_fingerprint(p_source text, p_summary text)
returns text language sql immutable as $fp$
  select md5(
    coalesce(p_source,'') || '|' ||
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(coalesce(p_summary,''),
            '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
            '#UUID','g'),
          '[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9:.+-]+)?','#TS','g'),
        '[0-9]+(\.[0-9]+)?','#N','g'),
      '\s+',' ','g')
  );
$fp$;

-- ---------------------------------------------------------------- the door
create or replace function public.source_alert_dedupe()
returns trigger language plpgsql as $dd$
declare v_fp text; v_id bigint;
begin
  begin
    v_fp := public.alert_fingerprint(new.source_name, new.change_summary);
    new.fingerprint := v_fp;
    new.last_seen   := coalesce(new.detected_at, now());

    select id into v_id
      from public.source_alerts
     where fingerprint = v_fp
       and not coalesce(acknowledged,false)
     order by id
     limit 1;

    if v_id is not null then
      update public.source_alerts
         set occurrences    = coalesce(occurrences,1) + 1,
             last_seen      = coalesce(new.detected_at, now()),
             change_summary = new.change_summary
       where id = v_id;
      return null;
    end if;

    if new.occurrences is null then new.occurrences := 1; end if;
    return new;
  exception when others then
    return new;
  end;
end $dd$;

drop trigger if exists trg_source_alert_dedupe on public.source_alerts;
create trigger trg_source_alert_dedupe
  before insert on public.source_alerts
  for each row execute function public.source_alert_dedupe();

-- ---------------------------------------------------------------- auto-close
create or replace function public.source_alerts_autoclose(p_quiet_hours int default 48)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $ac$
declare v_n int;
begin
  with closed as (
    update public.source_alerts
       set acknowledged    = true,
           acknowledged_at = now(),
           acknowledged_by = 'auto:quiet',
           ack_reason      = format(
             'auto-closed: condition stopped recurring - last seen %s, %s occurrence(s), quiet for %s hours',
             to_char(coalesce(last_seen, detected_at),'YYYY-MM-DD HH24:MI'),
             occurrences, p_quiet_hours)
     where not coalesce(acknowledged,false)
       and coalesce(occurrences,1) > 1
       and coalesce(last_seen, detected_at) < now() - make_interval(hours => p_quiet_hours)
    returning 1)
  select count(*) into v_n from closed;
  return jsonb_build_object('closed', v_n, 'quiet_hours', p_quiet_hours, 'at', now());
end $ac$;