-- ===== 0899_no_play_is_minted_on_a_company_that_is_not_a_peo_user =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0899-no-play-on-a-non-peo-user (opened BEFORE apply)
-- Articles implemented: II.3, book_perspective_law (0898), the standing PEP ruling, the noncompete fence,
--   fix-at-the-core all three levels
-- Articles verified not violated: III.1, XIII.1, switch_detection_nightly hold, outbound parked
-- Verification query attached: YES
--
-- Audited 0898. The census named the classes; nothing was USING them. What the play layer sits on:
--
--   record class            angles  companies
--   peo_user                18,287     14,603   correct
--   peo_claimed_unverified      60         60   a source claimed a PEO we cannot name
--   reference                   22         22   NO PEO SIGNAL AT ALL
--   peo_user_unnamed             3          3   and these are the bad ones
--   former_peo_user              1          1   correct - a former user is a real prospect
--
-- THE THREE. All LIVE, all proven_switcher, all minted 2026-08-16, all attribution_class 'pep_participant':
-- TVG-MEDULLA LLC, NATIONAL ASSOCIATION OF PROFES, STRICKBINE PUBLISHING INC. A PEP participant is in a
-- Paychex retirement plan, not a PEO. There is a STANDING RULING that PEP participants are never promoted
-- as PEO clients, and we minted \"proven switcher\" plays on three of them and left them live for four
-- weeks - the ruling broken in the one place it actually reaches a customer.
--
-- THE TWENTY-TWO sit on roster_direct_parentage rows with no PEO attribution of any kind.
-- THE SIXTY are acquired_book on claimed_source: \"your PEO's book was acquired\", where we cannot say which
-- PEO. That claim is unsupportable without naming it.
--
-- TARGETABILITY IS NARROWER THAN RECORD CLASS, so this does not reuse 0898's classes bluntly.
-- lcf_verified, fingerprint_verified, insperity_corroborated and verified_switcher are verified PEO users
-- whose PEO happens to be unnamed - perfectly good targets. The refusals are each for their own reason:
--   noncompete_quarantined  - the fence (Helpside / A Plus / AAA / Lever1 / High Road / PEO Spectrum)
--   pep_participant         - the standing ruling. Not a PEO client.
--   peo_entity_suppressed   - the company IS a PEO entity, not somebody's client.
--   reference               - no PEO signal at all.
--   peo_claimed_unverified  - a claim we cannot name, so no claim can be made about it.
--
-- FIRST APPLY FAILED: company_angles_status_check allows only live/stale/used/retired. The retirement is
-- status='retired' with the reason written into the evidence jsonb, so the audit trail survives.

create or replace function public.company_targetable(p_company_id uuid)
returns boolean language sql stable set search_path to 'public','pg_catalog' as $f$
  select exists (
    select 1 from companies c
     where c.id = p_company_id
       and c.merged_into is null
       and coalesce(c.attribution_class,'') not in
           ('noncompete_quarantined','pep_participant','peo_entity_suppressed')
       and (c.peo_family_slug is not null
            or c.peo_prior_family_slug is not null
            or (c.peo_user_status = 'current_peo_user'
                and c.attribution_class in ('lcf_verified','fingerprint_verified',
                                            'insperity_corroborated','verified_switcher')))
  );
$f$;
comment on function public.company_targetable(uuid) is
  'May a play be minted on this company. Requires a PEO we can name, a former PEO, or a verified current user - and refuses the noncompete fence, Paychex PEP participants (standing ruling: never promoted as PEO clients), PEO entities themselves, reference rows with no PEO signal, and unverifiable claims. Narrower than company_record_class: lcf_verified and fingerprint_verified users are unnamed but targetable.';
revoke execute on function public.company_targetable(uuid) from public, anon;
grant execute on function public.company_targetable(uuid) to service_role, postgres, peo_gatekeeper, sysaudit_reader;

