# messagefacility → spdlog: procedure skeleton

**Bucket 1 + 2 artifact.** Part I is the one-time foundation (preconditions the
workflow *checks*, never performs). Part II is the reusable per-package loop that
becomes the workflow.

Section references of the form §N point at `PATTERN_CATALOG.md`.

This is a skeleton: steps, gates and exit criteria, with no instance data. Effort
estimates are deliberately absent — they were per-package and do not transfer.

---

# Part I — One-time foundation (precondition, not workflow)

Performed once for the whole migration effort. The workflow **verifies** each item and
**aborts** if any is missing; it must never attempt to create them, because getting
these wrong silently poisons every subsequent package.

## F0. Decisions committed

All rows of §8 answered and recorded in a file, not in a conversation. The header-home
decision blocks everything else.

**Check:** the decisions file exists and has no unanswered rows.

## F1. spdlog available in the build environment

Added to the environment spec; resolves to the existing installed build rather than
rebuilding; `find_package(spdlog)` succeeds in a scratch project.

**Check:** `find_package` succeeds and the imported target links.

Record, once, the properties that constrain the design: version, compiled-vs-header-only,
bundled fmt version, and **whether `spdlog/mdc.h` exists** (absent ⇒ §2.8 context calls
are deleted, not translated).

## F2. Logging header exists and is correct

Lives at the location chosen in F0 (§6.2). Must contain, at minimum:

- the accumulating sink with an `std::ostringstream` member, carrying a comment stating
  the member is load-bearing (§1.2);
- destructor emitting with the body as an **argument** (§1.1), suppressing empty bodies;
- **disarming move constructor** (§1.3); deleted copy ctor, copy-assign, move-assign;
- both manipulator overloads — `std::ostream&` and `std::ios_base&` (§3.1);
- compile-time scoped-name prefix from `__PRETTY_FUNCTION__`, with a `__func__` fallback;
- level macros for err/warn/info/debug/trace (§2.1);
- a `debugEnabled()`-style runtime level query (§2.7);
- an init shim that sets the level **explicitly** (§4.2).

**Check:** header present; the foundation test (F3) passes.

## F3. Foundation test green

Covers, at minimum: named accumulating object with control flow; `Stream&&` forwarding
through multiple template levels; temporary streamed to, then passed as `Stream&&`;
generic dump manipulator; log alive across a `throw`; `std::endl`; `std::setw`;
multi-line body as one record; **body containing literal braces**; suppressed level
emits nothing and formats nothing; constructed-but-never-streamed emits nothing;
**move emits exactly once**; storage by value *and* by reference in a member (§2.5).

**Check:** test passes. No production file has been modified at this point.

## F4. Guard rails installed

Install **before** any bulk editing, not after. Implemented per
`F4_GUARDRAILS_PLAN.md`, checked in under `spdlog-migration/guardrails/`:

1. grep gate — fail if `mf::` / `MF_LOG_` / `messagefacility` reappears.
   `guardrails/grep-gate.sh [path ...]` (default: the four package trees).
   A standing, documented allowlist is applied automatically; `--no-allowlist`
   disables it for auditing the waiver list itself.
2. format-string lint — fail on an `spdlog::` call whose format argument is not a
   string literal (§1.1; this hazard fails at runtime only, and only for
   brace-containing messages).
   `guardrails/format-string-lint.sh [path ...]`; `--self-test` runs the
   required two-sided acceptance (clean against `Logging.cxx`, flags
   `prototypes/02-runtime-format-string-hazard.cxx`).
3. output-diff harness, checked in as a script so it can be re-run per file.
   `guardrails/gen-targets.sh` regenerates the source→test manifest
   (`guardrails/targets.tsv`) from the live ninja/ctest build graph — this is
   what makes the harness re-appliable to a new file with no manual mapping.
   `guardrails/outdiff.sh {baseline|check|levels|report} <test|--all-mf>`
   captures, normalizes (`guardrails/normalize.sed`), diffs, and reports.

**Check:** all three runnable —
`guardrails/grep-gate.sh`,
`guardrails/format-string-lint.sh --self-test`,
`guardrails/gen-targets.sh && guardrails/outdiff.sh baseline --all-mf && guardrails/outdiff.sh check --all-mf`.
All three require `guardrails/env.sh` to be sourced first (see
`BUILDING_WITH_SPACK_MPD.md`) for anything that runs a test binary.

