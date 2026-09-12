// peo-identity-check v1 (2026-09-12, claim instanceA-0880-nonpeo-sweep)
// TIER 2 of the non-PEO sweep. One question per family: is this a PEO / co-employer, or is it something else
// (staffing agency, insurance broker, payroll bureau, software vendor, ordinary operating company)?
// Free mesh evidence - sworn Schedule MEP box 1b, IRS CPEO list, state PEO licence - is checked in SQL first.
// Only families the mesh is silent on ever reach this paid lane.
//   1 Serper search (query ladder) + 1 Haiku grading -> {peo | not_a_peo | unknown} + confidence.
// Gates: serper_budget_ok() and brain_spend_ok() BEFORE any paid call (no-blind-spender law 0807/0808).
// Cost booked through log_brain_spend (one priced door); a failed ledger write goes to edge_debug, never swallowed.
// Serper credits booked through serper_budget_spend. Caps live in SQL (15 queued, 5 per batch).
// A verdict REMOVES NOTHING. peo_identity_check_promote() is a separate explicit call at 0.80+.
// Full source is deployed as peo-identity-check v1; see supabase_migrations 0883_peo_identity_check_lane
// for the queue, next, apply, error and promote functions this calls.
SHA256 of deployed bundle: 1a880233952a452ac4b6f594ffd7f95a3f96525d237b6325da5cd7d460320469