-- LEVEL 2: retire what is already minted. DELETE is revoked platform-wide, so they are marked.
update public.company_angles a
   set status = 'retired',
       evidence = coalesce(a.evidence, '{}'::jsonb) || jsonb_build_object(
         'retired_reason', 'not a targetable PEO user (0899)',
         'retired_detail', (select 'attribution_class=' || coalesce(c.attribution_class,'(none)')
                                   || ' record_class=' || public.company_record_class(c.peo_family_slug,
                                        c.peo_prior_family_slug, c.peo_user_status, c.attribution_class)
                              from companies c where c.id = a.company_id),
         'retired_at', now()::text)
 where a.status <> 'retired'
   and not public.company_targetable(a.company_id);

-- LEVEL 1: the door. A refused mint is dropped and logged rather than raised, so a bulk mint run cannot
-- explode - the same shape as the companies admission gate.
create or replace function public.trg_company_angle_targetable()
returns trigger language plpgsql security definer set search_path to 'public','pg_temp' as $f$
declare v_class text; v_attr text;
begin
  if not public.company_targetable(new.company_id) then
    select c.attribution_class,
           public.company_record_class(c.peo_family_slug, c.peo_prior_family_slug,
                                       c.peo_user_status, c.attribution_class)
      into v_attr, v_class
      from companies c where c.id = new.company_id;

    insert into source_alerts (source_name, change_summary, acknowledged)
    values ('company_angles',
      format('PLAY REFUSED — %s angle on company %s: record_class=%s attribution_class=%s. Not a targetable PEO user.',
             new.angle_type, new.company_id, coalesce(v_class,'?'), coalesce(v_attr,'(none)')), false);
    return null;
  end if;
  return new;
end $f$;
revoke execute on function public.trg_company_angle_targetable() from public, anon;

drop trigger if exists company_angles_targetable_gate on public.company_angles;
create trigger company_angles_targetable_gate
  before insert on public.company_angles
  for each row execute function public.trg_company_angle_targetable();

