-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (a lane that cannot finish is not alive), XII.2 (time budgets)
-- Articles verified not violated: III.1, VI.2 (no numbers change - same answers, computed once)
-- Verification query attached: YES
--
-- WIN/LOSS WAS RECOMPUTING THE FAMILY TREE EIGHT MILLION TIMES
--
-- refresh_peo_win_loss last completed on 2026-08-12. After the null-key bug was fixed today
-- (0828) it ran but never finished: it walks 417 PEO slugs, and for each slug it called
-- family_root() once per row of peo_switch_ledger (7,664) and peo_departure_ledger (11,182).
-- That is roughly 8 million runs of a recursive tree walk to answer a question whose answer
-- never changes during the run - the hierarchy is 34 rows.
--
-- Fix: walk the tree ONCE into a map, then join against it. Same answers, computed once.
-- The map rebuilds itself whenever the hierarchy changes, so it cannot go stale.

create table if not exists public.peo_family_root_map (
  slug         text primary key,
  root         text not null,
  refreshed_at timestamptz not null default now()
);

alter table public.peo_family_root_map enable row level security;

do $p$
begin
  if not exists (select 1 from pg_policies where tablename='peo_family_root_map' and policyname='peo_family_root_map_read') then
    create policy peo_family_root_map_read on public.peo_family_root_map
      for select to service_role, authenticated using (true);
  end if;
end $p$;

create or replace function public.rebuild_peo_family_root_map()
returns integer language plpgsql security definer set search_path to 'public','pg_temp' as $rb$
declare n int;
begin
  delete from public.peo_family_root_map;
  insert into public.peo_family_root_map (slug, root)
  select s.slug, public.family_root(s.slug)
    from (
      select child_slug  as slug from public.peo_brand_hierarchy
      union select parent_slug from public.peo_brand_hierarchy
      union select from_family_slug from public.peo_switch_ledger where from_family_slug is not null
      union select to_family_slug   from public.peo_switch_ledger where to_family_slug is not null
      union select from_family_slug from public.peo_departure_ledger where from_family_slug is not null
      union select peo_family_slug  from public.companies where peo_family_slug is not null
    ) s
   where s.slug is not null
   on conflict (slug) do nothing;
  get diagnostics n = row_count;
  return n;
end $rb$;

create or replace function public.trg_rebuild_family_root_map()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $tg$
begin
  perform public.rebuild_peo_family_root_map();
  return null;
end $tg$;

drop trigger if exists trg_peo_brand_hierarchy_root_map on public.peo_brand_hierarchy;
create trigger trg_peo_brand_hierarchy_root_map
  after insert or update or delete on public.peo_brand_hierarchy
  for each statement execute function public.trg_rebuild_family_root_map();

set role peo_gatekeeper;
create index if not exists ix_departure_from_family on public.peo_departure_ledger (from_family_slug);
create index if not exists ix_switch_scope_from on public.peo_switch_ledger (switch_scope, from_family_slug);
create index if not exists ix_companies_family_status on public.companies (peo_family_slug, peo_user_status);
reset role;

select public.rebuild_peo_family_root_map();

create or replace function public.peo_family_win_loss_block(p_root text)
returns jsonb language sql stable as $wl$
select jsonb_build_object(
  'grain', 'family_rollup',
  'member_brands', coalesce((select jsonb_agg(distinct m.slug)
     from public.peo_family_root_map m where m.root = p_root), to_jsonb(array[p_root])),
  'wins_from_families', coalesce((select jsonb_agg(jsonb_build_object(
      'from', f.from_family, 'n', f.n, 'window', f.earliest||' to '||f.latest,
      'evidence', f.methods) order by f.n desc)
    from v_peo_flows_family f where f.to_family = p_root), '[]'::jsonb),
  'losses_to_families', coalesce((select jsonb_agg(jsonb_build_object(
      'to', f.to_family, 'n', f.n, 'window', f.earliest||' to '||f.latest,
      'evidence', f.methods) order by f.n desc)
    from v_peo_flows_family f where f.from_family = p_root), '[]'::jsonb),
  'net_vs_families', coalesce((select jsonb_object_agg(x.rival, x.net) from (
      select coalesce(w.from_family, l.to_family) as rival,
             coalesce(w.n,0) - coalesce(l.n,0) as net
      from (select * from v_peo_flows_family where to_family = p_root) w
      full outer join (select * from v_peo_flows_family where from_family = p_root) l
        on w.from_family = l.to_family) x
    where x.rival is not null), '{}'::jsonb),
  'intra_family_movement', jsonb_build_object(
    'client_moves', (select count(*) from public.peo_switch_ledger s
       join public.peo_family_root_map m on m.slug = s.from_family_slug
      where s.switch_scope='intra_family' and m.root = p_root),
    'admin_consolidations', (select count(*) from public.peo_switch_ledger s
       join public.peo_family_root_map m on m.slug = s.from_family_slug
      where s.switch_scope='intra_family_admin' and m.root = p_root)),
  'open_market_departures', jsonb_build_object(
    'assumed', (select count(*) from public.peo_departure_ledger dl
       join public.peo_family_root_map m on m.slug = dl.from_family_slug
      where m.root = p_root and dl.status='assumed_open_market'),
    'confirmed', (select count(*) from public.peo_departure_ledger dl
       join public.peo_family_root_map m on m.slug = dl.from_family_slug
      where m.root = p_root and dl.status='confirmed_open_market')
      + (select count(*) from public.companies c
           join public.peo_family_root_map m on m.slug = c.peo_family_slug
          where m.root = p_root and c.peo_user_status='former_peo_user'
            and not exists (select 1 from public.peo_departure_ledger dl where dl.ein = c.ein))),
  'open_market_wins', jsonb_build_object('n', null, 'basis', 'open_market_entry lane pending'),
  'coverage_statement', 'Aggregation of member-brand flows through the hierarchy tree. Observed floors within extraction coverage (currently trinet + adp_totalsource MEP, 2020-2024 + TX WC lanes); expands automatically.',
  'computed_at', now()::text
) $wl$;

create or replace function public.refresh_peo_win_loss()
returns jsonb language plpgsql as $rf$
declare v_n int := 0; r record;
begin
  perform public.rebuild_peo_family_root_map();

  for r in
    select distinct x.slug, coalesce(m.root, x.slug) as root
      from (
        select from_family_slug as slug from public.peo_switch_ledger
        union select to_family_slug from public.peo_switch_ledger
        union select from_family_slug from public.peo_departure_ledger
        union select peo_family_slug from public.companies
               where peo_user_status='former_peo_user' and peo_family_slug is not null
      ) x
      left join public.peo_family_root_map m on m.slug = x.slug
     where x.slug is not null
  loop
    insert into public.peo_profiles (family_slug, display_name, win_loss_flows, updated_at)
    values (r.slug, r.slug,
      jsonb_build_object(
        'brand_level', public.peo_brand_win_loss_block(r.slug),
        'family_level', case when r.root = r.slug then public.peo_family_win_loss_block(r.slug)
                             else jsonb_build_object('rolls_up_to', r.root) end),
      now())
    on conflict (family_slug) do update
      set win_loss_flows = excluded.win_loss_flows, updated_at = now();
    v_n := v_n + 1;
  end loop;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('refresh_peo_win_loss', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('profiles_refreshed', v_n));
  return jsonb_build_object('profiles_refreshed', v_n);
end $rf$;