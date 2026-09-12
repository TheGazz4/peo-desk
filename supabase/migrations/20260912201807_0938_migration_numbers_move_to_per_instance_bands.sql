-- =====================================================================
-- CONSTITUTIONAL COMPLIANCE
-- Migration : 0938_migration_numbers_move_to_per_instance_bands
-- Area      : mesh_law            Holder: instanceA
-- Claim     : instanceA-0938-migration-number-bands
-- Article   : XI.1 (mechanical)
-- Why       : One shared counter guarded by a rule that every instance must
--             remember to follow is the wrong shape. It failed 51 times.
--             Only two holders ever called the allocator at all (instanceA,
--             pager); the other two instances simply pick numbers.
--             Fix at the core: delete the shared resource. Each instance gets
--             its own number band and its own sequence. Two instances can no
--             longer reach the same number even if neither ever coordinates.
-- Kept      : 0917's principle, now scoped per band - a band's sequence lifts
--             itself past the highest number already used INSIDE that band
--             before issuing, so a used number stays unreachable.
-- Also      : migration_allocation was PRIMARY KEY (migration_no) - one row
--             per number - so it could never record two instances using one
--             number. Re-keyed to (migration_no, holder).
-- Safety    : allocator + registry only. No company data. No display surface.
-- =====================================================================

-- ---------- 1. the bands ---------------------------------------------
create table if not exists public.migration_band (
  band_key       text    primary key,
  label          text    not null,
  band_lo        integer not null,
  band_hi        integer not null,
  seq_name       text    not null,
  holder_pattern text    not null,
  match_order    integer not null,
  constraint migration_band_range_ok check (band_hi > band_lo),
  constraint migration_band_four_digit check (band_lo >= 1000 and band_hi <= 9999)
);

comment on table public.migration_band is
  '0938: one number band per writing instance. Bands make migration-number collisions structurally impossible without any cross-instance coordination.';

insert into public.migration_band
  (band_key, label, band_lo, band_hi, seq_name, holder_pattern, match_order)
values
  ('a', 'Instance A - mesh law, non-PEO gate, book perspective', 1000, 1999,
        'migration_no_band_a', '^instanceA', 10),
  ('b', 'mesh_* instance - scorecard, pull, harvest, apply',     2000, 2999,
        'migration_no_band_b', '^(mesh|instanceB)', 20),
  ('c', 'twin-merge / dedup / EIN-harvest instance',             3000, 3999,
        'migration_no_band_c', '^(twin|dedup|ein|instanceC)', 30),
  ('d', 'pager - sysaudit repair lane',                          4000, 4999,
        'migration_no_band_d', '^pager', 40),
  ('z', 'UNCLAIMED - holder matches no declared band',           9000, 9999,
        'migration_no_band_z', '.', 999)
on conflict (band_key) do nothing;

create sequence if not exists public.migration_no_band_a start with 1000 minvalue 1000;
create sequence if not exists public.migration_no_band_b start with 2000 minvalue 2000;
create sequence if not exists public.migration_no_band_c start with 3000 minvalue 3000;
create sequence if not exists public.migration_no_band_d start with 4000 minvalue 4000;
create sequence if not exists public.migration_no_band_z start with 9000 minvalue 9000;

-- ---------- 2. which band is a holder in ------------------------------
create or replace function public.migration_band_of(p_holder text)
returns public.migration_band
language sql
stable
set search_path to 'public','pg_catalog'
as $fn$
  select b.* from public.migration_band b
   where coalesce(p_holder,'') ~ b.holder_pattern
   order by b.match_order
   limit 1;
$fn$;

