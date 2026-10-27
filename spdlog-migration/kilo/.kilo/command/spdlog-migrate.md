---
description: Run the messagefacility -> spdlog migration workflow on a target directory inside an mpd project srcs tree
---

You are executing the messagefacility → spdlog migration workflow.

`{TARGET}` for this invocation is: $ARGUMENTS

## 0. Establish context FIRST (before reading anything else)

This command is invoked from inside an **mpd project `srcs` directory**, and
`{TARGET}` is a path **relative to that `srcs` directory** (e.g. `larcorealg`,
`lardataobj/lardataobj/RawData`, or `larcorealg/larcorealg/Geometry/PlaneGeo.cxx`).
An absolute path is also accepted.

Run this first and report what it prints:

```
$MIGRATION/guardrails/mpd-paths.sh --check
```

where `$MIGRATION` is the directory containing this tooling (the
`spdlog-migration` directory in the `larsoft-phlex-adapt` repo; this command file
lives at `$MIGRATION/kilo/.kilo/command/spdlog-migrate.md`, so `$MIGRATION` is three
levels above it). It prints the discovered mpd project root, `srcs`, `build`,
`local`, and the tooling paths.

**Everything depends on this being right.** More than one mpd project can exist
side by side with identical layouts (e.g. `mpddev`, `larsoftobj`), and they are at
different migration stages. If the reported project is not the one you intend,
**stop** and ask; do not proceed. `MPD_PROJECT=<name|abs path>` overrides discovery.

If `{TARGET}` is empty, stop and ask which directory or file set to run against.
Do not default to a package.

Resolve `{TARGET}` to an absolute path under the discovered `srcs` and report it.
If it does not exist there, stop and say so.

## Source documents (always read fresh — do not rely on any cached summary)

All paths below are relative to `$MIGRATION`:

- `procedures/PROCEDURE.md`
- `procedures/PATTERN_CATALOG.md`
- `procedures/OPEN_QUESTION_ANSWERS.md`
- `procedures/F4_GUARDRAILS_PLAN.md`
- `procedures/BUILDING_WITH_SPACK_MPD.md`

Do **not** consult anything under `$MIGRATION/plans/` — those are the superseded
plan revisions, kept only for history. If executing this workflow ever seems to
require information from one of them, stop and report that instead of reading it.

## Guard rail scripts (F4)

All under `$MIGRATION/guardrails/`. Every one of them discovers the mpd project
from your current directory, so run them from inside the project's `srcs` tree
(or set `MPD_PROJECT`).

- `mpd-paths.sh --check` — report the discovered project and tooling paths.
  **Run this first, every time.**
- `env.sh` — **source** (do not execute) before any command that builds or runs
  a test binary: `source $MIGRATION/guardrails/env.sh`. It activates the spack
  environment for the discovered project and warns if gcc is not 12.5.0.
  See `procedures/BUILDING_WITH_SPACK_MPD.md`.
- `grep-gate.sh [path ...]` — G1. Fails (exit 1) if `mf::`/`MF_LOG_`/
  `messagefacility` remains. Paths may be absolute, CWD-relative, or
  srcs-relative. With no argument it scans all four packages of the discovered
  project. `--baseline-count` prints per-file counts; `--staged` checks staged
  files (run once per package repo — they are separate git repos).
- `format-string-lint.sh [path ...]` / `--self-test` — G2. Fails on a non-literal
  `spdlog::` format argument. `--self-test` is the required two-sided acceptance
  (Logging.cxx clean + hazard fixture flagged).
- `gen-targets.sh [--check]` — G3.1. Regenerates the source→test manifest at
  `guardrails/baselines/<project>/targets.tsv` from the live build graph.
- `outdiff.sh {baseline|check|levels|report} <test|--all-mf>` — G3.3/G3.4. The
  before/after output-diff harness and the level-vanish check. Baselines are
  stored per project under `guardrails/baselines/<project>/`.
- `normalize.sed` — the calibrated normalization rules `outdiff.sh` applies;
  read its header before trusting an unexplained diff.
