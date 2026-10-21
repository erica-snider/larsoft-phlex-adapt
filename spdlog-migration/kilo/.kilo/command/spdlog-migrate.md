---
description: Run the messagefacility -> spdlog per-package/per-file migration workflow for larcoreobj, larcorealg, lardataobj, lardataalg
---

You are executing the messagefacility → spdlog migration workflow.

`{TARGET}` for this invocation is: $ARGUMENTS

If `{TARGET}` is empty, stop and ask the user which package or file set to run against
(one of: `larcoreobj`, `larcorealg`, `lardataobj`, `lardataalg`, or an explicit file list).

## Source documents (always read fresh — do not rely on any cached summary)

- @larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/PROCEDURE.md
- @larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/PATTERN_CATALOG.md
- @larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/OPEN_QUESTION_ANSWERS.md
- @larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/F4_GUARDRAILS_PLAN.md
- @larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/BUILDING_WITH_SPACK_MPD.md

Do **not** consult any `larcorealg/*_PLAN_*.md` document or
`SPDLOG_MIGRATION_STAGING_STEPS.md`. If executing this workflow ever seems to require
information from one of those, stop and report that instead of reading it.

## Guard rail scripts (F4, implemented — see F4_GUARDRAILS_PLAN.md)

All under `larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/guardrails/`:

- `env.sh` — **source** (not execute) this first for any command that runs a
  build or test binary: `source guardrails/env.sh && spack env activate <path to mpddev/local>`.
  See `BUILDING_WITH_SPACK_MPD.md`.
- `grep-gate.sh [path ...]` — G1. Fails if `mf::`/`MF_LOG_`/`messagefacility`
  reappears. Standing allowlist applied automatically.
- `format-string-lint.sh [path ...]` / `--self-test` — G2. Fails on a non-literal
  `spdlog::` format argument. `--self-test` is the required two-sided acceptance.
- `gen-targets.sh [--check]` — G3.1. Regenerates `targets.tsv`, the
  source→test manifest, from the live ninja/ctest build graph. Run this
  whenever the build tree changes (new test, new file) — it is what makes the
  harness apply to a NEW file with no manual re-mapping.
- `outdiff.sh {baseline|check|levels|report} <test|--all-mf>` — G3.3/G3.4. The
  before/after output-diff harness and the level-vanish check.
- `normalize.sed` — the calibrated normalization rules `outdiff.sh` applies;
  read its header comments before trusting an unexplained diff.

Use these to make F4/GATE B checks concrete instead of asserted:
- F4 check command: `grep-gate.sh && format-string-lint.sh --self-test && gen-targets.sh && outdiff.sh baseline --all-mf && outdiff.sh check --all-mf`
- GATE B step 1: `outdiff.sh check <test>` (or `check --all-mf`)
- GATE B step 2: `outdiff.sh levels <test>` (note its documented limitation once
  a test is fully migrated to bare `%v` — treat step 1 as authoritative then)
- GATE B step 7: `grep-gate.sh`

## Precedence (apply at every decision point)

1. File-specific override in `OPEN_QUESTION_ANSWERS.md` §2 (only if the current file/site
   is named there).
2. General-decision override in `OPEN_QUESTION_ANSWERS.md` §2 (applies to every package).
3. Default answer in `OPEN_QUESTION_ANSWERS.md` §1 (resolves `PATTERN_CATALOG.md` §8 rows).
4. `PATTERN_CATALOG.md` default pattern/mitigation.
5. `PROCEDURE.md` skeleton default.

Known resolved values from §1/§2 (verify against the live files above, this is a summary
not a substitute for reading them):
- Output pattern: bare `%v`, no timestamp.
- Header home: `larcoreobj/larcoreobj/LoggingUtil/Logging.h`.
- File destinations from old config: keep as a second sink.
- Deprecation window for renamed public init functions: break immediately.
- No end-of-job spdlog statistics accumulated (drop the statistics sub-key permanently,
  emit one warning naming what was ignored — not a TODO).
- Per-file hot-path overrides: `lardataobj/lardataobj/RecoBase/Event.cxx` (leave as-is),
  `lardataobj/lardataobj/RawData/raw.cxx` (function-local one-count guard, once per
  vector/waveform/wire), `larcorealg/larcorealg/TestUtils/unit_test_base.h` (leave as-is),
  `GeometryBadIntPoint` in `larcorealg/larcorealg/Geometry/GeometryCore.cxx` (leave as-is).

## Part I — Foundation preconditions (F0–F5)

Verify, never create. For `{TARGET}`'s package, check each of F0 (decisions file
complete), F1 (`find_package(spdlog)` succeeds; record version, compiled-vs-header-only,
bundled fmt version, presence of `spdlog/mdc.h`), F2 (logging header exists at the
resolved home and contains every required element from `PROCEDURE.md`), F3 (foundation
test green, no production file touched yet), F4 (grep gate, format-string lint,
output-diff harness all runnable), F5 (package migration order fixed — `larcoreobj`
first, then verify the real dependency graph for the rest; do not assume).

**Stop after this step and report status of F0–F5 explicitly. Wait for approval before
continuing.**

## Part II — Per-package/per-file-set loop

Run every step below in order. **Stop after each individual step and wait for explicit
user approval before starting the next one** — this is a hard requirement of this
workflow, not a suggestion, regardless of how mechanical the step looks.

