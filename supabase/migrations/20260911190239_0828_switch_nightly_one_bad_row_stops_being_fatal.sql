-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (lane liveness), IV.2 (no silent swallow), VI.1 (visible backlog)
-- Articles verified not violated: II.3/XIV.1 (canonical families - nothing is force-registered),
--   II.2 (no merge on a non-distinctive name), III.1 (fences)
-- Verification query attached: YES
--
-- THE SWITCH DETECTION NIGHTLY HAS BEEN 50% DEAD SINCE 09-07.
-- Three of its six steps fail every night. Each failure is ONE bad row killing the
-- whole step, so thousands of good rows never get processed:
--
--   * mep_full  - stops on the first Form 5500 sponsor whose name is not yet a
--                 registered PEO family (e.g. "extensisgroupllc", which IS in the
--                 alias table mapping to extensishr, but the raw slug is passed
--                 through un-canonicalised). 156 of 264 sponsor slugs in
--                 mep_peo_book are not registered families - so the step dies on
--                 row one, every night.
--   * intra     - stops on the first EIN that has no company row yet
--                 (fk_signals_company_ein).
--   * win_loss  - "field name must not be null": net_vs_families builds an object
--                 with jsonb_object_agg over a FULL OUTER JOIN, and when both sides
--                 are null the key is null.
--
-- FIX: a row the door refuses is a SKIP with a recorded reason, not a lane death.
-- Nothing is force-registered and nothing is merged - the refused rows become a
-- counted, readable backlog instead of an invisible crash.

create table if not exists public.switch_detection_skips (
  id            bigserial primary key,
  step          text not null,
  ein           text,
  peo_slug      text,
  reason        text not null,
  first_seen    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),
  occurrences   integer not null default 1,
  unique (step, ein, peo_slug, reason)
);

create or replace function public.switch_skip_log(p_step text, p_ein text, p_slug text, p_reason text)
returns void language sql as $sk$
  insert into public.switch_detection_skips (step, ein, peo_slug, reason)
  values (p_step, p_ein, p_slug, left(p_reason, 300))
  on conflict (step, ein, peo_slug, reason)
  do update set last_seen = now(), occurrences = public.switch_detection_skips.occurrences + 1;
$sk$;

-- ---------------------------------------------------------------- mep_full
create or replace function public.run_switch_detection_mep_full(p_limit integer default 1000)
returns jsonb language plpgsql as $mf$
declare v_switched int := 0; v_ambiguous int := 0; v_skipped int := 0; r record; res jsonb;
begin
  for r in
    with fam_years as (
      select ein, peo_slug, min(filing_year) as min_yr, max(filing_year) as max_yr
      from mep_peo_book where ein is not null
      group by 1,2
    ),
    multi as (select ein from fam_years group by ein having count(*) = 2),
    pairs as (
      select a.ein, a.peo_slug as fam_a, a.min_yr as a_min, a.max_yr as a_max,
             b.peo_slug as fam_b, b.min_yr as b_min, b.max_yr as b_max
      from fam_years a join fam_years b on b.ein = a.ein and b.peo_slug > a.peo_slug
      join multi m on m.ein = a.ein
    )
    select p.ein,
      case when p.a_max > p.b_max then p.fam_b when p.b_max > p.a_max then p.fam_a end as from_family,
      case when p.a_max > p.b_max then p.fam_a when p.b_max > p.a_max then p.fam_b end as to_family,
      case when p.a_max > p.b_max then greatest(p.a_min, p.b_max + 1)
           when p.b_max > p.a_max then greatest(p.b_min, p.a_max + 1) end as switch_year,
      p.a_min, p.a_max, p.b_min, p.b_max, p.fam_a, p.fam_b
    from pairs p
    where not exists (select 1 from peo_switch_ledger l where l.ein = p.ein)
    limit p_limit
  loop
    if r.to_family is null then v_ambiguous := v_ambiguous + 1; continue; end if;
    if coalesce((select g.parent_group from peo_family_groups g where g.family_slug = r.from_family), r.from_family)
       = coalesce((select g.parent_group from peo_family_groups g where g.family_slug = r.to_family), r.to_family) then
      v_ambiguous := v_ambiguous + 1; continue;
    end if;

    begin
      res := record_peo_switch_by_ein(r.ein, r.from_family, r.to_family, make_date(r.switch_year,1,1),
        'form5500_mep:'||r.fam_a||' '||r.a_min||'-'||r.a_max||' / '||r.fam_b||' '||r.b_min||'-'||r.b_max,
        'mep_trajectory_full');
      if res ? 'switched' then v_switched := v_switched + 1; end if;
    exception when others then
      v_skipped := v_skipped + 1;
      perform public.switch_skip_log('mep_full', r.ein,
                coalesce(r.from_family,'')||'>'||coalesce(r.to_family,''), sqlerrm);
    end;
  end loop;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('run_switch_detection_mep_full', gen_random_uuid(), now(), now(), true,
    jsonb_build_object('switched', v_switched, 'ambiguous_skipped', v_ambiguous, 'refused_rows', v_skipped));
  return jsonb_build_object('switched', v_switched, 'ambiguous', v_ambiguous, 'refused', v_skipped);
