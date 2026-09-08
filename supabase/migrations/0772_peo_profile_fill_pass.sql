-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-peo-profile-spine
-- Articles implemented: VI.2 (job receipts), ENTRY PIPELINE (provenance on every field),
--   publish-shelf doctrine, auditor coverage
-- Articles verified not violated: noncompete families keep no profile and get no wants
-- Verification query attached: YES

-- ============================================================================
-- 0772  PEO profile fill pass + the standing loop
--   0. want_scope fix: the want board takes 'record' | 'class' (0770 used the
--      subject name by mistake); the subject_class column already carries
--      'peo_family', which is what the mesh reads.
--   1. Archive and remove the orphan profile rows left behind by past merges.
--   2. Create the missing profiles for families that have a client book.
--   3. Stamp provenance on every value already held.
--   4. Wire the shelf and the want loop into a nightly job.
--   5. Auditor: a family with current clients and no profile is a RED failure.
-- ============================================================================

create or replace function public.enqueue_peo_profile_wants(p_limit int default 2000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_n int;
begin
  with cand as (
    select f.family_slug, f.field_name, f.required_tier, f.freshness, f.current_clients,
           r.answer_hubs
    from v_peo_profile_freshness f
    join peo_profile_field_registry r on r.field_name = f.field_name
    where f.freshness in ('no_profile','never_sourced','stale')
      and f.current_clients > 0
    order by (f.required_tier = 'core') desc, f.current_clients desc
    limit p_limit
  ), ins as (
    insert into want_board
      (hub_slug, want_scope, want_kind, subject_class, subject_key, field_wanted,
       detail, priority, status, expires_at, dedupe_key)
    select 'mesh', 'record', 'field', 'peo_family', c.family_slug, c.field_name,
           jsonb_build_object('tier', c.required_tier, 'reason', c.freshness,
                              'answer_hubs', c.answer_hubs, 'clients', c.current_clients,
                              'law','0770 peo_profile_spine'),
           case when c.required_tier='core' then 90
                when c.required_tier='standard' then 60 else 30 end,
           'open', now() + interval '90 days',
           'peo_profile:'||c.family_slug||':'||c.field_name
    from cand c
    on conflict (dedupe_key) do nothing
    returning 1
  )
  select count(*) into v_n from ins;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('enqueue_peo_profile_wants', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('wants_opened', v_n, 'limit', p_limit));
  return jsonb_build_object('wants_opened', v_n);
end $fn$;

revoke all on function public.enqueue_peo_profile_wants(int) from public;
revoke all on function public.enqueue_peo_profile_wants(int) from map_reader;
grant execute on function public.enqueue_peo_profile_wants(int) to service_role;

create table if not exists public.peo_profile_archive (
  archived_at  timestamptz not null default now(),
  reason       text not null,
  family_slug  text not null,
  payload      jsonb not null
);
alter table public.peo_profile_archive enable row level security;

comment on table public.peo_profile_archive is
  '0772: profiles removed from peo_profiles are archived here whole, never simply deleted.';

insert into public.peo_profile_archive (reason, family_slug, payload)
select 'orphan_after_family_merge', p.family_slug, to_jsonb(p)
from public.peo_profiles p
where not exists (select 1 from public.peo_families f where f.family_slug = p.family_slug);

delete from public.peo_profiles p
where not exists (select 1 from public.peo_families f where f.family_slug = p.family_slug);

insert into public.peo_profiles (family_slug, display_name, customer_facing_name, profile_status, notes)
select f.family_slug,
       coalesce(max(f.family_display), f.family_slug),
       coalesce(max(f.family_display), f.family_slug),
       'stub',
       '0772 fill pass: profile created for a family that already carried a client book'
from public.peo_families f
where not exists (select 1 from public.peo_profiles p where p.family_slug = f.family_slug)
  and not public.is_noncompete_peo(f.family_slug)
  and exists (select 1 from public.companies c
              where c.merged_into is null and c.peo_family_slug = f.family_slug)
group by f.family_slug;

update public.peo_profiles p
set field_provenance = coalesce(p.field_provenance,'{}'::jsonb) || j.prov
from (
  select p2.family_slug,
         coalesce((
           select jsonb_object_agg(x.f, jsonb_build_object(
                    'as_of', x.as_of, 'source_hub', 'legacy_pre_0770',
                    'evidence_ref', 'backfilled by 0772', 'at', now()))
           from (
             select 'customer_facing_name' as f, coalesce(p2.updated_at::date, current_date) as as_of
             where nullif(btrim(p2.customer_facing_name),'') is not null
             union all
             select 'website', coalesce(p2.website_as_of, p2.updated_at::date, current_date)
             where nullif(btrim(p2.website),'') is not null
             union all
             select 'cpeo_status', coalesce(p2.updated_at::date, current_date)
             where p2.cpeo_status is not null
             union all
             select 'hq_city_state', coalesce(p2.updated_at::date, current_date)
             where p2.hq_address is not null
             union all
             select 'ownership_type', coalesce(p2.updated_at::date, current_date)
             where nullif(btrim(p2.ownership_type),'') is not null
             union all
             select 'total_wse_count', coalesce(p2.wse_as_of, p2.updated_at::date, current_date)
             where p2.total_wse_count is not null
             union all
             select 'client_count', coalesce(p2.client_count_as_of, p2.updated_at::date, current_date)
             where p2.client_count is not null
             union all
             select 'narrative', coalesce(p2.updated_at::date, current_date)
             where p2.narrative is not null
             union all
             select 'sponsor_eins', coalesce(p2.updated_at::date, current_date)
             where jsonb_array_length(coalesce(p2.sponsor_eins,'[]'::jsonb)) > 0
           ) x
         ), '{}'::jsonb) as prov
  from public.peo_profiles p2
) j
where j.family_slug = p.family_slug and j.prov <> '{}'::jsonb;

create or replace function public.peo_profile_nightly()
returns jsonb
language plpgsql
security definer
set search_path to 'public','pub','pg_temp'
as $fn$
declare v_wants jsonb; v_shelf bigint;
begin
  select public.enqueue_peo_profile_wants(2000) into v_wants;
  select pub.compile_peo_profiles() into v_shelf;
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('peo_profile_nightly', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('wants', v_wants, 'shelf_rows', v_shelf));
  return jsonb_build_object('wants', v_wants, 'shelf_rows', v_shelf);
end $fn$;

revoke all on function public.peo_profile_nightly() from public;
revoke all on function public.peo_profile_nightly() from map_reader;

select cron.schedule('peo_profile_nightly', '41 6 * * *',
                     $$select public.peo_profile_nightly();$$)
where not exists (select 1 from cron.job where jobname = 'peo_profile_nightly');

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
select 'peo_profile_law', 'doctrine', 'owner ruling 2026-09-08', 'all', 'RED',
  'PEO profiles are part of the heart of the product: every family with a live client book must have a profile row. FAIL = a family with current clients and no peo_profiles row (noncompete families excluded by law).',
  $q$select f.family_slug,
            (select count(*) from companies c
              where c.merged_into is null and c.peo_family_slug=f.family_slug and c.peo_current) as clients
     from (select distinct family_slug from peo_families) f
     where not is_noncompete_peo(f.family_slug)
       and exists (select 1 from companies c
                   where c.merged_into is null and c.peo_family_slug=f.family_slug and c.peo_current)
       and not exists (select 1 from peo_profiles p where p.family_slug=f.family_slug)
     limit 50$q$,
  '{"mode":"zero_rows"}'::jsonb,
  $q$select 1 where false$q$
where not exists (select 1 from public.sysaudit_registry where check_name='peo_profile_law');

reset role;

select public.enqueue_peo_profile_wants(2000);
select pub.compile_peo_profiles();

do $verify$
declare v_orphan int; v_missing int; v_noprov int; v_shelf bigint; v_cron int; v_wants int;
begin
  select count(*) into v_orphan from public.peo_profiles p
   where not exists (select 1 from public.peo_families f where f.family_slug=p.family_slug);
  if v_orphan > 0 then
    raise exception '0772 verification: % orphan profiles remain', v_orphan;
  end if;

  select count(*) into v_missing
  from (select distinct family_slug from public.peo_families) f
  where not public.is_noncompete_peo(f.family_slug)
    and exists (select 1 from public.companies c
                where c.merged_into is null and c.peo_family_slug=f.family_slug)
    and not exists (select 1 from public.peo_profiles p where p.family_slug=f.family_slug);
  if v_missing > 0 then
    raise exception '0772 verification: % families with a book still have no profile', v_missing;
  end if;

  if exists (select 1 from public.peo_profiles p where public.is_noncompete_peo(p.family_slug)) then
    raise exception '0772 verification: the fill pass created a profile for a noncompete PEO';
  end if;

  select count(*) into v_noprov from public.peo_profiles
   where nullif(btrim(website),'') is not null and not (field_provenance ? 'website');
  if v_noprov > 0 then
    raise exception '0772 verification: % held websites have no provenance', v_noprov;
  end if;

  -- no want may exist for a noncompete PEO
  if exists (select 1 from public.want_board w
             where w.subject_class='peo_family' and public.is_noncompete_peo(w.subject_key)) then
    raise exception '0772 verification: a want was opened against a noncompete PEO';
  end if;

  select count(*) into v_cron from cron.job where jobname='peo_profile_nightly';
  if v_cron <> 1 then
    raise exception '0772 verification: nightly job not scheduled';
  end if;

  select count(*) into v_wants from public.want_board where subject_class='peo_family' and status='open';
  select n_rows into v_shelf from pub.shelf_meta where surface='peo_profiles';
  raise notice '0772 OK: orphans cleared, profiles complete, % open PEO wants, shelf % rows',
    v_wants, v_shelf;
end $verify$;