## F5. Migration order determined

Dependency order across the packages in scope (§6.3), fixed before starting.

---

# Part II — Per-package / per-file-set procedure

The reusable loop. Input: a set of files or a package. Steps P1–P3 are read-only.

## P0. Precondition gate

Verify F0–F5. **Abort** with a specific message if any fails; do not attempt repair.

## P1. Inventory

Enumerate every mf call site, include, CMake reference, and configuration block in the
target set. Distinguish live sites from dead includes and commented-out sites (§5.4).

**Before any edit in this target set:** run
`guardrails/gen-targets.sh && guardrails/outdiff.sh baseline --all-mf` (or
`baseline <test>` for a narrower target) to capture output baselines for every
test this set can affect. This is the single most destructible precondition in
the whole workflow — a baseline cannot be regenerated once its source has been
migrated (`F4_GUARDRAILS_PLAN.md` finding 6) — so it must happen here, before
P4, not be treated as implicit.

**Output:** counts by API form; list of files touched; CMake and config references.

## P2. Classify

Place every site in a §2 form: mechanical temporary, named accumulating object,
`Stream&&`-forwarded, stored-by-value, generic dump helper, runtime level query, init
or context call.

Simultaneously scan for the hazards, which are **not** call-site forms:

- iomanip streamed into a log (§3.1);
- ostream-only ADL types, and whether they concentrate in one file (§3.4);
- **hot-path sites** — reachable from a loop, a comparison operator, or a per-record
  code path (§4.1);
- trace/debug sites whose visibility depends on an old verbose threshold (§4.2);
- public installed headers containing log calls — these force `INTERFACE` deps (§6.1);
- logging used as a test-assertion reporter (§5.2);
- stale comments describing the logger (§5.3);
- persisted data products / dictionaries ⇒ run the §7 checks;
- generic dump helpers that must not be narrowed (§2.6).

**Output — the one cheap interaction point per run.** A report giving the
classification counts, the hazard list with proposed mitigation per hot-path site, and
**any site that fits no catalogued pattern**. On an unattended run, proceed only if the
unclassified list is empty; otherwise stop and surface it (§9).

## P3. Order the work

Within the set: dependency order first, then difficulty. Mechanical bulk before hard
sites. Files whose migration unblocks the ability to *run* tests (test mains, init
shims) come first.

## GATE A — Smoke test

Before any bulk edit, migrate exactly **one** site exercising the hardest pattern
present in this set - preferably an ostream-only ADL type (§3.4) if one is used, or the
stored-by-value case (§2.5) if present. Compile the affected target in the **real
build**, not a reduced compilation.

Gate A is a coexistence check. If the selected file still contains other
messagefacility sites, retain both logging includes for this smoke test:

  #include "messagefacility/MessageLogger/MessageLogger.h"
  #include "larcoreobj/LoggingUtil/Logging.h"

Only the selected site may be converted. Do not remove the messagefacility
include or dependency during Gate A unless no remaining live messagefacility
site in the affected target requires it.

A Gate A failure caused by removing an include or dependency while other
messagefacility sites remain is a workflow error. Restore coexistence and retry
Gate A. A failure after coexistence has been preserved is a genuine Gate A
failure and stops the run.

The selected site must compile through the real target and its actual template,
ADL, and stream-helper paths. A newly written standalone reduction may be used
only as supplementary evidence; it cannot replace the real-target Gate A
compilation.

**Stop the entire run if this fails.** Everything downstream depends on the sink
handling this set's type system, and a failure here means the foundation needs work, not
the call sites.

## P4. Edit

A file is migrated **all at once or not at all.** Between the first edit and the last,
the file does not compile: the old include has to go and the new one has to arrive, and
any call site left behind references a name that no longer resolves. There is no safe
stopping point inside a file, so do not treat the site list as a queue that can be
paused, and do not interleave a build, a commit, or a report into the middle of one.

**Add the new include first; remove the old include last.** In between, both are
present and the file still compiles at every intermediate step, which makes a partial
edit recoverable instead of fatal.

Per file, in the P3 order:

1. **Enumerate every live site in this file, and write the list down** — count and line
   numbers — before changing anything. This list is the definition of done for the file.
   Use the P2 classification for the file; if it disagrees with what is in the file now,
   stop and reconcile rather than trusting either.
2. add the new logging include alongside the existing messagefacility include;
3. convert **every** site on the list from step 1: apply the level mapping (§2.1); drop
   category arguments and manual class/method prefixes already in the text (§2.2); apply
   the form-specific transformation from §2 — preserving load-bearing braces (§2.3), not
   restructuring control flow, not narrowing generic helpers (§2.6);
4. add hot-path guards per the P2 report (§4.1);
5. delete stale logger comments (§5.3) and context-singlet/iteration calls (§2.8);
6. **verify zero live sites remain, mechanically** (see below). Only then remove the
   messagefacility include — and only then, for a file that had a dead include and no
   live sites (§5.4), remove that include;
7. build the file's target. A file is not done until it compiles.

### The mechanical check that closes the file

Judgement is what fails here: an agent that believes it has finished will not re-read
the file to find out that it has not. So do not rely on believing. Run the grep gate on
the single file and require exit 0:

```
spdlog-migration/guardrails/grep-gate.sh <path/to/file>     # exit 0 = no live sites
```

Exit 1 with a non-empty list means the file is **still mid-edit**, regardless of how
complete it feels. Go back to step 3 and convert what it names. Running this before
removing the old include is what prevents the build break; running it after is only a
postmortem.

If the file is genuinely finished, the gate is silent and the target builds. Those two
facts together — not the agent's sense of completion — are what closes the file.

**No regex or `sed` bulk rewrite** (§5.1). One file per commit, committed only after
step 7 passes.

## P5. Build system

- drop the mf link from each target; note `PRIVATE` vs `INTERFACE`/`PUBLIC` (§6.1);
- add the logging dependency with the **same visibility** the mf dependency had;
- remove `find_package(... EXPORT)` **last** — it is a downstream-visible interface
  change (§6.1);
- translate configuration blocks (§4.5), recording dropped capabilities in-file.

## P6. Build and test

Package builds and links with no mf reference; existing tests pass. mf and spdlog
coexist during the transition, so a partially migrated tree is expected to build.

## GATE B — Verification

"Builds and tests pass" is **not** sufficient — §4.2 regressions produce neither a
compile error nor a test failure. All applicable checks are required:

1. **Normalized before/after output diff** for the affected tests. Message bodies must
   be identical modulo the added scoped-name prefix. Any other difference is a bug.
   This is the only check that catches a silently vanished level.
   Command: `guardrails/outdiff.sh check <test>` (or `check --all-mf` for every
   baselined test in this run). Requires a P1 baseline to already exist.
2. **Level check** — confirm every trace/debug site still visible under the old
   threshold is still visible (§4.2).
   Command: `guardrails/outdiff.sh levels <test>`. Note its documented
   limitation once a test is fully migrated to the bare-`%v` pattern (no level
   text remains to count) — treat check #1 as authoritative in that case.
3. **Hot-path check** — confirm each guard from P2 behaves, by exercising the loop or
   comparison path.
4. **Assertion-reporter check** — if §5.2 applies, deliberately break one assertion and
   confirm the test still fails.
5. **Dual-entry-point check** — if §2.5 applies, exercise both the by-value and
   by-reference paths.
6. **Serialization check** — if §7 applies, rebuild dictionaries, confirm class
   versions and checksums unchanged, and read back existing files.
7. **Grep sweep** — no `mf::`, `MF_LOG_`, or `messagefacility` outside documentation.
   Command: `guardrails/grep-gate.sh`.

## P7. Report

Per run: sites migrated by form; guards added and which style (§4.1); capabilities lost
(§4.4, §4.5, §4.6); interface changes needing announcement (§6.1); pre-existing defects
observed but deliberately not fixed (§2.4); any catalog gap found (§9).

---

# Rollback

The logging header is purely additive and the two libraries coexist, so every edit phase
is independently revertible. One package per phase, one file per commit within a phase.

The one step that is irreversible in practice is removing the `EXPORT`ed `find_package`,
because downstream packages consume it. Do it last, after everything else is green.