end $mf$;

-- ---------------------------------------------------------------- intra
create or replace function public.run_switch_detection_intra(p_limit integer default 500)
returns jsonb language plpgsql as $it$
declare v_client int := 0; v_admin int := 0; v_ambiguous int := 0; v_skipped int := 0; r record; res jsonb;
begin
  create temp table _intra_moves on commit drop as
  with sponsor_years as (
    select ein, peo_slug, sponsor_ein, min(filing_year) as min_yr, max(filing_year) as max_yr
    from mep_peo_book
    where ein is not null and sponsor_ein is not null
    group by 1,2,3
  ),
  multi as (select ein, peo_slug from sponsor_years group by 1,2 having count(*) = 2),
  pairs as (
    select a.ein, a.peo_slug,
           a.sponsor_ein as sp_a, a.min_yr as a_min, a.max_yr as a_max,
           b.sponsor_ein as sp_b, b.min_yr as b_min, b.max_yr as b_max
    from sponsor_years a
    join sponsor_years b on b.ein = a.ein and b.peo_slug = a.peo_slug and b.sponsor_ein > a.sponsor_ein
    join multi m on m.ein = a.ein and m.peo_slug = a.peo_slug
  )
  select p.ein, p.peo_slug,
    case when p.a_max > p.b_max then p.sp_b when p.b_max > p.a_max then p.sp_a end as from_sponsor,
    case when p.a_max > p.b_max then p.sp_a when p.b_max > p.a_max then p.sp_b end as to_sponsor,
    case when p.a_max > p.b_max then greatest(p.a_min, p.b_max + 1)
         when p.b_max > p.a_max then greatest(p.b_min, p.a_max + 1) end as switch_year
  from pairs p
  limit p_limit;

  create temp table _mass on commit drop as
  select peo_slug, from_sponsor, to_sponsor, switch_year, count(*) as n
  from _intra_moves where from_sponsor is not null
  group by 1,2,3,4 having count(*) >= 25;

  for r in select m.* from _intra_moves m where m.from_sponsor is not null loop
    begin
      res := record_peo_switch_by_ein(r.ein, r.peo_slug, r.peo_slug, make_date(r.switch_year,1,1),
        'form5500_mep:sponsor '||r.from_sponsor||'>'||r.to_sponsor,
        case when exists (select 1 from _mass ms where ms.peo_slug=r.peo_slug and ms.from_sponsor=r.from_sponsor
                          and ms.to_sponsor=r.to_sponsor and ms.switch_year=r.switch_year)
             then 'plan_consolidation' else 'intra_family_sponsor_move' end,
        r.from_sponsor, r.to_sponsor,
        case when exists (select 1 from _mass ms where ms.peo_slug=r.peo_slug and ms.from_sponsor=r.from_sponsor
                          and ms.to_sponsor=r.to_sponsor and ms.switch_year=r.switch_year)
             then 'intra_family_admin' else 'intra_family' end);
      if res ? 'switched' then
        if res->>'scope' = 'intra_family_admin' then v_admin := v_admin + 1; else v_client := v_client + 1; end if;
      end if;
    exception when others then
      v_skipped := v_skipped + 1;
      perform public.switch_skip_log('intra', r.ein, r.peo_slug, sqlerrm);
    end;
  end loop;

  select count(*) into v_ambiguous from _intra_moves where from_sponsor is null;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('run_switch_detection_intra', gen_random_uuid(), now(), now(), true,
    jsonb_build_object('client_moves', v_client, 'admin_consolidations', v_admin,
                       'ambiguous', v_ambiguous, 'refused_rows', v_skipped));
  return jsonb_build_object('client_moves', v_client, 'admin', v_admin,
                            'ambiguous', v_ambiguous, 'refused', v_skipped);
