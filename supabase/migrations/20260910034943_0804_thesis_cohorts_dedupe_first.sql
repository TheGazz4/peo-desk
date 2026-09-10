-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-10-mint-thesis-cost (#170)
-- Articles implemented: DEDUPE BEFORE YOU BUILD. A minting cohort must exclude what it has already
--                       minted BEFORE running the expensive gates, not after. Per-thesis cost is
--                       measured and recorded so a cohort cannot quietly bloat again.
-- Articles verified not violated: noncompete gate present and UNCHANGED in every cohort;
--                       is_peo_targetable present and unchanged; identical claim text, evidence,
--                       confidence, window and evidence_hash produced for every row that mints;
--                       sourcing never displayed; carrier internal-only; client street addresses
--                       never displayed.
-- Verification query attached: YES
--
-- MEASUREMENT (before)
--   proven_switcher   2,984 ms - 6,006 rows built, 349 survive dedupe, 0 mint
--   acquired_book     4,151 ms - 8,620 rows built, 4,310 survive dedupe, 0 mint
--   cpeo_cert_risk    1,574 ms - 1,027 rows built,     0 survive dedupe, 0 mint
--   TOTAL             ~7.3 s every hour to mint NOTHING.
--
-- WHY: mint_thesis_plays wraps each cohort as
--        insert ... select ... from (COHORT) q where not exists (... evidence_hash ...)
--      so the dedupe runs LAST. Every hour the cohort re-derived 15,653 rows - running
--      company_is_noncompete (up to 6 regex passes each) and is_peo_targetable on all of them -
--      and then discarded the lot. The rows that did survive the hash test were then discarded a
--      second time by "on conflict (company_id, angle_type) do nothing", because those companies
--      already hold an angle of that type.
--
-- FIX: each cohort now excludes, up front, (a) companies that already hold an angle of this type -
--      which is exactly what the on-conflict rule enforces, so behaviour is identical - and
--      (b) rows whose evidence_hash already exists. The gates then run on what is genuinely new.
--      proven_switcher additionally replaces a correlated max(evidence_as_of) subplan that executed
--      once per row (6,198 executions) with a single window pass. Tie behaviour is preserved: all
--      rows at the company's max evidence_as_of are kept, verified to return the same 349 rows.
--
-- MEASUREMENT (after): 66 ms + 42 ms + 12 ms = ~0.12 s. Same results.

update public.play_theses set cohort_sql = $q$
 with latest as materialized (
   select id, company_id, switch_scope, evidence_as_of, from_family_slug, to_family_slug,
          max(evidence_as_of) over (partition by company_id) mx
   from peo_switch_ledger
 ),
 cand as materialized (
   select c.id as company_id, c.legal_name, c.wc_renewal_month,
          l.id as lid, l.from_family_slug, l.to_family_slug, l.evidence_as_of,
          md5(c.id::text||':proven_switcher:'||l.id) as evidence_hash
   from latest l
   join companies c on c.id = l.company_id
   where l.switch_scope = 'cross_family'
     and l.evidence_as_of = l.mx
     and c.merged_into is null
     and not exists (select 1 from company_angles a2
                     where a2.company_id = c.id and a2.angle_type = 'proven_switcher')
     and not exists (select 1 from company_angles a
                     where a.evidence_hash = md5(c.id::text||':proven_switcher:'||l.id))
 )
 select q.company_id,
   format('%s has switched PEOs before (%s -> %s, %s) - a proven buyer of the PEO decision. Known WC renewal month: %s.',
     q.legal_name, q.from_family_slug, q.to_family_slug, q.evidence_as_of,
     coalesce(q.wc_renewal_month::text,'unknown')) as claim,
   jsonb_build_object('ref','switch_ledger:'||q.lid, 'from', q.from_family_slug,
                      'to', q.to_family_slug, 'as_of', q.evidence_as_of) as evidence,
   'VERIFIED' as evidence_tag,
   0.85 as confidence,
   current_date as window_start,
   (current_date + interval '18 months')::date as window_end,
   q.evidence_hash
 from cand q
 join companies c on c.id = q.company_id
 where is_peo_targetable(c.id) and not company_is_noncompete(c)
$q$ where thesis_slug = 'proven_switcher';

update public.play_theses set cohort_sql = $q$
 with cand as materialized (
   select c.id as company_id, c.legal_name,
          e.id as eid, e.counterparty_name, e.acquirer_slug, e.counterparty_slug,
          e.event_date, e.researched_at, e.narrative_line,
          md5(c.id::text||':acquired_book:'||e.id) as evidence_hash
   from peo_ma_events e
   join companies c on c.peo_family_slug = e.counterparty_slug
   where e.event_kind in ('acquired','merged')
     and e.counterparty_slug is not null
     and c.merged_into is null
     and not exists (select 1 from company_angles a2
                     where a2.company_id = c.id and a2.angle_type = 'acquired_book')
     and not exists (select 1 from company_angles a
                     where a.evidence_hash = md5(c.id::text||':acquired_book:'||e.id))
 )
 select q.company_id,
   format('%s''s PEO (%s) was acquired by %s on %s - carriers and renewal terms are changing without them choosing. %s',
     q.legal_name, q.counterparty_name, q.acquirer_slug,
     coalesce(q.event_date::text,'(date pending)'), q.narrative_line) as claim,
   jsonb_build_object('ref','ma_event:'||q.eid, 'acquirer', q.acquirer_slug,
                      'counterparty', q.counterparty_slug, 'event_date', q.event_date) as evidence,
   'VERIFIED' as evidence_tag,
   0.8 as confidence,
   coalesce(q.event_date, q.researched_at::date) as window_start,
   (coalesce(q.event_date, q.researched_at::date) + interval '18 months')::date as window_end,
   q.evidence_hash
 from cand q
 join companies c on c.id = q.company_id
 where is_peo_targetable(c.id) and not company_is_noncompete(c)
$q$ where thesis_slug = 'acquired_book';

update public.play_theses set cohort_sql = $q$
 with ruled as materialized (
   select e.subject_key as name_norm, e.ruling->>'family_slug' as fam
   from exception_desk e
   where e.case_class='cpeo_link_adjudication' and e.status='ruled'
     and e.ruling->>'verdict' = 'linked'
     and coalesce((e.ruling->>'mint_eligible')::boolean, false)
     and e.ruling->>'family_slug' is not null
 ),
 risk as materialized (
   select distinct on (r.fam) r.fam, r.name_norm, s.cpeo_name, s.list_kind, s.effective_date
   from ruled r
   join irs_cpeo_snapshots s on s.name_norm = r.name_norm
     and s.snapshot_date = (select max(snapshot_date) from irs_cpeo_snapshots)
     and s.list_kind in ('suspended','revoked')
     and s.effective_date > current_date - interval '24 months'
   order by r.fam, s.effective_date desc
 ),
 cand as materialized (
   select c0.id as company_id, c0.legal_name, r.fam,
          r.cpeo_name, r.list_kind, r.effective_date, r.name_norm,
          md5(c0.id::text||':cpeo_cert_risk') as evidence_hash
   from risk r
   join companies c0 on c0.peo_family_slug = r.fam
   where c0.merged_into is null
     and not exists (select 1 from company_angles a2
                     where a2.company_id = c0.id and a2.angle_type = 'cpeo_cert_risk')
     and not exists (select 1 from company_angles a
                     where a.evidence_hash = md5(c0.id::text||':cpeo_cert_risk'))
 )
 select q.company_id,
   format('%s''s PEO entity %s carries an IRS certification action: %s effective %s. %s',
     q.legal_name, q.cpeo_name, q.list_kind, q.effective_date,
     case q.list_kind when 'suspended'
       then 'By law every customer received written notice within 10 days; section 3511 protection is gone for new contracts.'
       else 'On revocation, customers may be liable for the federal employment taxes the PEO was supposed to remit.' end) as claim,
   jsonb_build_object('ref','cpeo_snapshot:2026-04-15','cpeo_name', q.cpeo_name,'list', q.list_kind,
                      'effective', q.effective_date,'ruled_case','cpeo_link:'||q.name_norm) as evidence,
   'VERIFIED' as evidence_tag, 0.92 as confidence,
   q.effective_date as window_start,
   (q.effective_date + interval '24 months')::date as window_end,
   q.evidence_hash
 from cand q
 join companies c on c.id = q.company_id
 where is_peo_targetable(c.id) and not company_is_noncompete(c)
$q$ where thesis_slug = 'cpeo_cert_risk';

-- MEASURE EVERY THESIS, EVERY RUN --------------------------------------------
create or replace function public.mint_thesis_plays()
returns jsonb
language plpgsql
as $function$
declare t record; v_minted int; v_total int := 0; v_res jsonb := '[]'::jsonb; v_err text;
        t0 timestamptz; v_ms int;
begin
  -- NOTE: no set_config('statement_timeout') here. It would not bind - statement_timeout is
  -- measured against the outermost statement. The budget is set by the caller as its own
  -- top-level statement (see the mint_thesis_plays cron job).
  for t in select * from play_theses where enabled loop
    v_minted := 0; v_err := null; t0 := clock_timestamp();
    begin
      execute format($f$
        insert into company_angles (company_id, angle_type, claim, evidence, evidence_tag, confidence, timing_window, suggested_channel, suggested_persona, status, evidence_hash)
        select q.company_id, %L, q.claim, q.evidence, q.evidence_tag, q.confidence,
               daterange(q.window_start, q.window_end, '[]'), %L, %L, 'live', q.evidence_hash
        from (%s) q
        where not exists (select 1 from company_angles a where a.evidence_hash = q.evidence_hash)
        limit 1000
        on conflict (company_id, angle_type) do nothing
      $f$, t.thesis_slug, t.suggested_channel, t.suggested_persona, t.cohort_sql);
      get diagnostics v_minted = row_count;
    exception when others then
      v_err := left(sqlerrm, 240);
      insert into source_alerts (source_name, change_summary)
      values ('mint_thesis_plays', t.thesis_slug||': '||v_err);
    end;
    v_ms := (extract(epoch from (clock_timestamp() - t0)) * 1000)::int;
    v_res := v_res || case when v_err is null
      then jsonb_build_object('thesis', t.thesis_slug, 'minted', v_minted, 'ms', v_ms)
      else jsonb_build_object('thesis', t.thesis_slug, 'minted', v_minted, 'ms', v_ms, 'ERRORED', v_err) end;
    v_total := v_total + v_minted;
  end loop;
  insert into jobs (name, run_id, started_at, finished_at, ok, detail)
  values ('mint_thesis_plays', gen_random_uuid(), now(), clock_timestamp(), true,
    jsonb_build_object('total_minted', v_total, 'by_thesis', v_res));
  return v_res;
end $function$;

-- STANDING LAW ---------------------------------------------------------------
set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
 'thesis_mint_cost', 'mechanical', 'XII.4', 'all', 'RED',
 'No enabled play thesis may take longer than 5 seconds to decide what to mint. A cohort that does is rebuilding rows it will throw away - the defect found on 2026-09-10, when three cohorts spent 7.3 seconds an hour deriving 15,653 rows and minting zero. Reads the per-thesis timings recorded on the latest mint_thesis_plays receipt.',
 'select x.thesis, x.ms from (select j.detail from jobs j where j.name = ''mint_thesis_plays'' order by j.finished_at desc limit 1) r, lateral jsonb_to_recordset(r.detail->''by_thesis'') as x(thesis text, minted int, ms int) where x.ms > 5000',
 '{"mode":"zero_rows"}'::jsonb,
 'select ''zz_thesis''::text as thesis, 99999::int as ms'
)
on conflict (check_name) do update
  set module=excluded.module, article=excluded.article, scope=excluded.scope,
      severity=excluded.severity, description=excluded.description,
      check_sql=excluded.check_sql, expectation=excluded.expectation,
      selftest_sql=excluded.selftest_sql;

reset role;

-- VERIFICATION
-- select mint_thesis_plays();   -- every thesis reports ms; total well under 1s, minted unchanged
-- select detail from jobs where name='mint_thesis_plays' order by finished_at desc limit 1;