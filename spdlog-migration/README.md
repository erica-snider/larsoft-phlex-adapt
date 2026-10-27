# spdlog-migration

Tooling and procedure for migrating LArSoft packages from `messagefacility` to
`spdlog`.

This directory lives in the **`larsoft-phlex-adapt`** repo, *outside* any mpd
project, and is shared across projects. The mpd project to operate on is
**discovered from your current directory**.

## Layout

| Directory | Contents |
|---|---|
| `procedures/` | The live workflow. `PROCEDURE.md` (steps), `PATTERN_CATALOG.md` (what you may find and what to do), `OPEN_QUESTION_ANSWERS.md` (decisions), `F4_GUARDRAILS_PLAN.md`, `BUILDING_WITH_SPACK_MPD.md`, `STATE.md`. |
| `guardrails/` | Executable checks. See below. |
| `prototypes/` | 12 compile-verified prototypes; `verify-installed-header.sh` is the F3 gate. |
| `plans/` | Superseded plan revisions, history only. **Do not drive work from these.** |
| `kilo/.kilo/` | The `/spdlog-migrate` slash command, soft-linked into place for VS Code. |

## Quick start

From inside the `srcs` directory of the mpd project you want to work on:

```bash
MIGRATION=<abs path to this directory>

# 1. Confirm which project was discovered -- ALWAYS do this first.
$MIGRATION/guardrails/mpd-paths.sh --check

# 2. Activate the build environment (SOURCE it, do not execute).
source $MIGRATION/guardrails/env.sh

# 3. Run the workflow.
/spdlog-migrate <dir>        # <dir> is relative to this srcs directory
```

`<dir>` may be a package (`larcorealg`), a subdirectory
(`lardataobj/lardataobj/RawData`), or a single file.

## Project discovery

An mpd project root is a directory containing `srcs/`, `local/spack.yaml` and
`build/`. Every script walks up from the invocation directory to find one.

- Override with `MPD_PROJECT=<name|absolute path>`.
- Resolution **fails loudly** if no project is found — a guard rail that cannot
  find its tree must never quietly report success.
- Several projects may coexist at different migration stages. **Check which one
  you are pointed at before trusting a result**: a clean grep gate means nothing
  if it scanned the wrong tree.

Baselines and the test manifest are kept per project under
`guardrails/baselines/<project>/`, because a baseline is a capture of one
project's test output and is meaningless against another's.

## Guard rails

| Script | Purpose |
|---|---|
| `mpd-paths.sh --check` | Report the discovered project and tooling paths. |
| `env.sh` | **Source** it. Activates the spack environment; warns if gcc is not 12.5.0. |
| `grep-gate.sh [path ...]` | G1. Exit 1 if `mf::`/`MF_LOG_`/`messagefacility` remains. Also the per-file close-out check in `PROCEDURE.md` P4. |
| `format-string-lint.sh [path ...]` / `--self-test` | G2. Flags a non-literal `spdlog::` format argument (a runtime-only hazard). |
| `gen-targets.sh [--check]` | G3.1. Regenerates the source→test manifest. |
| `outdiff.sh {baseline\|check\|levels\|report}` | G3.3/G3.4. Before/after output diff and the level-vanish check. |
| `normalize.sed` | Calibrated normalization rules used by `outdiff.sh`. |
| `../prototypes/verify-installed-header.sh` | F3 gate: compiles the real `Logging.h` against the full checklist. |

Paths given to `grep-gate.sh` and `format-string-lint.sh` may be absolute,
relative to your current directory, or relative to the discovered `srcs`.

## Installing the slash command

Soft-link `kilo/.kilo` so VS Code discovers it, e.g. from the directory that
should carry the config:

```bash
ln -s <abs path>/spdlog-migration/kilo/.kilo .kilo
```

`kilo/.kilo/` is the single source of truth for the command; there is no second
copy to keep in sync.