end $it$;

-- ---------------------------------------------------------------- win_loss null key
create or replace function public.peo_family_win_loss_block(p_root text)
returns jsonb language sql stable as $wl$
select jsonb_build_object(
  'grain', 'family_rollup',
  'member_brands', coalesce((select jsonb_agg(distinct b) from (
      select p_root as b
      union select child_slug from peo_brand_hierarchy where family_root(child_slug) = p_root
    ) x), '[]'::jsonb),
  'wins_from_families', coalesce((select jsonb_agg(jsonb_build_object(
      'from', f.from_family, 'n', f.n, 'window', f.earliest||' to '||f.latest,
      'evidence', f.methods) order by f.n desc)
    from v_peo_flows_family f where f.to_family = p_root), '[]'::jsonb),
  'losses_to_families', coalesce((select jsonb_agg(jsonb_build_object(
      'to', f.to_family, 'n', f.n, 'window', f.earliest||' to '||f.latest,
      'evidence', f.methods) order by f.n desc)
    from v_peo_flows_family f where f.from_family = p_root), '[]'::jsonb),
  -- a FULL OUTER JOIN can yield a row with no family on either side; a null key
  -- makes jsonb_object_agg raise "field name must not be null" and killed the step.
  'net_vs_families', coalesce((select jsonb_object_agg(rival, net) from (
      select coalesce(w.from_family, l.to_family) as rival,
             coalesce(w.n,0) - coalesce(l.n,0) as net
      from (select * from v_peo_flows_family where to_family = p_root) w
      full outer join (select * from v_peo_flows_family where from_family = p_root) l
        on w.from_family = l.to_family) x
    where x.rival is not null), '{}'::jsonb),
  'intra_family_movement', jsonb_build_object(
    'client_moves', (select count(*) from peo_switch_ledger where switch_scope='intra_family'
      and family_root(from_family_slug) = p_root),
    'admin_consolidations', (select count(*) from peo_switch_ledger where switch_scope='intra_family_admin'
      and family_root(from_family_slug) = p_root)),
  'open_market_departures', jsonb_build_object(
    'assumed', (select count(*) from peo_departure_ledger dl where family_root(dl.from_family_slug) = p_root and dl.status='assumed_open_market'),
    'confirmed', (select count(*) from peo_departure_ledger dl where family_root(dl.from_family_slug) = p_root and dl.status='confirmed_open_market')
      + (select count(*) from companies c where family_root(c.peo_family_slug) = p_root and c.peo_user_status='former_peo_user'
          and not exists (select 1 from peo_departure_ledger dl where dl.ein = c.ein))),
  'open_market_wins', jsonb_build_object('n', null, 'basis', 'open_market_entry lane pending'),
  'coverage_statement', 'Aggregation of member-brand flows through the hierarchy tree. Observed floors within extraction coverage (currently trinet + adp_totalsource MEP, 2020-2024 + TX WC lanes); expands automatically.',
  'computed_at', now()::text
) $wl$;