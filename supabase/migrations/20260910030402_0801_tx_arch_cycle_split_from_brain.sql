-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-brain-worker-split-and-isolation (#168)
-- Articles implemented: A BRAIN IS A REPORTER. Work that mutates the spine - name expansion, city
--                       append, identity adjudication, case opening - belongs in a worker with its
--                       own slot and its own receipt, not inside the hourly reporting tick.
-- Articles verified not violated: every guard carried across UNCHANGED - the uq_companies_name_state_live
--                       collision guard on both sides of a rename, the II.4 routing of a blocked
--                       expansion to identity_adjudication_queue (never guessing a winner), the
--                       noncompete gate on the candidate set, tx_city_appendable, the bijective name
--                       test, the 25-case desk cap, the XI.1 no-re-raise receipt rule. Both functions
--                       created AS peo_gatekeeper (writer conformance - they write fenced tables).
--                       Sourcing never displayed; carrier internal-only; client street addresses
--                       never displayed; noncompete PEOs never worked.
-- Verification query attached: YES
--
-- hub_brain_tx_wc measured 54.8s (0798), 40.3s after the LCF index (0799). Under 1s of that is
-- reporting. The rest is the pre-PEO archaeology cycle: 500 dark companies matched against
-- arch_names_scratch, then city/state appends, truncated-name expansions, adjudication routing,
-- former-user conclusions and desk cases. That is a worker. It now runs as one, on its own slot.

set role peo_gatekeeper;

create or replace function public.tx_arch_cycle()
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_batch int := 0; v_resolved int := 0; v_former int := 0; v_cases int := 0;
  v_renamed int := 0; v_name_collisions int := 0;
  r record;
  v_run_id uuid := gen_random_uuid();
  v_started timestamptz := clock_timestamp();
begin
  create temp table _cycle_dark on commit drop as
  select c.id company_id, c.normalized_name, c.peo_family_slug,
         (length(c.legal_name) between 13 and 15) is_truncated
  from companies c
  left join arch_attempts a on a.company_id = c.id
  where c.peo_family_slug is not null and c.city is null
    and c.normalized_name is not null and length(c.normalized_name) >= 10
    and not company_is_noncompete(c)
    and (a.company_id is null or (a.outcome in ('refused','no_candidates') and a.attempted_at < now() - interval '7 days'))
  limit 500;
  select count(*) into v_batch from _cycle_dark;

  if v_batch > 0 and exists (select 1 from arch_names_scratch limit 1) then
    create temp table _cycle_resolved on commit drop as
    with exact_hits as (
      select d.company_id, d.peo_family_slug, n.name_norm, n.full_name,
             n.distinct_cities, n.latest_city, n.latest_state, n.latest_eff, n.has_active, n.latest_exp
      from _cycle_dark d join arch_names_scratch n on n.name_norm = d.normalized_name
      where not d.is_truncated
    ),
    prefix_counts as (
      select d.company_id, d.peo_family_slug, count(*) cnt, min(n.name_norm) only_name
      from _cycle_dark d
      join arch_names_scratch n
        on n.name_norm collate "C" >= d.normalized_name collate "C"
       and n.name_norm collate "C" < (d.normalized_name || chr(1114111)) collate "C"
      where d.is_truncated
      group by d.company_id, d.peo_family_slug
    ),
    prefix_hits as (
      select p.company_id, p.peo_family_slug, n.name_norm, n.full_name,
             n.distinct_cities, n.latest_city, n.latest_state, n.latest_eff, n.has_active, n.latest_exp
      from prefix_counts p join arch_names_scratch n on n.name_norm = p.only_name
      where p.cnt = 1
    ),
    all_hits as (select * from exact_hits union all select * from prefix_hits),
    clean as (
      select * from all_hits h
      where h.distinct_cities <= 2 and tx_city_appendable(h.peo_family_slug, h.latest_city)
    ),
    bijective as (
      select name_norm from clean group by name_norm having count(distinct company_id)=1
    )
    select distinct on (c.company_id) c.*
    from clean c join bijective b on b.name_norm = c.name_norm
    order by c.company_id, c.latest_eff desc;

    select count(*) into v_resolved from _cycle_resolved;

    update companies c
    set city = initcap(lower(r2.latest_city)),
        state = coalesce(nullif(r2.latest_state,''),'TX'),
        last_field_updated = coalesce(c.last_field_updated,'{}'::jsonb)
          || jsonb_build_object('city', jsonb_build_object('source','tx_pre_peo_archaeology','as_of', r2.latest_eff::text))
    from _cycle_resolved r2
    where r2.company_id = c.id
      and not exists (
        select 1 from companies x
        where x.id <> c.id
          and x.merged_into is null
          and coalesce(x.is_location_stub,false) = false
          and x.identity_quarantined_at is null
          and lower(btrim(regexp_replace(x.legal_name,'\s+',' ','g')))
              = lower(btrim(regexp_replace(c.legal_name,'\s+',' ','g')))
          and coalesce(upper(btrim(x.state)),'(null)')
              = coalesce(upper(btrim(coalesce(nullif(r2.latest_state,''),'TX'))),'(null)')
      );

    create temp table _rename_candidates on commit drop as
    select r2.company_id, r2.full_name, r2.name_norm, c.state,
           lower(btrim(regexp_replace(r2.full_name,'\s+',' ','g')))       as key_name,
           coalesce(upper(btrim(c.state)),'(null)')                        as key_state
    from _cycle_resolved r2
    join companies c on c.id = r2.company_id
    where length(c.legal_name) between 13 and 15
      and length(r2.full_name) > length(c.legal_name);

    create temp table _rename_ok on commit drop as
    select k.* from _rename_candidates k
    where not exists (
            select 1 from companies x
            where x.id <> k.company_id
              and x.merged_into is null
              and coalesce(x.is_location_stub,false) = false
              and x.identity_quarantined_at is null
              and lower(btrim(regexp_replace(x.legal_name,'\s+',' ','g'))) = k.key_name
              and coalesce(upper(btrim(x.state)),'(null)') = k.key_state)
      and (select count(*) from _rename_candidates k2
           where k2.key_name = k.key_name and k2.key_state = k.key_state) = 1;

    update companies c
       set legal_name = k.full_name, normalized_name = k.name_norm
      from _rename_ok k
     where k.company_id = c.id;
    get diagnostics v_renamed = row_count;

    insert into identity_adjudication_queue
      (domain, subject_table, subject_natural_key, member_ids, member_count,
       quarantine_reason, evidence, status, created_by, load_key, ruleset_version)
    select 'company_identity', 'companies', k.key_name||' | '||k.key_state,
           array[k.company_id], 2,
           'II.2/II.4 archaeology name expansion blocked by uq_companies_name_state_live: '
           ||'expanding a truncated legal_name to its full archaeology name would collide with '
           ||'another live company at the same name+state. Either they are the same entity '
           ||'(merge through the gate) or the archaeology match is wrong. No winner guessed.',
           jsonb_build_object('company_id', k.company_id, 'proposed_legal_name', k.full_name,
                              'proposed_normalized_name', k.name_norm, 'state', k.state,
                              'source','tx_pre_peo_archaeology')
    , 'quarantined', 'tx_arch_cycle',
           'arch-name-collision-'||to_char(current_date,'YYYYMMDD'),
           'constitution-v1/tx-archaeology'
    from _rename_candidates k
    where not exists (select 1 from _rename_ok o where o.company_id = k.company_id)
      and not exists (
        select 1 from identity_adjudication_queue q
        where q.domain = 'company_identity' and q.subject_table = 'companies'
          and q.subject_natural_key = k.key_name||' | '||k.key_state);
    get diagnostics v_name_collisions = row_count;

    insert into field_observations (subject_class, subject_key, field_name, value_text, as_of, source_hub, evidence_ref, observed_at, dedupe_key)
    select 'company', c.ein, 'city', c.city, r2.latest_eff, 'tx_wc',
           'archaeology:'||r2.company_id, now(), 'arch_city:'||r2.company_id
    from _cycle_resolved r2 join companies c on c.id = r2.company_id
    where c.ein is not null and c.city is not null
    on conflict (dedupe_key) do nothing;

    insert into arch_attempts (company_id, attempted_at, outcome)
    select d.company_id, now(),
           case when r2.company_id is not null then 'resolved'
                when exists (select 1 from arch_names_scratch n where n.name_norm = d.normalized_name
                             or (d.is_truncated and n.name_norm collate "C" >= d.normalized_name collate "C"
                                 and n.name_norm collate "C" < (d.normalized_name||chr(1114111)) collate "C"))
                then 'refused' else 'no_candidates' end
    from _cycle_dark d left join _cycle_resolved r2 on r2.company_id = d.company_id
    on conflict (company_id) do update set attempted_at = excluded.attempted_at, outcome = excluded.outcome;

    for r in
      select rr.*, (rr.peo_family_slug = 'trinet') is_historical
      from _cycle_resolved rr where rr.has_active
    loop
      if r.is_historical then
        v_former := v_former + 1;
        insert into hub_conclusions (hub_slug, concluded_at, window_start, conclusion_kind, subject, detail, confidence,
          changed_from, changed_to, as_of, detection_method, significance, evidence_refs, affected, suggested_action, dedupe_key)
        values ('tx_wc', now(), now(), 'former_user_confirmed', 'active_own_policy_dead_book',
          jsonb_build_object('company_id', r.company_id, 'family', r.peo_family_slug, 'own_policy_expires', r.latest_exp),
          0.85,
          jsonb_build_object('status','attributed to dead-book family '||r.peo_family_slug),
          jsonb_build_object('status','independent coverage active - former PEO user, proven buyer'),
          r.latest_eff,
          'archaeology: active own policy + family book known expired',
          'former-user doctrine: proven PEO-model buyers are prime pipeline; independence date = policy effective',
          jsonb_build_object('migration','0162'), jsonb_build_object('company_id', r.company_id),
          'peo_user_status flip rides directive #89 triage', 'arch_former:'||r.company_id)
        on conflict do nothing;
      elsif v_cases < 25 then
        v_cases := v_cases + 1;
        perform mesh_open_case(
          'arch_active_policy_contradiction', 'company', r.company_id::text,
          'family='||r.peo_family_slug||';pattern=active_own_policy_on_current_book',
          jsonb_build_object('company_id', r.company_id, 'family', r.peo_family_slug,
            'own_policy_effective', r.latest_eff, 'own_policy_expires', r.latest_exp,
            'question', 'Active own direct WC policy while attributed to a current-book PEO: live departure (switch signal) or name collision? Corroborate: fingerprint presence in current pass + attribution-evidence date vs policy date ordering.'),
          'tx_arch_cycle');
      end if;
    end loop;
  end if;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('tx_arch_cycle', v_run_id, v_started, now(), true,
    jsonb_build_object('arch_batch', v_batch, 'arch_resolved', v_resolved,
      'names_expanded', v_renamed, 'name_collisions_adjudicated', v_name_collisions,
      'former_user_confirmations', v_former, 'desk_cases_opened', v_cases));

  return jsonb_build_object('arch_batch', v_batch, 'arch_resolved', v_resolved,
    'names_expanded', v_renamed, 'name_collisions_adjudicated', v_name_collisions,
    'former_user_confirmations', v_former, 'desk_cases_opened', v_cases);
exception when others then
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('tx_arch_cycle', v_run_id, v_started, now(), false,
    jsonb_build_object('error', left(sqlerrm,300), 'sqlstate', sqlstate,
                       'arch_batch', v_batch, 'arch_resolved', v_resolved));
  insert into edge_debug (fn, step, detail, at)
  values ('tx_arch_cycle','failed', left(sqlerrm,200), now());
  return jsonb_build_object('ok', false, 'error', left(sqlerrm,300));
end
$function$;

create or replace function public.hub_brain_tx_wc()
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  w timestamptz; prior_n bigint; new_n bigint;
  v_answered int := 0; v_wants int := 0;
  r record;
  v_run_id uuid := gen_random_uuid();
  v_started timestamptz := clock_timestamp();
begin
  select coalesce(max(concluded_at), now() - interval '24 hours') into w
    from hub_conclusions where hub_slug='tx_wc';
  select count(distinct app.normalize_name(split_part(upper(insured_employer_name),' LCF ',2))) into prior_n
  from tx_wc_fingerprint_staging where first_seen_at <= w and upper(insured_employer_name) like '% LCF %';
  select count(distinct app.normalize_name(split_part(upper(insured_employer_name),' LCF ',2))) into new_n
  from tx_wc_fingerprint_staging where upper(insured_employer_name) like '% LCF %';
  if new_n > prior_n then
    insert into hub_conclusions (hub_slug, window_start, conclusion_kind, subject, as_of, detection_method, significance,
      changed_from, changed_to, evidence_refs, affected, confidence, suggested_action, dedupe_key, detail)
    values ('tx_wc', w, 'lcf_universe_grew', 'distinct LCF-visible employers', current_date,
      'distinct normalized employer names carrying the LCF marker, first_seen_at stamps after prior conclusion window',
      'each new LCF employer is a PEO client made newly visible - attribution pipeline feedstock and potential switch/new-client evidence',
      jsonb_build_object('distinct_employers', prior_n), jsonb_build_object('distinct_employers', new_n),
      jsonb_build_object('table','tx_wc_fingerprint_staging'),
      jsonb_build_object('scope','TX universe'), 0.9,
      'attribution pipeline will match next nightly; no action unless growth anomalous',
      'lcf_universe_'||current_date, jsonb_build_object('delta', new_n - prior_n))
    on conflict do nothing;
  end if;

  for r in select b.* from mesh_scan_board('tx_wc', 25) b
  loop
    exit when v_answered >= 25;
    if r.field_wanted in ('wc_renewal_month','wc_carrier','wc_coverage_status','wc_policy_expiration')
       and exists (select 1 from companies c where c.ein = r.subject_key and c.wc_last_observed_at is not null) then
      perform mesh_answer_want('tx_wc', r.id,
        (select jsonb_build_object(r.field_wanted,
            case r.field_wanted
              when 'wc_renewal_month' then to_jsonb(c.wc_renewal_month)
              when 'wc_carrier' then to_jsonb(c.wc_carrier)
              when 'wc_coverage_status' then to_jsonb(c.wc_coverage_status)
              else to_jsonb(c.wc_policy_expiration) end)
         from companies c where c.ein = r.subject_key and c.wc_last_observed_at is not null limit 1),
        jsonb_build_object('provenance','tx_wc client-native, dated'),
        'tx_wc',
        (select c.wc_last_observed_at::date from companies c where c.ein = r.subject_key limit 1),
        0.9, r.subject_key);
      v_answered := v_answered + 1;
    end if;
  end loop;

  for r in
    select c.id, c.legal_name, c.city from companies c
    where c.peo_family_slug is not null and c.ein is null and c.city is not null
      and c.last_field_updated->'city'->>'source' = 'tx_pre_peo_archaeology'
      and not exists (select 1 from want_board wb
                      where wb.subject_key = c.id::text and wb.field_wanted='ein'
                        and wb.status in ('open','unanswerable'))
    limit 10
  loop
    perform mesh_post_want('tx_wc','field_hunt','company', r.id::text, 'ein',
      jsonb_build_object('legal_name', r.legal_name, 'city', r.city, 'why','archaeology-resolved LCF client; EIN unlocks federal corroboration'),
      3, 'record', interval '30 days');
    v_wants := v_wants + 1;
  end loop;

  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brain_tx_wc', v_run_id, v_started, now(), true,
    jsonb_build_object('lcf_universe', new_n, 'wants_answered', v_answered,
                       'ein_wants_posted', v_wants, 'worker', 'tx_arch_cycle (split out 0801)'));
exception when others then
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('hub_brain_tx_wc', v_run_id, v_started, now(), false,
    jsonb_build_object('error', left(sqlerrm,300), 'sqlstate', sqlstate));
  insert into edge_debug (fn, step, detail, at)
  values ('hub_brain_tx_wc','failed', left(sqlerrm,200), now());
end
$function$;

revoke all on function public.tx_arch_cycle() from public, anon, authenticated;
grant execute on function public.tx_arch_cycle() to service_role;

reset role;

select cron.schedule('tx_arch_cycle', '26 * * * *', 'select public.tx_arch_cycle()');

-- VERIFICATION
-- select public.tx_arch_cycle();
-- select public.hub_brain_tx_wc();   -- must now return in about a second
-- select name, ok, detail from jobs where name in ('hub_brain_tx_wc','tx_arch_cycle') order by finished_at desc limit 4;