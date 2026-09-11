-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-11-lockstep-protocol (#180)
-- Articles implemented: LOCKSTEP LAW. More than one session writes this database - an interactive
--                       session and an hourly unattended pager, both running as instanceA. Until now
--                       nothing coordinated them. Two sessions may still work in parallel, but never
--                       on the same AREA at the same time, and a migration number is ALLOCATED, never
--                       chosen by hand.
-- Articles verified not violated: nothing here edits data, a lane, a law or a check's expectation.
--                       Locks are advisory-by-area and time-limited so a dead session cannot block
--                       the platform forever. Sourcing never displayed; carrier internal-only;
--                       noncompete PEOs never worked.
-- Verification query attached: YES
--
-- THE EVIDENCE
-- 80 migration numbers have been used more than once. 93 duplicate files. The oldest is 0089,
-- 2026-08. Worst cases: 0589 used EIGHT times, 0588 seven, 0519 and 0331 three each. Today 0811 was
-- used twice - once by the hourly pager at 03:43 and once by the interactive session at 11:01.
-- next_migration_no() has always been a safe atomic sequence. The collisions happened because
-- sessions did not call it - they read the last number and hand-picked the next. Two sessions
-- reading the same last number pick the same next number.
--
-- WHY IT MATTERS BEYOND TIDINESS
-- Two migrations with one number are two different changes with one name. Rolling back, auditing
-- "what changed when", and reading history all silently pick one and ignore the other. It is also
-- how one session's fix quietly replaces another's without either noticing.

-- 1. AREA LOCKS -------------------------------------------------------------
create table if not exists public.work_area_lock (
  area        text primary key,
  holder      text        not null,
  claimed_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  note        text
);

comment on table public.work_area_lock is
 'One row per area of the platform currently being worked. A second session claiming a held area is refused and told who holds it. Locks expire so a dead session cannot block the platform.';

alter table public.work_area_lock enable row level security;
drop policy if exists work_area_lock_read on public.work_area_lock;
create policy work_area_lock_read on public.work_area_lock for select
  to service_role, sysaudit_reader using (true);
grant select on public.work_area_lock to service_role, sysaudit_reader;

create or replace function public.work_lock_claim(p_area text, p_holder text, p_ttl_minutes int default 90)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare v record;
begin
  delete from public.work_area_lock where expires_at < now();          -- expired locks are not locks
  select * into v from public.work_area_lock where area = p_area;
  if v.area is not null and v.holder <> p_holder then
    return jsonb_build_object('granted', false, 'area', p_area,
      'held_by', v.holder, 'since', v.claimed_at, 'expires', v.expires_at,
      'guidance', 'Do not write in this area. Work elsewhere or wait for the lock to expire.');
  end if;
  insert into public.work_area_lock (area, holder, expires_at)
  values (p_area, p_holder, now() + make_interval(mins => p_ttl_minutes))
  on conflict (area) do update
    set holder = excluded.holder, claimed_at = now(), expires_at = excluded.expires_at;
  return jsonb_build_object('granted', true, 'area', p_area, 'holder', p_holder,
                            'expires', now() + make_interval(mins => p_ttl_minutes));
end $$;

create or replace function public.work_lock_release(p_area text, p_holder text)
returns boolean
language sql
security definer
set search_path to 'public','pg_temp'
as $$
  with d as (delete from public.work_area_lock where area = p_area and holder = p_holder returning 1)
  select exists (select 1 from d)
$$;

-- 2. MIGRATION NUMBERS ARE ALLOCATED, NOT CHOSEN ----------------------------
create table if not exists public.migration_allocation (
  migration_no  text primary key,
  area          text        not null,
  holder        text        not null,
  allocated_at  timestamptz not null default now(),
  used_as_name  text
);

alter table public.migration_allocation enable row level security;
drop policy if exists migration_allocation_read on public.migration_allocation;
create policy migration_allocation_read on public.migration_allocation for select
  to service_role, sysaudit_reader using (true);
grant select on public.migration_allocation to service_role, sysaudit_reader;

-- Takes the area lock AND the number in one call. If the area is held by someone else, you get
-- no number - which is the point. next_migration_no() is left untouched so nothing in flight breaks.
create or replace function public.claim_migration_no(p_area text, p_holder text, p_ttl_minutes int default 90)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare v_lock jsonb; v_no text;
begin
  v_lock := public.work_lock_claim(p_area, p_holder, p_ttl_minutes);
  if not (v_lock->>'granted')::boolean then
    return v_lock || jsonb_build_object('migration_no', null);
  end if;
  v_no := public.next_migration_no();
  insert into public.migration_allocation (migration_no, area, holder)
  values (v_no, p_area, p_holder)
  on conflict (migration_no) do nothing;
  return v_lock || jsonb_build_object('migration_no', v_no);
end $$;

revoke all on function public.work_lock_claim(text,text,int)    from public, anon, authenticated;
revoke all on function public.work_lock_release(text,text)      from public, anon, authenticated;
revoke all on function public.claim_migration_no(text,text,int) from public, anon, authenticated;
grant execute on function public.work_lock_claim(text,text,int)    to service_role;
grant execute on function public.work_lock_release(text,text)      to service_role;
grant execute on function public.claim_migration_no(text,text,int) to service_role;

-- 3. THE PROTOCOL, WHERE EVERY SESSION READS IT -----------------------------
insert into public.brain_knowledge (scope, key, content)
values ('universal', 'parallel_session_lockstep_law',
 'LOCKSTEP LAW (owner ruling, Mike, 2026-09-11: "How do we have instances in lockstep, no overwriting one another"). '
 'More than one session writes this database: the interactive session and the hourly scheduled pager, both running as instanceA. '
 'BEFORE WRITING: call claim_migration_no(area, holder) - it takes the area lock and allocates the migration number together. '
 'If granted is false, DO NOT WRITE IN THAT AREA. Work elsewhere or wait; the response names the holder and the expiry. '
 'NEVER hand-pick a migration number by reading the last one - that is exactly how 80 numbers collided across 93 files since 0089. '
 'Areas are coarse on purpose: auditor, mesh, tx, fl, az, federal, serper, spend, outbound, profiles, desk, platform. '
 'Locks expire (default 90 minutes) so a dead session cannot block the platform. Release with work_lock_release(area, holder) when done. '
 'Checks migration_number_collision and migration_allocation_recorded catch a breach within one audit cycle.')
on conflict do nothing;

-- 4. CHECKS -----------------------------------------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'migration_number_collision', 'mechanical', 'XVI.1', 'all', 'RED',
 'No two migrations may share a number. Two migrations with one number are two different changes wearing one name: rollback, history and "what changed when" all silently pick one and ignore the other. 80 numbers collided across 93 files before 2026-09-11; those are grandfathered as history that cannot be rewritten. Any NEW collision fails.',
 'select substring(name from ''^[0-9]{4}'') as num, count(*) as files, string_agg(name, '' | '') as names from supabase_migrations.schema_migrations where name ~ ''^[0-9]{4}'' and to_timestamp(version, ''YYYYMMDDHH24MISS'') > timestamptz ''2026-09-11 19:00:00+00'' group by 1 having count(*) > 1',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''9999''::text as num, 2::bigint as files, ''a | b''::text as names'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'migration_allocation_recorded', 'mechanical', 'XVI.2', 'all', 'AMBER',
 'Every migration applied after the lockstep law took effect should have been allocated through claim_migration_no, which takes the area lock at the same time. A migration with no allocation record means a session hand-picked its number and wrote without holding the area - the exact behaviour that produced 93 duplicate files. AMBER while sessions adopt the call; promote to RED once both writers are on it.',
 'select name, version from supabase_migrations.schema_migrations where to_timestamp(version, ''YYYYMMDDHH24MISS'') > timestamptz ''2026-09-11 19:00:00+00'' and not exists (select 1 from migration_allocation a where a.migration_no = substring(supabase_migrations.schema_migrations.name from ''^[0-9]{4}''))',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''9999_zz''::text as name, ''20990101000000''::text as version'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope, severity=excluded.severity,
      description=excluded.description, check_sql=excluded.check_sql,
      expectation=excluded.expectation, selftest_sql=excluded.selftest_sql;

insert into public.sysaudit_semantic_map (object_name, object_kind, role_in_platform, note, assigned_by)
values ('work_area_lock', 'table', 'registry',
        'Which area of the platform each session currently holds. Claimed together with a migration number by claim_migration_no. Expires so a dead session cannot block.', 'peo_gatekeeper'),
       ('migration_allocation', 'table', 'audit',
        'Every migration number allocated through the lockstep door, with the area and holder that took it.', 'peo_gatekeeper')
on conflict (object_name) do update
  set role_in_platform = excluded.role_in_platform, note = excluded.note;

reset role;

-- Record this migration's own number so the law applies to itself from the first row.
insert into public.migration_allocation (migration_no, area, holder, used_as_name)
values ('0823', 'platform', 'instanceA-interactive', '0823_parallel_session_lockstep_protocol')
on conflict (migration_no) do nothing;

-- VERIFICATION
-- select claim_migration_no('mesh','instanceA-interactive');            -- granted + a number
-- select claim_migration_no('mesh','some-other-session');               -- refused, names the holder
-- select * from work_area_lock;
-- select substring(name from '^[0-9]{4}') n, count(*) from supabase_migrations.schema_migrations
--   where to_timestamp(version,'YYYYMMDDHH24MISS') > '2026-09-11 19:00:00+00' group by 1 having count(*)>1;  -- empty