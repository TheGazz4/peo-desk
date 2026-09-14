# Two finds: the Florida licence register, and PEOs naming themselves in the filing

**Date:** 2026-09-14 · **Instance:** mesh · **Migrations:** 2096, 2097, 2098, 2099
**Follows:** claude/fl-book-attribution-engine-2026-09-13.md, claude/fl-identity-lanes-and-growth-2026-09-13.md

## Find 1 — an authoritative FL PEO register was sitting raw and wired to nothing

`fl_dbpr_licensees_raw` holds Florida DBPR **licence type 63 — Employee Leasing Company**. Two
snapshots (2026-08-17, 2026-09-01), 1,104 rows each, parsed into nothing.

This is the state''s own answer to "is this entity a licensed Florida PEO", and it was idle while a
queue of 40 unresolvable book names waited on external research.

Parsed into `fl_peo_licenses`: **766 licensed entities** (classes EL/GL/GM/DM/DS/DL; the CO
controlling-officer and SH shareholder rows are people and are excluded).

Adjudicating the 40 gap names against it, with no external research:

| Verdict | Names | Books | Clients |
|---|---|---|---|
| Licensed Florida PEO — safe to register the alias | **6** | 11 | 224 |
| Not FL-licensed — research before registering | 34 | 66 | 2,182 |

The 34 are staffing firms (ASR Staffing, Adelphi Medical Staffing, All Purpose Staffing…), not PEOs.
Under the PEO-broker law a staffing name is not evidence of a PEO, and now there is a register to
prove it rather than an opinion.

**Bigger than the gap queue: 486 of the 766 licensed entities have no canonical slug in the platform
at all** — 485 currently valid, 194 already present in the company spine under some name. That is a
competitor-discovery list from a state register. Exposed as `v_fl_licensed_peo_discovery`.

## Find 2 — the filing names the PEO, and nobody had split the string

338 FL rows across 146 policies concatenate the PEO and the client into one `employer_name`:

- `ALLY HR III LLC FLWT IKASH LLC`
- `AYS EMPLOYEE LEASING INC FWLT ULTIMATE HOME REPAIRS LLC`
- `ASCEND HR INC LWF IPERIONX CRITICAL MINERALS LLC`

Separators seen: `FLWT`, `FWLT`, `LWF`, `LCF`. Two things were lost because nobody split it:

1. **The strongest attribution evidence available** — the source document naming the PEO — was
   invisible to every lane.
2. **The client half was unusable as an identity key**, so those clients could never be married and
   could never vote.

Validation before building: **131 books declare a PEO this way. 131 of 131 unanimous. ZERO
conflicting declarations. ZERO disagreements with books already named by the vote or fingerprint
lanes.** Perfect agreement with independent evidence is what earns this lane rank 0 and 0.95.

`fl_leasing_peo_part()` / `fl_client_name()` do the split; names without a separator pass through
unchanged, so nothing else moves.

**Caveat recorded, not hidden:** 0.95 is granted even on a single declaring row. The evidence is a
source document naming the PEO for that policy, and measured error is zero — but a typo in the
source would win uncontested on a one-row book. Worth a confidence tier if error ever appears.

## Result of this pass

| | Before this pass | After |
|---|---|---|
| Books named >=0.7 | 749 | **898** |
| Clients on named books | 142,908 | **153,615** |
| Two-sided FL switches visible | 6,772 | **8,722 across 7,518 employers** |
| Identities resolved | 30,479 | **38,996** |
| Unresolvable book names | 40 | **37 (6 now provably licensed PEOs)** |

Named by lane this run: 123 by declaration, 5 by vote, 2 by fingerprint. Second pass converged.

Audit: 3,663 decision rows against 3,663 eligible books (exact), 0 named without a slug,
0 non-compete, 0 protected-source overwrites, 0 odd confidences, 0 declared-vs-vote conflicts.

## Lane ladder as it now stands

| Rung | Lane | Confidence | Basis |
|---|---|---|---|
| 0 | `self_declared` | 0.95 | the FL filing names the PEO in the employer string |
| — | vote + fingerprint | 0.90 | >=3 clients agree AND the carrier signature agrees |
| — | vote | 0.80 | >=3 distinctive clients, >=75% dominance |
| — | fingerprint | 0.75 | exclusive carrier+agency+anchor, non-multi-PEO agency, uncontradicted |
| 1 | `ein` (identity) | dormant | FL carries no EINs — 0 of 302,817 rows |
| 2 | `name_address` (identity) | live | name + building key + state + zip |
| 3 | `unique_name` (identity) | live | the pre-existing FL marriage bridge |

## Still open

- **37 unregistered names** (2,182 clients) — now known NOT to be FL-licensed PEOs. Registering them
  as PEO families would be wrong; they likely belong in the non-PEO gate another instance owns.
- **486 licensed FL PEOs with no alias** — needs a ruling on whether to admit them to
  `peo_families` from a state licence register alone.
- **101 two-vote books** — would clear at a threshold of 2 instead of 3. Owner ruling.
- **No switches minted.** Ruling #48 still open.

## Objects added

- Table `fl_peo_licenses` (gatekeeper, RLS on) + `fl_refresh_peo_licenses()` + `fl_is_licensed_peo()`
- Functions `fl_leasing_peo_part()`, `fl_client_name()`
- Views `v_fl_book_declared`, `v_fl_book_alias_gap_triage`, `v_fl_licensed_peo_discovery`
- `v_fl_book_votes` re-keyed onto the client half of the name
- `fl_name_books_cycle()` now runs licences -> slugs -> identity -> naming, one job, 07:13 UTC