-- ---------- 3. the allocator, now band-aware --------------------------
create or replace function public.next_migration_no(p_holder text)
returns text
language plpgsql
security definer
set search_path to 'public','pg_catalog'
as $fn$
declare b public.migration_band; v_ceiling integer; v_next bigint;
begin
  b := public.migration_band_of(p_holder);
  if b.band_key is null then
    raise exception 'no migration band resolves for holder %', p_holder;
  end if;

  -- 0917 principle, scoped to this band: the repo is the authority on what
  -- has already been used inside the band.
  select coalesce(max((substring(m.name from '^(\d{4})'))::int), 0)
    into v_ceiling
    from supabase_migrations.schema_migrations m
   where m.name ~ '^\d{4}'
     and (substring(m.name from '^(\d{4})'))::int between b.band_lo and b.band_hi;

  if coalesce(pg_sequence_last_value(b.seq_name::regclass), b.band_lo - 1) < greatest(v_ceiling, b.band_lo - 1) then
    perform setval(b.seq_name::regclass, greatest(v_ceiling, b.band_lo - 1), true);
  end if;

  v_next := nextval(b.seq_name::regclass);

  if v_next > b.band_hi then
    raise exception 'migration band % (%-%) is exhausted', b.band_key, b.band_lo, b.band_hi;
  end if;

  return lpad(v_next::text, 4, '0');
end $fn$;

-- legacy zero-arg form: no holder means no band, so it lands in the
-- UNCLAIMED band rather than silently borrowing someone else's numbers.
create or replace function public.next_migration_no()
returns text
language sql
security definer
set search_path to 'public','pg_catalog'
as $fn$ select public.next_migration_no(null::text) $fn$;

-- ---------- 4. the ledger can finally record a collision ---------------
alter table public.migration_allocation drop constraint if exists migration_allocation_pkey;
alter table public.migration_allocation add constraint migration_allocation_pkey
  primary key (migration_no, holder);

create or replace function public.claim_migration_no(p_area text, p_holder text, p_ttl_minutes integer default 90)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_lock jsonb; v_no text; v_band public.migration_band;
begin
  v_lock := public.work_lock_claim(p_area, p_holder, p_ttl_minutes);
  if not (v_lock->>'granted')::boolean then
    return v_lock || jsonb_build_object('migration_no', null);
  end if;

  v_band := public.migration_band_of(p_holder);
  v_no   := public.next_migration_no(p_holder);

  insert into public.migration_allocation (migration_no, area, holder)
  values (v_no, p_area, p_holder)
  on conflict (migration_no, holder) do nothing;

  return v_lock || jsonb_build_object(
    'migration_no', v_no,
    'band',         v_band.band_key,
    'band_label',   v_band.label);
end $fn$;

-- ---------- 5. grants --------------------------------------------------
grant select on public.migration_band to sysaudit_reader, peo_gatekeeper, service_role;

-- ---------- 6. the conformance check ----------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, article, module, scope, severity, description,
   check_sql, expectation, enabled, created_by, selftest_sql)
values (
  'migration_number_outside_any_band',
  'XI.1',
  'mechanical',
  'fast',
  'AMBER',
  'Every migration applied after the band cutover carries a number inside a declared band. A number outside every band means an instance is still drawing from the old shared range and can collide with another. Names the offending files.',
$sql$select m.name,
       substring(m.name from '^(\d{4})') as num
  from supabase_migrations.schema_migrations m
 where m.name ~ '^\d{4}'
   and to_timestamp(m.version, 'YYYYMMDDHH24MISS') > timestamptz '2026-09-12 20:00:00+00'
   and not exists (
         select 1 from public.migration_band b
          where (substring(m.name from '^(\d{4})'))::int between b.band_lo and b.band_hi)
 order by m.version
 limit 200$sql$,
  '{"mode":"zero_rows"}'::jsonb,
  true,
  'instanceA-0938',
  $st$select 'SYNTHETIC_out_of_band'::text as name, '0000'::text as num$st$
)
on conflict (check_name) do update set
  check_sql    = excluded.check_sql,
  selftest_sql = excluded.selftest_sql,
  description  = excluded.description,
  severity     = excluded.severity,
  scope        = excluded.scope,
  enabled      = true;

reset role;
;