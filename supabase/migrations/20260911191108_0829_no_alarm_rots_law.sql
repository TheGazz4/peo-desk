-- CONSTITUTIONAL COMPLIANCE
-- Constitution read: YES
-- Session claim: instanceA-0826-alert-door
-- Articles implemented: XI.1 (findings are enforced, not parked), XIII.3 (every law has a check)
-- Articles verified not violated: III.1 (fences), XIV.6 (no display leakage), IX.2 (no silent loss)
-- Verification query attached: YES
--
-- NO ALARM ROTS LAW (0829)
-- The alarm list reached 1,169 unread rows over 30 days because nothing ever forced
-- anyone to answer one. An alarm could be ignored forever at no cost, so it was.
-- 0826 made repeats fold into a counter and made stopped conditions close themselves.
-- This closes the last hole: an alarm that is still unanswered after 72 hours is now
-- a failing check. Answering it means either fixing the condition or acknowledging it
-- with a written reason - silence is no longer one of the options.
--
-- This also covers every watcher that has no check of its own
-- (hub_conformance_watch, persistence_sentinel, map_ai_grounding, data_sanity_battery,
-- dol_attachment_harvest...). Their findings are now enforced through one law instead of
-- needing a bespoke mirror check each, which is why they kept falling through.

-- run the auto-close hourly so a condition that stops is closed without anyone looking
select cron.schedule('source_alerts_autoclose_hourly', '23 * * * *',
                     'select public.source_alerts_autoclose(48)');

set role peo_gatekeeper;

insert into public.sysaudit_registry
  (check_name, module, article, scope, severity, description, check_sql, expectation, selftest_sql)
values (
  'watcher_finding_unaddressed', 'mechanical', 'XI.1', 'fast', 'AMBER',
  'No alarm may sit unanswered for more than 72 hours. Answer means one of two things: the condition is fixed (and the auto-close closes it), or a person wrote down why it is acceptable (acknowledged with a reason). Silence is not an answer. This is the law that would have caught the 1,169-row backlog on day four instead of day thirty.',
  'select id, source_name, occurrences, last_seen, left(change_summary,120) as summary from public.source_alerts where not coalesce(acknowledged,false) and coalesce(last_seen, detected_at) < now() - interval ''72 hours'' order by last_seen limit 50',
  '{"mode":"zero_rows"}'::jsonb,
  'select 0::bigint as id, ''selftest''::text as source_name, 1 as occurrences, now() as last_seen, ''violating shape''::text as summary'
)
on conflict (check_name) do nothing;

reset role;

-- the three seed hubs are placeholders for seeded lists, not live feeds with a cadence.
-- Recording that decision where the conformance watcher can see it, with a review date,
-- instead of leaving a RED standing with no explanation.
insert into public.hub_contract_exemptions (hub_slug, contact_cron, reason, exempted_by, review_after)
values
 ('seed:HubSpot','(hub completeness)','PLACEHOLDER HUB, not a live feed. seed:HubSpot carries a one-time seeded list; it has a working brain (hub_brain_seed, clean hourly runs since 2026-09-11) but no upstream source to poll, so it has no cadence, no mailboxes and no medic by design. Either it gets a real upstream feed or it stops being marked live - decision due at review.','instanceA_0829','2026-10-15'),
 ('seed:miEdge','(hub completeness)','PLACEHOLDER HUB, not a live feed. Same shape as seed:HubSpot: one-time seeded list, working brain, no upstream source to poll.','instanceA_0829','2026-10-15'),
 ('seed:unknown','(hub completeness)','PLACEHOLDER HUB, not a live feed. Holding bucket for seeded rows with no identified origin. No upstream source exists to give it a cadence; the real work is identifying the origin of those rows.','instanceA_0829','2026-10-15')
on conflict do nothing;