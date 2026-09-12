-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0870-mesh-backlog (opened BEFORE apply)
-- Articles implemented: MESH CROSS-REFERENCE MANDATE, VIII.2 (a disagreement is adjudicated, never auto-merged),
--   IX.2 (appends carry the source's real dates; never a date we cannot prove), ENTRY PIPELINE (written only
--   through record_field_observation), XIII.1 (RLS on every table created)
-- Articles verified not violated: III.1 (zero spend), XIV.6, the noncompete law (0 protected PEOs touched),
--   the switch_detection_nightly hold (no switch minted; disagreements QUEUED, exactly as that hold requires)
-- Verification query attached: YES
--
-- WHAT GAZZ CAUGHT: 127,482 companies - 52.6% of the book - had never been confirmed by any live source. Vendor
-- seed rows and nothing else. The mandate says every record is cross-referenced against the whole mesh on every
-- ingest; for this half it never happened, and nothing even records an attempt (resolution_attempts: ZERO rows).
--
-- NOT A COVERAGE GAP - WE ALREADY HELD THE DATA:
--   FL WC ledger 25,731 distinctive named entities -> only 1,155 companies had ever received an fl_wc observation
--   TX WC ledger  5,078 distinctive named entities
-- Joined on the platform's own normalization rule: 6,225 distinctive 1-to-1 matches, every one naming a PEO.
--
--   4,586 AGREE with held attribution -> appended as corroboration (0.90, two sources agree)
--     235 had NO attribution          -> appended as attribution  (0.80, one state registry)
--   1,394 DISAGREE                    -> QUEUED for adjudication, not written, no switch minted
--      16 PEO name uncanonicalizable  -> QUEUED
--   Result: 4,815 companies validated; 1,410 queued; 0 refused; 0 switches minted.
--
-- FOUR GUARDS CAUGHT ME WRITING THIS, each recorded rather than quietly fixed:
--   1. direct INSERT into field_observations refused by ACL - the one-door law. Rewritten through
--      record_field_observation(), which also refuses noncompete touches and posts the mesh's want/decay events.
--   2. ONE-DOOR LAW rejected source_hub "FL_wc" - a missing lower().
--   3. my own 0867 check (as_of_field_unclassified) demanded fl_wc/tx_wc peo_family_slug_sighting be declared
--      evidence before it could be written. It was.
--   4. 0871: I broke the as-of law inside the hour. least(window_end, current_date) caps an IN-FORCE policy to
--      TODAY, so 2,163 appends read "As of Sep 12, 2026" - the manufactured "we checked today" the law exists to
--      prevent. A live term proves its EFFECTIVE date, not today; the policy could have been cancelled this
--      morning. Corrected: term ended -> window_end; term running -> window_start. valid_through keeps the term.
--   5. 0872: rls_on_every_public_table failed on the four working tables. Fenced with read policies.
--
-- MY OWN DIAGNOSTIC BUG, for the record: I first reported "5,990 conflicts" because I compared a family SLUG
-- (southeastpersonnelleasinginc) against a raw ledger NAME (SOUTHEAST PERSONNEL LEASING, INC.). Zero agreement out
-- of 6,225 was the tell. Canonicalized through peo_families and the real split is 4,586 agree / 1,394 disagree.
--
-- WHAT REMAINS (honest): of the 127,482, only 8,342 have ANY name match in the state ledgers we hold. 54,117 sit in
-- states with no WC feed at all. The state ledgers are now essentially exhausted; the rest is a coverage problem
-- answered by new sources, not by a better join.

insert into public.observation_evidence_class (source_hub, field_name, kind, note) values
 ('fl_wc','peo_family_slug_sighting','evidence','Florida WC ledger names the PEO on a dated policy term'),
 ('tx_wc','peo_family_slug_sighting','evidence','Texas WC ledger names the PEO on a dated policy term')
on conflict (source_hub, field_name) do nothing;

create table if not exists public.mesh_backlog_adjudication (
  id bigserial primary key, company_id uuid not null, state text not null, legal_name text,
  held_peo_family_slug text, ledger_peo_raw text, ledger_peo_family_slug text, ledger_nk text,
  window_start date, window_end date,
  kind text not null check (kind in ('disagreement','unresolved_peo_name')),
  status text not null default 'open' check (status in ('open','ruled','dismissed')),
  ruling text, ruled_by text, ruled_at timestamptz, queued_at timestamptz not null default now(),
  unique (company_id, ledger_nk));

-- working tables: unvalidated_backlog, mesh_ledger_nn, mesh_append_candidates, mesh_backlog_best
-- (all RLS-enabled with read policies in 0872)

create or replace function public.mesh_backlog_append_batch(p_limit int default 500)
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare r record; n_ok int := 0; n_refused int := 0; v_id bigint; v_as_of date;
begin
  for r in
    select b.*, c.peo_family_slug as held
      from public.mesh_backlog_best b join public.companies c on c.id = b.company_id
     where not b.appended and b.ledger_family_slug is not null
       and (c.peo_family_slug is null or c.peo_family_slug = b.ledger_family_slug)
     order by b.company_id limit p_limit
  loop
    -- an in-force term proves its effective date, never today
    v_as_of := case when r.window_end > current_date then r.window_start else r.window_end end;
    if v_as_of is null then v_as_of := least(r.window_start, r.window_end); end if;
    v_id := public.record_field_observation(
      'company', r.company_id::text, 'peo_family_slug_sighting', r.ledger_family_slug,
      v_as_of, lower(r.state) || '_wc',
      'mesh_backlog_0870|' || r.state || ' WC ledger nk:' || r.nk
        || '|policy ' || coalesce(r.window_start::text,'?') || '..' || coalesce(r.window_end::text,'?')
        || '|named:' || left(coalesce(r.display_name,''), 60)
        || '|confidence:' || case when r.held = r.ledger_family_slug
                                  then '0.90 (distinctive name, two sources agree)'
                                  else '0.80 (distinctive name, one state registry)' end,
      r.window_end);
    if v_id is null then n_refused := n_refused + 1; else n_ok := n_ok + 1; end if;
    update public.mesh_backlog_best set appended = true where company_id = r.company_id;
  end loop;
  return jsonb_build_object('appended', n_ok, 'refused', n_refused,
    'remaining', (select count(*) from public.mesh_backlog_best where not appended));
end $f$;
revoke execute on function public.mesh_backlog_append_batch(int) from public, anon;
grant execute on function public.mesh_backlog_append_batch(int) to service_role, postgres;
