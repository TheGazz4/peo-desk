-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-2026-09-08-tx-liveness-and-peo-codes
-- Articles implemented: XI.1 silent-brain law (the liveness signal must measure what the projection
--   is supposed to consume, or it cries wolf and hides the next real stall), Mesh Cross-Reference
--   Mandate (every leasing-coded policy is PEO evidence), no-guessing doctrine (codes cited from 0785)
-- Articles verified not violated: code 1 (6.5M ordinary employers) still excluded; code 3 (the PEO's
--   own internal policy) is NOT written into the client ledger
-- Verification query attached: YES

-- ============================================================================
-- 0787  Texas: fix the false stall, harvest the codes we were dropping
--
-- ALARM: mesh_liveness FAIL - "TX raw intake grew by 1,880,132 while the ledger
-- produced nothing."
--
-- DIAGNOSIS (autoheal doctrine: diagnose before repairing). Two separate things,
-- one real and one not:
--
--   1. NOT A STALL. The TX pump was widened to lane peo_flag_all and now pulls
--      the ENTIRE Texas WC universe - 6,563,062 of 6.76M staged rows are WCIO
--      code 1, ordinary non-leasing employers the projection is right to ignore.
--      The adapter's source_count_query counted every raw row, so widening the
--      pump reads as a stall forever - and would mask the next real one, which
--      is exactly the failure this check was written after (the 11-day FL
--      breach). Now counts PROJECTABLE intake: what the projection is supposed
--      to consume, per the codes recorded in 0785.
--
--   2. A REAL GAP. mesh_project_tx read only code 2 and the "LCF" name
--      convention. Codes 4, 6, 7 and 8 - all co-employment relationships per
--      WCIO - were dropped with nobody having decided to drop them:
--         code 4  client policy, leased workers        51 names (35 new)
--         code 6  client policy, non-leased workers   136 names (49 new)
--         code 7  client policy, both populations      64 names (62 new)
--         code 8  PEO multi-client, staff excluded      11 names (11 new)
--      157 employer names that never reached the ledger. Each now carries its
--      code and the published meaning as evidence.
--
-- Code 3 (the PEO's own policy for internal staff) is deliberately NOT written
-- to the client ledger - those 51 names are PEO entities, not clients, and are
-- left for the PEO registry lane rather than guessed into the book.
-- ============================================================================

update public.mesh_state_adapters
set source_count_query =
  'select count(*) from tx_wc_fingerprint_staging s '
  'where s.insured_employer_name ilike ''% LCF %'' '
  '   or exists (select 1 from wcio_leasing_policy_codes c '
  '              where c.code = s.peo_leasing_flag::text and c.implies_peo_relationship)'
where state = 'TX';

create or replace function public.mesh_project_tx()
returns void
language plpgsql
as $function$
begin
  delete from mesh_raw_nk_map where state = 'TX';
  insert into mesh_raw_nk_map (state, raw_name, nk)
  select 'TX', raw, nk from (
    select raw, case when raw ilike '% LCF %'
      then app.normalize_name(nullif(split_part(raw,' LCF ',2),''))
      else app.normalize_name(raw) end nk
    from (select distinct insured_employer_name raw
          from tx_wc_fingerprint_staging
          where insured_employer_name ilike '% LCF %'
             or peo_leasing_flag::text in ('2','4','6','7','8')) r) q
  where q.nk is not null
  on conflict (state, raw_name) do update set nk = excluded.nk;

  -- named: the Texas "<PEO> LCF <CLIENT>" convention (WCIO code 5 shape)
  insert into mesh_state_ledger (state, hub_slug, kind, nk, display_name, peo_family, window_start, window_end, confidence, evidence_note)
  select 'TX','tx_wc','named', q.nk, q.disp, q.peo, min(q.s), max(q.e), 0.95, 'TX LCF inline naming'
  from (select app.normalize_name(nullif(split_part(raw,' LCF ',2),'')) nk,
               nullif(split_part(raw,' LCF ',2),'') disp,
               mesh_peo_display(split_part(raw,' LCF ',1)) peo, s, e
        from (select insured_employer_name raw,
                     min(policy_effective_date::date) s, max(policy_expiration_date::date) e
              from tx_wc_fingerprint_staging
              where insured_employer_name ilike '% LCF %' group by 1) r) q
  where q.nk is not null
  group by 4,5,6;

  insert into mesh_state_ledger (state, hub_slug, kind, nk, display_name, peo_family, premium, eff, confidence, evidence_note)
  select distinct on (q.nk) 'TX','tx_wc','premium', q.nk, q.disp, q.tx_peo, q.prem, q.eff, 0.95, 'TX LCF standard premium'
  from (select app.normalize_name(nullif(split_part(raw,' LCF ',2),'')) nk,
               nullif(split_part(raw,' LCF ',2),'') disp,
               mesh_peo_display(split_part(raw,' LCF ',1)) tx_peo, prem, eff
        from (select distinct on (insured_employer_name)
                     insured_employer_name raw, state_standard_premium prem,
                     policy_effective_date::date eff
              from tx_wc_fingerprint_staging
              where insured_employer_name ilike '% LCF %' and state_standard_premium > 0
              order by insured_employer_name, policy_effective_date::date desc) d) q
  where q.nk is not null
  order by q.nk, q.eff desc;

  -- unnamed: every leasing code that means co-employment and is NOT the PEO's own
  -- internal policy (0785). Was code 2 alone; now 2, 4, 6, 7, 8. Code 1 (ordinary
  -- employers) and code 3 (PEO own staff) are excluded by that same register.
  insert into mesh_state_ledger (state, hub_slug, kind, nk, display_name, confidence, evidence_note)
  select 'TX','tx_wc','unnamed', q.nk, min(q.raw),
         case when q.code = '2' then 0.90 else 0.85 end,
         'TX WCIO leasing code '||q.code||': '||max(c.official_meaning)
  from (select distinct app.normalize_name(insured_employer_name) nk,
                        insured_employer_name raw,
                        peo_leasing_flag::text code
        from tx_wc_fingerprint_staging
        where peo_leasing_flag::text in ('2','4','6','7','8')
          and insured_employer_name not ilike '% LCF %') q
  join wcio_leasing_policy_codes c on c.code = q.code
  where q.nk is not null
  group by q.nk, q.code;
end $function$;

do $verify$
declare v_named bigint; v_unnamed bigint; v_src bigint; v_raw bigint; v_codes text[];
begin
  perform public.mesh_project_tx();

  select count(*) into v_named   from public.mesh_state_ledger where state='TX' and kind='named';
  select count(*) into v_unnamed from public.mesh_state_ledger where state='TX' and kind='unnamed';

  if v_named = 0 then
    raise exception '0787 verification: the TX named lane produced nothing after the rewrite';
  end if;
  if v_unnamed < 24269 then
    raise exception '0787 verification: the unnamed lane shrank to % (was 24,269) - the rewrite lost data', v_unnamed;
  end if;

  select array_agg(distinct substring(evidence_note from 'code ([0-9])'))
    into v_codes
  from public.mesh_state_ledger
  where state='TX' and evidence_note like 'TX WCIO leasing code%';
  if not (v_codes @> array['2','4','6','7','8']) then
    raise exception '0787 verification: harvested codes are %, expected 2,4,6,7,8', v_codes;
  end if;

  if exists (select 1 from public.mesh_state_ledger
             where state='TX' and evidence_note like 'TX WCIO leasing code 3%') then
    raise exception '0787 verification: a PEO own-policy row reached the client ledger';
  end if;
  if exists (select 1 from public.mesh_state_ledger
             where state='TX' and evidence_note like 'TX WCIO leasing code 1%') then
    raise exception '0787 verification: an ordinary non-leasing employer reached the client ledger';
  end if;

  execute (select source_count_query from public.mesh_state_adapters where state='TX') into v_src;
  select count(*) into v_raw from public.tx_wc_fingerprint_staging;
  if v_src >= v_raw then
    raise exception '0787 verification: projectable intake (%) is not narrower than raw intake (%)', v_src, v_raw;
  end if;
  if v_src < 100000 then
    raise exception '0787 verification: projectable intake collapsed to % - the filter is too tight', v_src;
  end if;

  raise notice '0787 OK: named %, unnamed %, projectable intake % of % raw rows',
    v_named, v_unnamed, v_src, v_raw;
end $verify$;