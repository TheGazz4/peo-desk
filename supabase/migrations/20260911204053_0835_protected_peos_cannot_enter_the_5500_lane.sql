-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0835-noncompete-hard-door
-- Articles implemented: III.1 (fence at the door, not after), IX.2 (every block receipted), XI.1 (one door)
-- Articles verified not violated: II.2, VI.2, XIV.6
-- Verification query attached: YES
--
-- WHY THIS EXISTS
-- The noncompete fence guarded the wrong thing. It stopped us NAMING a protected PEO - it never
-- stopped us INGESTING a protected PEO'S CLIENT LIST. A Helpside client has an ordinary company
-- name and no Helpside attribution, so every guard on companies/signals/contacts waved it through.
-- 875 rows of Helpside, Lever1 and High Road client rosters landed in the Form 5500 lane, and the
-- next 5500 pull would have brought them straight back.
--
-- THREE LOCKS, so a rename cannot get past them:
--   1. NAME  - widened patterns, tested on the PEO slug, the plan name AND the sponsor name.
--   2. EIN   - a protected sponsor EIN is remembered forever. Names change; EINs do not.
--   3. DOOR  - a BEFORE INSERT trigger on EVERY table in the 5500 lane. A protected row is dropped
--              at the door and receipted. It is not filtered later, it never lands.

-- ---------------------------------------------------------------- 1. widen the name patterns
insert into public.noncompete_peo_patterns (pattern, label, basis) values
 ('help[ _.-]*side', 'Helpside (spacing-tolerant)',
  'Gazz non-compete directive 2026-08-08; widened 2026-09-11 because "HELP SIDE INC" slipped the original pattern'),
 ('high[ _.-]*road[ _.-]*(peo|mep|hr|benefit|employ|workforce|staffing)', 'High Road PEO (wider suffix set)',
  'Gazz directive 2026-09-07; widened 2026-09-11 - the original required the literal token PEO or MEP'),
 ('peo[ _.-]*spectrum', 'PEO Spectrum',
  'Standing denylist - recorded as a pattern 2026-09-11 so it is enforced, not just remembered')
on conflict do nothing;

-- ---------------------------------------------------------------- 2. protected sponsor EINs
create table if not exists public.noncompete_protected_eins (
  ein        text primary key,
  label      text not null,
  basis      text not null,
  added_at   timestamptz not null default now()
);

alter table public.noncompete_protected_eins enable row level security;

do $p$
begin
  if not exists (select 1 from pg_policies where tablename='noncompete_protected_eins' and policyname='noncompete_protected_eins_read') then
    create policy noncompete_protected_eins_read on public.noncompete_protected_eins
      for select to service_role, authenticated using (true);
  end if;
end $p$;

insert into public.noncompete_protected_eins (ein, label, basis) values
 ('870476353','Helpside Inc',
  'Plan sponsor EIN on HELPSIDE INC. 401(K) PLAN and HELPSIDE INC. CAFETERIA PLAN, form years 2020-2024. Blocked by EIN so a plan rename cannot re-open the door.'),
 ('863802120','High Road PEO LLC',
  'Plan sponsor EIN on HIGH ROAD MEP 401(K) PLAN, form years 2021-2024.'),
 ('454152888','Lever1',
  'Plan sponsor EIN on LEVER1 RETIREMENT SAVINGS PLAN and LEVER1 WELFARE BENEFITS PLAN, form years 2020-2024.')
on conflict (ein) do nothing;
-- NOTE: EIN 20-3886993 is deliberately NOT listed. It belongs to National Benefit Services, the
-- third-party administrator that filed the Helpside plan in 2023-2024. It also files a dozen
-- legitimate unrelated plans, so blocking it wholesale would delete honest data. The Helpside
-- rows under it are caught by the NAME lock instead.

-- ---------------------------------------------------------------- 3. the single test
create or replace function public.noncompete_blocks(
  p_slug text default null, p_plan_name text default null,
  p_sponsor_name text default null, p_sponsor_ein text default null,
  p_employer_name text default null)
returns boolean language sql stable as $nb$
  select coalesce(public.is_noncompete_peo(p_slug), false)
      or coalesce(public.is_noncompete_peo(p_plan_name), false)
      or coalesce(public.is_noncompete_peo(p_sponsor_name), false)
      or coalesce(public.is_noncompete_peo(p_employer_name), false)
      or exists (select 1 from public.noncompete_protected_eins e
                  where e.ein = regexp_replace(coalesce(p_sponsor_ein,''), '[^0-9]', '', 'g')
                    and e.ein <> '');
$nb$;

-- ---------------------------------------------------------------- 4. the door
create table if not exists public.noncompete_door_log (
  id          bigserial primary key,
  table_name  text not null,
  reason      text not null,
  sample      jsonb,
  blocked_at  timestamptz not null default now(),
  occurrences integer not null default 1
);

alter table public.noncompete_door_log enable row level security;

do $p$
begin
  if not exists (select 1 from pg_policies where tablename='noncompete_door_log' and policyname='noncompete_door_log_read') then
    create policy noncompete_door_log_read on public.noncompete_door_log
      for select to service_role, authenticated using (true);
  end if;
end $p$;

-- One trigger function for every 5500 table. It reads whichever of the columns exist on the row
-- it is given, so the same guard works on staging, participants and filings without per-table code.
create or replace function public.trg_noncompete_5500_door()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $td$
declare
  j jsonb := to_jsonb(new);
  v_slug text    := j->>'peo_slug';
  v_plan text    := j->>'plan_name';
  v_spons text   := coalesce(j->>'sponsor_name', j->>'best_name');
  v_sein text    := coalesce(j->>'sponsor_ein', j->>'ein');
  v_emp text     := coalesce(j->>'employer_name_raw', j->>'employer_name_clean', j->>'employer_name');
begin
  if public.noncompete_blocks(v_slug, v_plan, v_spons, v_sein, v_emp) then
    insert into public.noncompete_door_log (table_name, reason, sample)
    values (tg_table_name,
            'protected PEO blocked at the 5500 door',
            jsonb_build_object('plan_name', v_plan, 'sponsor_name', v_spons,
                               'sponsor_ein', v_sein, 'peo_slug', v_slug));
    return null;               -- the row never lands
  end if;
  return new;
exception when others then
  -- a broken guard must fail CLOSED on this lane: if we cannot prove the row is safe, drop it
  insert into public.noncompete_door_log (table_name, reason, sample)
  values (tg_table_name, 'guard error - row dropped to fail closed: '||left(sqlerrm,200), j);
  return null;
end $td$;

do $mk$
declare t text;
begin
  foreach t in array array['form5500_mep_participants','efast_5500_staging',
                           'efast_mep_part_staging','f5500_peo_filings_staging',
                           'efast_mep_sponsor_census']
  loop
    execute format('drop trigger if exists trg_noncompete_5500_door on public.%I', t);
    execute format('create trigger trg_noncompete_5500_door before insert or update on public.%I
                    for each row execute function public.trg_noncompete_5500_door()', t);
  end loop;
end $mk$;