- `../prototypes/verify-installed-header.sh` — the F3 gate: compiles the real
  installed `Logging.h` against the full F3 checklist.

Concrete check commands:
- **F3**: `$MIGRATION/prototypes/verify-installed-header.sh`
- **F4**: `grep-gate.sh && format-string-lint.sh --self-test && gen-targets.sh`
- **GATE B step 1**: `outdiff.sh check <test>` (or `check --all-mf`)
- **GATE B step 2**: `outdiff.sh levels <test>`
- **GATE B step 7**: `grep-gate.sh {TARGET}`

## Precedence (apply at every decision point)

1. File-specific override in `OPEN_QUESTION_ANSWERS.md` §2 (only if the current
   file/site is named there).
2. General-decision override in `OPEN_QUESTION_ANSWERS.md` §2.
3. Default answer in `OPEN_QUESTION_ANSWERS.md` §1.
4. `PATTERN_CATALOG.md` default pattern/mitigation.
5. `PROCEDURE.md` skeleton default.

Known resolved values (verify against the live files; this is a summary, not a
substitute for reading them):
- Output pattern: set by `Logging.cxx` (`[LOG-%l] %v`), with `Logging.h` emitting
  `[in <scope>]: <body>`. `normalize.sed` is calibrated to that exact shape.
- Header home: `larcoreobj/larcoreobj/LoggingUtil/Logging.h` **within the
  discovered project's `srcs`**.
- File destinations from old config: keep as a second sink.
- Deprecation window for renamed public init functions: break immediately.
- No end-of-job spdlog statistics (drop permanently, warn once naming what was
  ignored — not a TODO).
- Per-file hot-path overrides are listed in `OPEN_QUESTION_ANSWERS.md` §2 and are
  scoped to the current migration wave; re-read them rather than assuming.

## Part I — Foundation preconditions (F0–F5)

Verify, never create. For the discovered project:

- **F0** decisions file complete (`OPEN_QUESTION_ANSWERS.md`, no unanswered rows).
- **F1** `find_package(spdlog)` succeeds; record version, compiled-vs-header-only,
  bundled-vs-external fmt, presence of `spdlog/mdc.h`.
- **F2** logging header exists at the resolved home **in this project** and
  contains every required element from `PROCEDURE.md`.
- **F3** foundation test green: run `prototypes/verify-installed-header.sh`.
- **F4** `grep-gate.sh`, `format-string-lint.sh --self-test`, `gen-targets.sh`,
  `outdiff.sh` all runnable.
- **F5** migration order fixed — `larcoreobj` first, then verify the real
  dependency graph; do not assume.

Note F2/F3 are **per project**: a project that has never been migrated will not
have `LoggingUtil/`, and that is an F2 failure to report, not something to fix
inside this step.

**Stop after this step and report F0–F5 status explicitly. Wait for approval.**

## Part II — Per-target loop

Run every step in order. **Stop after each step and wait for explicit approval
before starting the next** — a hard requirement, regardless of how mechanical the
step looks.

1. **P0 — Precondition gate.** Re-verify F0–F5. Abort naming the specific failing
   item; do not repair automatically. **Stop for approval.**
2. **P1 — Inventory.** Enumerate every mf call site, include, CMake reference and
   config block under `{TARGET}`. Separate live sites from dead includes and
   commented-out sites. Report counts by API form, file list, CMake/config refs.
   **Before stopping, capture output baselines** for every test `{TARGET}` can
   affect — irreversible once source is migrated (F4_GUARDRAILS_PLAN.md finding 6):
   `source guardrails/env.sh`, then `gen-targets.sh`, then
   `outdiff.sh baseline --all-mf` (or `baseline <test>`). Report which tests were
   baselined. **Stop for approval.**
3. **P2 — Classify.** Place every live site in a `PATTERN_CATALOG.md` §2 form, and
   scan for every hazard in `PROCEDURE.md` P2 (iomanip, ostream-only ADL
   concentration, hot-path sites, threshold-dependent trace/debug, public-header
   log calls, assertion-reporter logging, stale logger comments, persisted
   data-product headers, generic-helper narrowing). Apply the precedence order for
   hot-path mitigation. **If any site fits no §2 form, stop immediately and surface
   it — do not guess, do not proceed even with approval until the catalog is
   extended.** Otherwise **stop for approval.**
