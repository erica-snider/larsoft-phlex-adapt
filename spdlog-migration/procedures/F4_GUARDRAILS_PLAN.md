# Plan: automate creation of the F4 guard rails

**Goal.** Satisfy `PROCEDURE.md` F4 ("grep gate, format-string lint, output-diff
harness — all three runnable") so the migration workflow's precondition gate can pass,
and so `GATE B` has real checks behind it rather than assertions.

**Scope.** This plan covers only the F4 guard rails. It does not migrate any call site
and does not touch F1 (`spdlog` in `spack.yaml`), which is tracked separately.

**Deliverables.** Four scripts plus one generated manifest, all under
`spdlog-migration/guardrails/`:

| ID | Artifact | Per-file? | Purpose |
|---|---|---|---|
| G0 | `env.sh` | no | activate the build/run environment; sourced by the others |
| G1 | `grep-gate.sh` | no | fail if mf identifiers reappear |
| G2 | `format-string-lint.sh` | no | fail on a non-literal spdlog format argument |
| G3 | `outdiff.sh` + `targets.tsv` | **yes, via generated manifest** | normalized before/after output comparison |

---

## 0. Findings that shape this plan

Established by inspection before writing it:

1. **A live build tree exists** at `mpddev/build` with 76 registered ctest tests. The
   baseline can be captured for real.
2. **The test environment is not active in a plain shell.** `geometry_test` fails with
   `libtbb.so.12: cannot open shared object file`. Adding
   `local/.spack-env/view/tbb/latest/lib` to `LD_LIBRARY_PATH` clears that, after which
   the test fails *differently* — an mf `Configuration error` — meaning more of the
   environment (at minimum `FHICL_FILE_PATH`) is still missing. **G0 exists because of
   this**, and it must be solved first: every other guard rail depends on being able to
   run a test.
3. **Tests may not be green even before migration.** If so, that is not a blocker for
   G3 — a diff compares before against after, and a *stable* failure is still a valid
   baseline — but it is fatal for `GATE B`'s level check, which needs the trace/debug
   output the test would produce. Establishing which tests actually run is therefore
   part of this plan, not an assumption.
4. **The migration documents are full of mf identifiers.** `PATTERN_CATALOG.md`,
   both plan revisions and the prototypes all contain `mf::`, `MF_LOG_` and
   `messagefacility` as *subject matter*. A naive grep gate fails instantly on its own
   documentation. Exclusions are a correctness requirement, not a convenience.
5. **Prototype 08 must keep failing to compile.** `build-and-run.sh` treats a successful
   compile there as an error. No guard rail may "fix" or lint that file.
6. **The baseline is destructible and unrecoverable.** Once a file is migrated, its
   pre-migration output cannot be regenerated without a revert. Baseline capture must
   therefore happen before the first edit of a package, and the captured artifacts must
   be treated as read-only thereafter.

---

## G0. Environment activation helper

**Problem.** Nothing in the source tree documents how to enter the build environment;
it was discovered empirically that a plain shell cannot run the tests.

**Steps.**

1. Determine the intended activation (in order of preference): an existing spack
   env activation for `mpddev/local`, else the `.spack-env/view` layout with the
   needed paths exported explicitly.
2. Write `guardrails/env.sh` that is **sourced**, not executed, and sets whatever is
   required — at minimum `LD_LIBRARY_PATH` for tbb, plus `FHICL_FILE_PATH` /
   `FW_SEARCH_PATH` if the ctest-provided values are not sufficient outside ctest.
3. Make it idempotent and safe to source twice.
4. **Acceptance:** after sourcing, `ctest --test-dir build -R '^geometry_test$'` runs
   the binary and produces geometry output rather than a loader or configuration error.
   If the test still fails for a *migration-independent* reason, record the exact
   failure in the file as a known-state note and continue.

**Risk.** If the environment cannot be made to work, G3 cannot be built as specified.
That is a stop-and-report condition, not something to paper over: without a baseline,
`GATE B` step 1 is unenforceable and the whole "catch silent regressions" argument
collapses. Surface it rather than substituting a weaker check.

**Solution**. `guardrails/env.sh` has been added. Sourcing this file will set up `spack mpd`
as needed to build and test the code. `env.sh` is idempotent. 
`larcorealg/spdlog-migration/BUILDING_WITH_SPACK_MPD.md` explains how to use `spack mpd` 
to build code and run tests, and explains the connection to `spack`, `spack mpd` 
and `ctest` commands.

---

## G1. Grep gate

**Contract.** Exit 0 if no live mf identifier is present in the scanned scope; exit
non-zero listing every offender otherwise.

**Steps.**

1. Write `guardrails/grep-gate.sh [path ...]`, defaulting to the four package source
   trees when given no argument.
2. Pattern: `messagefacility`, `mf::`, `MF_LOG_`, plus `MF_MessageLogger` for CMake.
3. **Exclusions, encoded as a single documented list:**
   - the entire `spdlog-migration/` directory (catalog, plans, prototypes, this file);
   - `SPDLOG_MIGRATION*.md` and `MIGRATION_PLAN.md` at package root;
   - any `build/` tree;
   - `.git/`.
4. Provide `--staged` mode scanning only staged files, so it can serve as a
   pre-commit check per `PROCEDURE.md` P4's one-file-per-commit rule.
5. Provide `--allow-file <path>` for files deliberately retaining a reference
   (e.g. a deprecation note), recorded in an `ALLOWLIST` block inside the script with a
   reason per entry.
6. **Acceptance:** run it now, against the unmigrated tree. It **must report the known
   live sites** (~392 in `larcorealg`, 10 in `lardataobj`, 68 in `lardataalg`) and
   **must not** report anything from the migration documents. A gate that is green today
   is broken. Record the current counts in the script header as the starting baseline.

---

## G2. Format-string lint

**Contract.** Fail on any `spdlog::` logging call whose format argument is not a string
literal — the §1.1 hazard, which fails only at runtime and only for brace-containing
messages.

**Steps.**

1. Write `guardrails/format-string-lint.sh [path ...]`.
2. Match `spdlog::(trace|debug|info|warn|error|critical|log)\s*\(` and inspect the
   first argument — or, for `spdlog::log`, the argument after the level.
3. Flag when that argument does not begin with `"` (allowing a preceding level
   expression for `log`). Explicitly flag the known-bad shapes: a bare identifier, a
   `.str()` call, and string concatenation.
4. Accept a documented waiver comment (`// spdlog-format-ok: <reason>`) on the
   preceding line, so `Logging.cxx`'s own correct call sites can be annotated rather
   than special-cased by path.
5. **Known limitation, stated in the script header:** this is a regex check, not a
   parser. It will not see a call split across lines in unusual ways. It is a net, not
   a proof — the real protection is that `LogStream` is the only sanctioned path and it
   is verified by prototype 02 and the F3 gate.
6. **Acceptance — two-sided, both required:**
   - against `larcoreobj/larcoreobj/LoggingUtil/Logging.cxx`: **clean** (its two calls
     pass the body as an argument);
   - against `prototypes/02-runtime-format-string-hazard.cxx`: **flags** the deliberate
     hazard. A lint that cannot detect the one file written to demonstrate the bug is
     not a lint. Use that file as the permanent regression fixture.

---

## G3. Output-diff harness

The only check that catches a silently vanished level (§4.2). Also the only guard rail
that is per-target, which is where the automation the request asks for is needed.

### G3.1 The per-file problem, and how it is automated

A source file does not have output; a *test* does. The mapping needed is
`source file → ctest test(s) whose output that file influences`. Producing it by hand
per file does not scale and goes stale. Instead **generate it**:

1. Enumerate tests from the build tree with `ctest --test-dir build -N`.
2. For each test, recover its target and sources from the CMake/ctest metadata
   (`CTestTestfile.cmake` plus the `cet_test(... SOURCE ...)` declarations in each
   `test/*/CMakeLists.txt`).
3. For each test, record the libraries it links, so a change to a library source can be
   attributed to the tests that exercise it.
4. Emit `guardrails/targets.tsv`, one row per test:
   `test_name <TAB> package <TAB> source_files <TAB> linked_libs <TAB> has_mf_sites`
5. `has_mf_sites` is computed by intersecting the test's sources and library sources
   with G1's live-site list — this is what makes the manifest *useful* rather than
   merely complete: it marks which tests can possibly change output.

A regeneration script `guardrails/gen-targets.sh` rebuilds the manifest, so adding a
package later is one command, not an edit. The manifest is checked in so a run can
detect drift.

### G3.2 Normalization — calibrate, do not guess

Before: mf-decorated records. After: `scope::name: body`. The comparison must reduce
both to bare message bodies.

**This cannot be written correctly without seeing real baseline output**, so the
sequence is: capture first, then calibrate, then finalize. Planned rules, to be
confirmed against actual captures:

- strip mf record decoration (`%MSG`-style banners, category, severity, timestamp,
  application/context fields, and mf's trailing `%MSG` terminator);
- strip the spdlog scoped-name prefix `^[A-Za-z_][A-Za-z0-9_:<>~]*: ` from migrated
  output — but **capture it separately** into a sidecar file, because §2.4's note says
  the prefix identifies the call site and a *wrong* prefix is a real defect worth
  seeing;
- normalize absolute paths, PIDs, and any wall-clock or duration values;
- leave blank-line structure intact, since a spurious blank line was an observed mf
  artifact and its disappearance is a real (acceptable) change worth seeing in the diff.

Each rule goes in `guardrails/normalize.sed` (or a small awk script) with a comment
naming what it strips and why, so an unexplained diff can be traced to a rule.

### G3.3 Commands

`guardrails/outdiff.sh` with three modes:

- `baseline <test|--all-mf>` — run the test, normalize, store under
  `guardrails/baselines/<test>.txt`; refuse to overwrite an existing baseline without
  `--force`, since it is unrecoverable (finding 6);
- `check <test>` — re-run, normalize, diff against the stored baseline, exit non-zero on
  difference, print a unified diff;
- `report` — summarize every test with a baseline: matched / differing / missing.

### G3.4 Level check support

`GATE B` step 2 needs "every trace/debug site still visible is still visible". Add
`outdiff.sh levels <test>`, which counts records by level in baseline and current
output and fails if a level's count drops to zero when it was non-zero before. This is
the cheap, mechanical form of the §4.2 check and catches the exact regression named as
most likely.

### G3.5 Acceptance

1. `gen-targets.sh` produces a manifest whose `has_mf_sites` column marks the tests
   known to exercise mf-heavy code (the geometry tests in `larcorealg`, the
   `DetectorInfo` tests in `lardataalg`).
2. `baseline --all-mf` captures every such test, with the environment from G0.
3. `check` immediately after `baseline`, with no edits, reports **no differences** for
   every captured test. A harness that is not self-consistent is worse than none —
   it would train the operator to ignore it.
4. Deliberately perturb one message body in a scratch copy and confirm `check` catches
   it, then revert. This proves sensitivity, which (3) alone does not.

---

## Execution order

G0 → G1 → G2 → (G3.1 manifest → G3.3 capture → G3.2 calibrate → G3.4 → G3.5).

G1 and G2 are independent of the environment and can be finished even if G0 stalls.
G3 is strictly blocked on G0.

**Do not capture baselines for a package after starting to migrate it.** If migration
of any package has already begun when this plan is executed, note it and capture what
is still capturable, flagging the rest as permanently unavailable.

---

## Integration back into the workflow

Once the four artifacts exist:

1. `PROCEDURE.md` F4 becomes checkable: name the three scripts and their acceptance
   commands.
2. `.kilo/command/spdlog-migrate.md` F4 verification runs each script's self-test rather
   than asserting existence.
3. `GATE B` steps 1, 2 and 7 cite concrete commands (`outdiff.sh check`,
   `outdiff.sh levels`, `grep-gate.sh`) instead of prose.
4. Add one line to `PROCEDURE.md` P1: capture baselines for the target package **before**
   the first edit. This is currently implicit and is the single most destructible
   precondition in the whole workflow.

These edits are part of executing this plan, not follow-up work — a guard rail the
workflow does not invoke is not installed.

---

## Deliberately excluded

- **A clang-tidy/AST-based checker.** Correct, and disproportionate here. The regex lint
  plus the `LogStream`-only convention covers the hazard; revisit if hand-written
  `spdlog::` calls proliferate.
- **CI wiring.** No CI configuration was found in the dev area. The scripts are written
  to be CI-friendly (path arguments, exit codes, quiet mode) but nothing is registered.
- **A guard rail for hot-path rate limiting.** `GATE B` step 3 requires exercising the
  loop, which is per-site work, not a generic script.