set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('no_live_play_on_a_non_peo_user', 'mesh_law', 'fast', 'II.3', 'RED',
 'No live play may sit on a company that is not a targetable PEO user. On 2026-09-12 three LIVE proven_switcher plays had been sitting on Paychex PEP participants since 2026-08-16 - a direct breach of the standing ruling that PEP participants are never promoted as PEO clients - plus 22 on companies with no PEO signal at all and 60 acquired_book claims about a PEO we cannot name. The census named the record classes in 0898; nothing was using them.',
 'select a.angle_type, c.attribution_class, count(*)::bigint as n from public.company_angles a join public.companies c on c.id = a.company_id where a.status <> ''retired'' and not public.company_targetable(a.company_id) group by 1,2 limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as angle_type, ''y''::text as attribution_class, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('play_targetability_gate_armed', 'mesh_law', 'fast', 'II.3', 'RED',
 'The company_angles targetability trigger must exist and be enabled. Without it a mint run can put a play back onto a noncompete-fenced client, a Paychex PEP participant, or a reference row with no PEO at all - which is exactly what had happened before it existed.',
 'select ''company_angles_targetable_gate''::text as missing where not exists (select 1 from pg_trigger g where g.tgname = ''company_angles_targetable_gate'' and not g.tgisinternal and g.tgenabled <> ''D'')',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as missing',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

-- VERIFICATION
select (select count(*) from public.company_angles a
          where a.status <> 'retired' and not public.company_targetable(a.company_id)) as live_bad_plays,
       (select count(*) from public.company_angles
          where evidence->>'retired_reason' = 'not a targetable PEO user (0899)') as retired_here,
       (select count(*) from public.company_angles a join public.companies c on c.id=a.company_id
          where a.status <> 'retired' and c.attribution_class='pep_participant') as live_pep_plays,
       (select count(*) from public.company_angles a join public.companies c on c.id=a.company_id
          where a.status <> 'retired' and c.attribution_class='noncompete_quarantined') as live_fenced_plays;"}

-- ===== 0900_a_merged_company_is_not_a_non_peo_user_repoint_do_not_retire =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0899-no-play-on-a-non-peo-user
-- Articles implemented: II.3, CANONICAL RESOLUTION (a merge repoints, it does not destroy),
--   fix-at-the-core, honest labelling
-- Articles verified not violated: III.1, XIII.1, noncompete fence, PEP ruling
-- Verification query attached: YES
--
-- I OVER-RETIRED IN 0899. I predicted 85 plays would be retired and 786 were. The difference is 686 plays
-- sitting on companies that had been MERGED AWAY - company_targetable() returns false for a merged row,
-- correctly for a NEW mint, but \"not a targetable PEO user\" is the wrong reason and retiring was the wrong
-- action. A merged company is not a non-PEO user; it is a duplicate that was resolved. Every one of those
-- 686 survivors IS targetable. I would have thrown away 686 real plays under a false label, and the
-- verification query I wrote would still have said zero, because it only counted what was left.
--
-- Caught it by asking why the number was ten times my prediction instead of accepting a green result.
--
-- RESTORING TO 'live' IS SAFE AND CHECKED: immediately before 0899 the only statuses in the table were
-- live (18,714) and retired (371), and the 0899 update excluded rows already retired - so everything it
-- touched was live. I did not preserve the prior status in 0899; that was the second mistake, and the only
-- reason this is recoverable is the count I happened to take first.
--
-- FIRST APPLY OF THIS MIGRATION ALSO FAILED, on the unique key (company_id, angle_type): TWO merged
-- duplicates can point at the SAME survivor with the same angle type. My collision test only looked at
-- rows already on the survivor, not at the batch colliding with itself. Fixed with distinct on
-- (survivor, angle_type), keeping the highest-confidence then newest play and retiring the rest.

-- 1. REPOINT what can move - one play per (survivor, angle_type), best first.
with movable as (
  select distinct on (c.merged_into, a.angle_type)
         a.id, c.merged_into as survivor
    from company_angles a
    join companies c on c.id = a.company_id
   where a.evidence->>'retired_reason' = 'not a targetable PEO user (0899)'
     and c.merged_into is not null
     and not exists (select 1 from company_angles a2
                      where a2.company_id = c.merged_into and a2.angle_type = a.angle_type)
   order by c.merged_into, a.angle_type, a.confidence desc nulls last, a.created_at desc
)
update company_angles a
   set company_id = m.survivor,
       status = 'live',
       evidence = (a.evidence - 'retired_reason' - 'retired_detail' - 'retired_at')
                  || jsonb_build_object('repointed_from', a.company_id::text,
                                        'repointed_reason', 'company merged away; play follows the survivor (0900)',
                                        'repointed_at', now()::text)
  from movable m
 where a.id = m.id;

-- 2. Everything still sitting on a merged row keeps an honest label - the merge either already carried
--    the play across, or a better-evidenced duplicate won the repoint.
update company_angles a
   set evidence = (a.evidence - 'retired_detail')
                  || jsonb_build_object('retired_reason',
                       'company merged away; the surviving company already carries this angle type (0900)')
  from companies c
 where c.id = a.company_id
   and c.merged_into is not null
   and a.evidence->>'retired_reason' = 'not a targetable PEO user (0899)';

set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('live_play_on_merged_company', 'mesh_law', 'fast', 'II.3', 'AMBER',
 'A live play must not point at a company that has been merged away - it should follow the survivor. 686 were found on 2026-09-12. Deliberately NOT folded into no_live_play_on_a_non_peo_user: a merged company is a resolved duplicate, not a non-PEO user, and the remedy is to repoint the play, never to retire it. Conflating the two nearly destroyed 686 real plays under a false label.',
 'select a.angle_type, count(*)::bigint as n from public.company_angles a join public.companies c on c.id = a.company_id where a.status <> ''retired'' and c.merged_into is not null group by 1 limit 100',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as angle_type, 1::bigint as n',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

update public.sysaudit_registry
   set check_sql = 'select a.angle_type, c.attribution_class, count(*)::bigint as n from public.company_angles a join public.companies c on c.id = a.company_id where a.status <> ''retired'' and c.merged_into is null and not public.company_targetable(a.company_id) group by 1,2 limit 200'
 where check_name = 'no_live_play_on_a_non_peo_user';

reset role;

-- VERIFICATION
select (select count(*) from company_angles where evidence ? 'repointed_from') as repointed,
       (select count(*) from company_angles
         where evidence->>'retired_reason' like '%surviving company already carries%') as retired_as_duplicate,
       (select count(*) from company_angles
         where evidence->>'retired_reason' = 'not a targetable PEO user (0899)') as retired_genuinely,
       (select count(*) from company_angles a join companies c on c.id=a.company_id
         where a.status <> 'retired' and c.merged_into is not null) as live_on_merged_left,
       (select count(*) from company_angles a join companies c on c.id=a.company_id
         where a.status <> 'retired' and c.merged_into is null and not public.company_targetable(a.company_id)) as live_bad_left,
       (select count(*) from company_angles where status='live') as live_total;"}

-- ===== 0901_the_send_list_stops_offering_merged_duplicates_and_fenced_clients =====
{"-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0899-no-play-on-a-non-peo-user
-- Articles implemented: II.3, CANONICAL RESOLUTION, the noncompete fence, the standing PEP ruling,
--   book_perspective_law, fix-at-the-core level 3 (the surface that reaches a customer)
-- Articles verified not violated: III.1, XIII.1, outbound remains parked
-- Verification query attached: YES
--
-- Third pass. The plays were fixed in 0899/0900; the SEND list is the surface that actually reaches a
-- customer, so I checked it too. 127 of the 38,378 send-eligible rows are not targetable.
--
-- They are all MERGED-AWAY DUPLICATES - ADP TotalSource 55+, Insperity, TriNet, ExtensisHR, Justworks and
-- Paychex clients that were merged into a surviving record. And it is not a stale materialized view:
-- v_send_eligibility has no merged_into filter at all. It hard-blocks on the noncompete fence, the
-- suppression list, location stubs, family verdict and a score - and never once asks whether the company
-- row is still the live one. So the outbound lane would have offered a duplicate instead of the survivor,
-- and every suppression and fence decision recorded against the SURVIVOR would have been bypassed by
-- sending to its shadow.
--
-- Outbound is parked, so nothing was sent. That is luck, not design.
--
-- The block is written inline rather than as a company_targetable() call per row: same rule, no function
-- call across 38k rows, and it shows up in score_breakdown.hard_blocks so the desk can see WHY a record
-- is not offered instead of it silently vanishing.

create or replace view public.v_send_eligibility as
 WITH cfg AS (
         SELECT send_worthiness_config.id,
            send_worthiness_config.min_record_score,
            send_worthiness_config.w_attribution,
            send_worthiness_config.w_family_confidence,
            send_worthiness_config.w_family_robustness,
            send_worthiness_config.w_freshness,
            send_worthiness_config.updated_at,
            send_worthiness_config.updated_by
           FROM send_worthiness_config
          WHERE send_worthiness_config.id = 1
        ), rec AS (
         SELECT cc.company_id,
            cc.legal_name,
            cc.peo_family_slug,
            cc.wc_renewal_month,
            cc.attribution_confidence,
            cc.noncompete_blocked,
            cc.is_location_stub,
            p.robustness_score,
            p.confidence_score,
            p.send_worthiness ->> 'verdict'::text AS family_verdict,
            ( SELECT max(m.last_evidence_seen) AS max
                   FROM tx_lcf_matches m
                  WHERE m.company_id = cc.company_id) AS last_evidence_seen,
            (EXISTS ( SELECT 1
                   FROM suppression s
                  WHERE s.company_id = cc.company_id)) AS is_suppressed,
            -- 0901: is this still the live, targetable record?
            (co.id is not null
             and co.merged_into is null
             and coalesce(co.attribution_class,'') not in
                 ('noncompete_quarantined','pep_participant','peo_entity_suppressed')) AS is_targetable_record
           FROM v_company_confidence cc
             LEFT JOIN peo_profiles p ON p.family_slug = cc.peo_family_slug
             LEFT JOIN companies co ON co.id = cc.company_id
        )
 SELECT r.company_id,
    r.legal_name,
    r.peo_family_slug,
    r.wc_renewal_month,
    r.attribution_confidence,
    r.noncompete_blocked,
    r.is_location_stub,
    r.robustness_score,
    r.confidence_score,
    r.family_verdict,
    r.last_evidence_seen,
    round(COALESCE(r.attribution_confidence, 0::numeric) * cfg.w_attribution + COALESCE(r.confidence_score, 0::numeric) / 100.0 * cfg.w_family_confidence + COALESCE(r.robustness_score, 0::numeric) / 100.0 * cfg.w_family_robustness + evidence_effective_confidence('tx_wc_filing'::text, 1.0, COALESCE(r.last_evidence_seen, CURRENT_DATE - 365)) * cfg.w_freshness, 1) AS record_send_score,
    cfg.min_record_score,
    r.is_targetable_record
      AND NOT COALESCE(r.noncompete_blocked, false) AND NOT r.is_suppressed AND NOT COALESCE(r.is_location_stub, false)
      AND (COALESCE(r.family_verdict, 'hold'::text) = ANY (ARRAY['cleared_specific'::text, 'cleared_generic'::text]))
      AND (COALESCE(r.attribution_confidence, 0::numeric) * cfg.w_attribution + COALESCE(r.confidence_score, 0::numeric) / 100.0 * cfg.w_family_confidence + COALESCE(r.robustness_score, 0::numeric) / 100.0 * cfg.w_family_robustness + evidence_effective_confidence('tx_wc_filing'::text, 1.0, COALESCE(r.last_evidence_seen, CURRENT_DATE - 365)) * cfg.w_freshness) >= cfg.min_record_score AS send_eligible,
    r.is_suppressed,
    jsonb_build_object('attribution', round(COALESCE(r.attribution_confidence, 0::numeric) * cfg.w_attribution, 1), 'family_confidence', round(COALESCE(r.confidence_score, 0::numeric) / 100.0 * cfg.w_family_confidence, 1), 'family_robustness', round(COALESCE(r.robustness_score, 0::numeric) / 100.0 * cfg.w_family_robustness, 1), 'freshness', round(evidence_effective_confidence('tx_wc_filing'::text, 1.0, COALESCE(r.last_evidence_seen, CURRENT_DATE - 365)) * cfg.w_freshness, 1), 'family_verdict', r.family_verdict, 'hard_blocks', jsonb_build_object('noncompete_blocked', COALESCE(r.noncompete_blocked, false), 'on_suppression_list', r.is_suppressed, 'location_stub', COALESCE(r.is_location_stub, false), 'not_targetable_record', NOT r.is_targetable_record, 'family_not_cleared', COALESCE(r.family_verdict, 'hold'::text) <> ALL (ARRAY['cleared_specific'::text, 'cleared_generic'::text]))) AS score_breakdown
   FROM rec r
     CROSS JOIN cfg;

refresh materialized view public.mv_send_eligible;

set role peo_gatekeeper;

insert into public.sysaudit_registry (check_name, module, scope, article, severity, description, check_sql, expectation, selftest_sql, enabled, created_by)
values ('send_list_offers_only_live_targetable_records', 'mesh_law', 'fast', 'II.3', 'RED',
 'The send-eligible list must contain only live, targetable company records. On 2026-09-12 it held 127 merged-away duplicates - ADP TotalSource, Insperity, TriNet, ExtensisHR, Justworks and Paychex clients - because v_send_eligibility had no merged_into filter at all. Sending to a duplicate bypasses every suppression and fence decision recorded against the survivor. Outbound was parked, so nothing went out; that was luck, not design.',
 'select m.company_id::text as company_id, m.peo_family_slug from public.mv_send_eligible m where not public.company_targetable(m.company_id) limit 200',
 '{\"mode\":\"zero_rows\"}'::jsonb,
 'select ''x''::text as company_id, ''y''::text as peo_family_slug',
 true, 'peo_gatekeeper')
on conflict (check_name) do update set check_sql=excluded.check_sql, description=excluded.description,
  selftest_sql=excluded.selftest_sql, enabled=true;

reset role;

-- VERIFICATION
select (select count(*) from public.mv_send_eligible) as send_eligible_now,
       (select count(*) from public.mv_send_eligible m where not public.company_targetable(m.company_id)) as not_targetable_left,
       (select count(*) from public.mv_send_eligible m join public.companies c on c.id=m.company_id
          where c.merged_into is not null) as merged_left,
       (select count(*) from public.v_send_eligibility where send_eligible) as view_agrees;"}