1. **P0 — Precondition gate.** Re-verify F0–F5 for `{TARGET}`. Abort with the specific
   failing item if anything regressed; do not repair automatically. **Stop for approval.**
2. **P1 — Inventory.** Enumerate every mf call site, include, CMake reference, and config
   block in `{TARGET}`. Separate live sites from dead includes / commented-out sites.
   Output counts by API form, file list, CMake/config references.
   **Before stopping for approval, capture output baselines for every test this
   set can affect** (irreversible once source is migrated — see F4_GUARDRAILS_PLAN.md
   finding 6): run `guardrails/gen-targets.sh` then
   `guardrails/outdiff.sh baseline --all-mf` (or `baseline <test>` for a
   narrower target), sourcing `guardrails/env.sh` first. Report which tests
   were baselined. **Stop for approval.**
3. **P2 — Classify.** Place every live site into a `PATTERN_CATALOG.md` §2 form. Scan for
   every hazard listed in `PROCEDURE.md`'s P2 (iomanip, ostream-only ADL concentration,
   hot-path sites, threshold-dependent trace/debug, public-header log calls,
   assertion-reporter logging, stale logger comments, persisted-data-product headers,
   generic-helper narrowing risk). For hot-path mitigation, apply the precedence order
   above (file-specific override first, then §4.1's ranked menu: one-shot → counter →
   demote). Produce the classification report. **If any site fits no §2 form, stop
   immediately and surface it — do not guess a mapping, do not proceed even with
   approval until the catalog is extended.** Otherwise, **stop for approval.**
4. **P3 — Order the work.** Dependency order first, then difficulty; mechanical bulk
   before hard sites; files that unblock running tests first. **Stop for approval.**
5. **GATE A — Smoke test.** Migrate exactly one site exercising the hardest pattern
   actually present (prefer ostream-only ADL, else stored-by-value). Compile in the real
   build, not a reduction. **If this fails, stop the entire run** — the foundation needs
   work, not the call sites. **Stop for approval either way before any bulk edit.**
6. **P4 — Edit.** A file is migrated **all at once or not at all** — there is no safe
   stopping point inside a file, because a half-converted file does not compile. Do not
   pause, build, commit, or report in the middle of one.

   Per file, in P3 order: (a) enumerate every live site in the file and write the list
   down first — that list is the definition of done; (b) add the new include *alongside*
   the old one (add new first, remove old last, so the file compiles throughout);
   (c) convert **every** site on the list — level mapping (§2.1), drop category args and
   manual class/method prefixes (§2.2), form-specific transform from §2, preserving
   load-bearing braces (§2.3), not restructuring control flow, not narrowing generic
   helpers (§2.6); (d) add hot-path guards per the resolved P2 report; (e) delete stale
   logger comments (§5.3) and context-singlet/iteration calls (§2.8) if `spdlog/mdc.h`
   is absent; (f) **run the single-file close-out check and require exit 0**:

   ```
   larsoft3/mpdtest/mpddev/srcs/larcorealg/spdlog-migration/guardrails/grep-gate.sh <file>
   ```

   Exit 1 means the file is **still mid-edit** no matter how complete it feels — go back
   to (c) and convert what it names. Only after exit 0, remove the messagefacility
   include (and, for a dead-include-only file, §5.4); (g) build the file's target.

   **Do not report a file as done, and do not stop for approval, until (f) exits 0 and
   (g) compiles.** A file that fails either is unfinished work in progress, not a
   completed step awaiting review. No regex/`sed` bulk rewrite. One file per commit.
   **Stop for approval after each completed file** (or an explicitly pre-approved batch).
7. **P5 — Build system.** Drop the mf link per target, noting original visibility;
   add the logging dependency with the same visibility; remove `EXPORT`ed
   `find_package` last; translate config blocks per §4.5 with the resolved overrides
   (second sink kept, statistics summary dropped permanently with one warning).
   **Stop for approval.**
8. **P6 — Build and test.** Confirm package builds/links with no mf reference and
   existing tests pass. Partial-tree builds (mf + spdlog coexisting) are expected.
   **Stop for approval.**
9. **GATE B — Verification.** Run all seven applicable checks from `PROCEDURE.md`
   using the guard rail scripts above: `outdiff.sh check` (output diff),
   `outdiff.sh levels` (level check), manual exercise for hot-path/assertion-
   reporter/dual-entry-point/serialization checks where applicable, `grep-gate.sh`
   (grep sweep). Present all seven results explicitly; do not report green on
   partial evidence. **Stop for approval.**
10. **P7 — Report.** Sites migrated by form; guards added and their source (file-specific
    override vs. §4.1 default); capabilities lost (explicitly note the permanent
    statistics-summary loss); interface changes needing downstream announcement; observed
    but unfixed pre-existing defects; any new catalog gap. **Stop — final sign-off for
    `{TARGET}`.**

## Re-running for a new file or package

Re-invoke this same command with a new `{TARGET}` (e.g. `/spdlog-migrate lardataalg` or
`/spdlog-migrate lardataobj/lardataobj/RawData/raw.cxx`). Nothing else changes. If P2
surfaces a new hot-path decision not covered by the default menu, add it to
`OPEN_QUESTION_ANSWERS.md` §2 as a new row before finalizing that run, rather than
special-casing this command.
