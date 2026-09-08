-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-seed-observation-backfill
-- Articles implemented: ENTRY PIPELINE (field_observations with provenance and period shape),
--   Mesh Cross-Reference Mandate 1 (canonicalised through peo_families), VI.2 (job receipts)
-- Articles verified not violated: noncompete law (noncompete records skipped entirely);
--   ratified_63.1 preserved - 0774 guarantees an undated-grade claim cannot date a switch
-- Verification query attached: YES

-- ============================================================================
-- 0775  Backfill: the seed's own claims join the pipeline
--
-- The seed wrote peo_original / peo_user_status straight onto companies and
-- never wrote a field_observation, so 171,168 live records carried a
-- vendor-supplied PEO with no provenance row and corroboration undercounted a
-- 3-source record as 2. Requires 0774 (guard) to be safe.
-- ============================================================================

set role peo_gatekeeper;

create or replace function public.backfill_seed_observations(p_limit int default 20000)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $fn$
declare v_name int := 0; v_slug int := 0; v_status int := 0; v_scanned int := 0;
begin
  create temp table if not exists _seed_batch (
    id uuid, ein text, peo_original text, peo_user_status text,
    hub text, load_key text, created_at timestamptz
  ) on commit drop;
  delete from _seed_batch;

  insert into _seed_batch
  select c.id, c.ein, c.peo_original, c.peo_user_status,
         'seed:'||coalesce(nullif(btrim(c.seed_source_file),''),'unknown'),
         c.load_key, c.created_at
  from companies c
  where c.merged_into is null
    and nullif(btrim(c.peo_original),'') is not null
    and not company_is_noncompete(c)
    and not exists (
      select 1 from field_observations o
      where o.company_id = c.id and o.source_hub like 'seed:%' and o.field_name = 'peo_name')
  limit p_limit;

  get diagnostics v_scanned = row_count;
  if v_scanned = 0 then
    return jsonb_build_object('scanned',0,'peo_name',0,'peo_family_slug',0,'peo_user_status',0,'done',true);
  end if;

  insert into field_observations
    (company_id, subject_class, subject_key, field_name, value_text, as_of, source_hub,
     evidence_ref, observed_at, dedupe_key, resolution_status)
  select b.id, 'company', coalesce(b.ein, b.id::text), 'peo_name', btrim(b.peo_original),
         b.created_at::date, b.hub,
         b.hub||':'||coalesce(nullif(btrim(b.load_key),''),b.id::text),
         b.created_at, 'seed_backfill:'||b.id::text||':peo_name', null
  from _seed_batch b
  on conflict (dedupe_key) do nothing;
  get diagnostics v_name = row_count;

  insert into field_observations
    (company_id, subject_class, subject_key, field_name, value_text, as_of, source_hub,
     evidence_ref, observed_at, dedupe_key, resolution_status)
  select b.id, 'company', coalesce(b.ein, b.id::text), 'peo_family_slug', f.family_slug,
         b.created_at::date, b.hub,
         b.hub||':'||coalesce(nullif(btrim(b.load_key),''),b.id::text)||':canonicalised',
         b.created_at, 'seed_backfill:'||b.id::text||':peo_family_slug', null
  from _seed_batch b
  join lateral (
      select ff.family_slug from peo_families ff
      where regexp_replace(upper(ff.alias),'[^A-Z0-9]','','g')
          = regexp_replace(upper(b.peo_original),'[^A-Z0-9]','','g')
      limit 1) f on true
  where not is_noncompete_peo(f.family_slug)
  on conflict (dedupe_key) do nothing;
  get diagnostics v_slug = row_count;

  insert into field_observations
    (company_id, subject_class, subject_key, field_name, value_text, as_of, source_hub,
     evidence_ref, observed_at, dedupe_key, resolution_status)
  select b.id, 'company', coalesce(b.ein, b.id::text), 'peo_user_status', b.peo_user_status,
         b.created_at::date, b.hub,
         b.hub||':'||coalesce(nullif(btrim(b.load_key),''),b.id::text),
         b.created_at, 'seed_backfill:'||b.id::text||':peo_user_status', null
  from _seed_batch b
  where nullif(btrim(b.peo_user_status),'') is not null
  on conflict (dedupe_key) do nothing;
  get diagnostics v_status = row_count;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('backfill_seed_observations', gen_random_uuid(), now(), now(), true,
          jsonb_build_object('scanned', v_scanned, 'peo_name', v_name,
                             'peo_family_slug', v_slug, 'peo_user_status', v_status));

  return jsonb_build_object('scanned', v_scanned, 'peo_name', v_name,
    'peo_family_slug', v_slug, 'peo_user_status', v_status, 'done', v_scanned < p_limit);
end $fn$;

comment on function public.backfill_seed_observations(int) is
  '0775: writes the PEO facts the seed files delivered (miEdge/HubSpot) onto field_observations as vendor_attested claims. hub seed:<file>, evidence seed:<file>:<load_key>, as_of = load date. Safe only because 0774 forbids an M4_undated-grade source from defining a switch date. Chunked; call until done=true. Noncompete records skipped.';

revoke all on function public.backfill_seed_observations(int) from public;
revoke all on function public.backfill_seed_observations(int) from map_reader;
grant execute on function public.backfill_seed_observations(int) to service_role;

reset role;

do $verify$
declare v jsonb;
begin
  select public.backfill_seed_observations(500) into v;
  if (v->>'peo_name')::int = 0 then
    raise exception '0775 verification: probe batch wrote no seed observations';
  end if;
  if exists (select 1 from public.field_observations o
             join public.companies c on c.id = o.company_id
             where o.source_hub like 'seed:%' and public.company_is_noncompete(c)) then
    raise exception '0775 verification: a noncompete record received a seed observation';
  end if;
  raise notice '0775 OK: probe wrote %', v;
end $verify$;