4. **P3 — Order the work.** Dependency order, then difficulty; mechanical bulk
   before hard sites; files that unblock running tests first. **Stop for approval.**
5. **GATE A — Smoke test.** Migrate exactly one site exercising the hardest pattern
   present (prefer ostream-only ADL, else stored-by-value) and compile it in the
   real build. **If this fails, stop the entire run** — the foundation needs work,
   not the call sites. **Stop for approval either way before any bulk edit.**
6. **P4 — Edit.** A file is migrated **all at once or not at all** — there is no
   safe stopping point inside a file, because a half-converted file does not
   compile. Do not pause, build, commit, or report in the middle of one.

   Per file, in P3 order: (a) enumerate every live site in the file and write the
   list down first — that list is the definition of done; (b) add the new include
   *alongside* the old one (add new first, remove old last, so the file compiles
   throughout); (c) convert **every** site on the list — level mapping (§2.1), drop
   category args and manual class/method prefixes (§2.2), form-specific transform
   from §2, preserving load-bearing braces (§2.3), not restructuring control flow,
   not narrowing generic helpers (§2.6); (d) add hot-path guards per the resolved
   P2 report; (e) delete stale logger comments (§5.3) and context-singlet/iteration
   calls (§2.8) if `spdlog/mdc.h` is absent; (f) **run the single-file close-out
   check and require exit 0**:

   ```
   $MIGRATION/guardrails/grep-gate.sh <file>
   ```

   Exit 1 means the file is **still mid-edit** no matter how complete it feels — go
   back to (c) and convert what it names. Only after exit 0, remove the
   messagefacility include (and, for a dead-include-only file, §5.4); (g) build the
   file's target.

   **Do not report a file as done, and do not stop for approval, until (f) exits 0
   and (g) compiles.** A file failing either is work in progress, not a completed
   step awaiting review. No regex/`sed` bulk rewrite. One file per commit.
   **Stop for approval after each completed file** (or a pre-approved batch).
7. **P5 — Build system.** Drop the mf link per target, noting original visibility;
   add the logging dependency with the same visibility; remove `EXPORT`ed
   `find_package` last; translate config blocks per §4.5 with the resolved
   overrides. **Stop for approval.**
8. **P6 — Build and test.** Package builds/links with no mf reference and existing
   tests pass. Use `spack mpd build` / `spack mpd test` per
   `BUILDING_WITH_SPACK_MPD.md`. Partial-tree builds (mf + spdlog coexisting) are
   expected mid-migration. **Stop for approval.**
9. **GATE B — Verification.** Run all seven applicable checks from `PROCEDURE.md`
   using the guard rails: `outdiff.sh check` (output diff), `outdiff.sh levels`
   (level check), manual exercise for hot-path / assertion-reporter /
   dual-entry-point / serialization checks where applicable, and
   `grep-gate.sh {TARGET}` (grep sweep). Present all seven results explicitly; do
   not report green on partial evidence. **Stop for approval.**
10. **P7 — Report.** Sites migrated by form; guards added and their source
    (file-specific override vs. §4.1 default); capabilities lost (note the
    permanent statistics-summary loss); interface changes needing downstream
    announcement; pre-existing defects observed but not fixed; any new catalog gap.
    **Stop — final sign-off for `{TARGET}`.**

## Re-running

Re-invoke with a new `{TARGET}` from the same `srcs` directory, e.g.
`/spdlog-migrate lardataalg` or
`/spdlog-migrate lardataobj/lardataobj/RawData/raw.cxx`. To work on a different
mpd project, invoke from that project's `srcs` directory (or set `MPD_PROJECT`)
— baselines and manifests are kept per project automatically.

If P2 surfaces a new hot-path decision not covered by the default menu, add it to
`OPEN_QUESTION_ANSWERS.md` §2 before finalizing that run, rather than
special-casing this command.
