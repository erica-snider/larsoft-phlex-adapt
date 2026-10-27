#!/usr/bin/env bash
#
# G1 grep gate (spdlog-migration/F4_GUARDRAILS_PLAN.md).
#
# Fails (exit 1) if a live messagefacility identifier is found in scope.
# Exit 0 means clean.
#
# Usage:
#   grep-gate.sh [path ...]              scan the given paths (default: the four
#                                         package source trees). The ALLOWLIST
#                                         block below is applied automatically
#                                         -- no flag needed for the default,
#                                         zero-manual-input case.
#   grep-gate.sh --staged                scan only files staged in the git repo
#                                         whose CWD you invoke this from (one call
#                                         per package repo -- see NOTE below)
#   grep-gate.sh --allow-file <path> ...  suppress findings in <path> for THIS run
#                                         in addition to the standing ALLOWLIST;
#                                         <path> must already be listed in the
#                                         ALLOWLIST block below with a reason, or
#                                         the script refuses (waivers are reviewed
#                                         in one place, never invented ad hoc)
#   grep-gate.sh --no-allowlist           disable the standing ALLOWLIST for this
#                                         run (see every raw hit, for auditing
#                                         the waiver list itself)
#   grep-gate.sh --baseline-count         print "<count> <file>" per offending file
#                                         instead of the human report (for scripting)
#
# NOTE on --staged: larcoreobj, larcorealg, lardataobj and lardataalg are four
# separate git repositories (see `git -C <pkg> status` in each). --staged only
# inspects the repo whose working directory you are in (or pass explicit paths
# with --staged, which are interpreted as that repo's pathspecs). Run once per
# package repo as part of that repo's pre-commit hook.
#
# Live-site history (run with --baseline-count to reproduce):
#
#   2026-09-22, mpddev, UNMIGRATED:
#     larcoreobj ~0 files | larcorealg ~29 | lardataobj ~9 | lardataalg ~12
#   2026-10-27, mpddev, MIGRATED:
#     0 live sites in all four packages; the only matches are the two
#     allowlisted comment-only references in larcoreobj/LoggingUtil/.
#
# Reading a "clean" result correctly:
#   - A clean result is only meaningful if the tree was expected to be clean.
#     Check WHICH project you are pointed at first (`mpd-paths.sh --check`):
#     mpddev is already migrated, so 0 is correct there, whereas an
#     unmigrated project (e.g. larsoftobj) reporting 0 means this gate is
#     scanning the wrong tree.
#   - Note the pattern also matches migration DOCUMENTATION; those paths are
#     excluded by EXCLUDE_DIR_PATTERNS/EXCLUDE_FILE_PATTERNS below, so a raw
#     `rg` count over a package will be much higher than this gate's count.
#     That difference is expected, not a bug.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The guard rails now live in the larsoft-phlex-adapt repo, OUTSIDE any mpd
# project, so SRCS_DIR can no longer be derived by walking up from this script.
# It is discovered from the invocation directory instead -- see mpd-paths.sh.
# shellcheck source=mpd-paths.sh
source "$SCRIPT_DIR/mpd-paths.sh"

# Only resolve the project when we actually need a default scan root: explicit
# path arguments and --staged work fine outside a project.
SRCS_DIR=""
mpd_srcs_or_die() {
  if [[ -z "$SRCS_DIR" ]]; then
    mpd_resolve || exit 1
    SRCS_DIR="$MPD_SRCS"
  fi
}

PACKAGES=("${MPD_PACKAGES[@]}")

# --- Exclusions -------------------------------------------------------------
# Everything here is subject matter (mf identifiers are the topic, not a live
# call site) or generated/VCS noise. Keep this list itself as the single
# documented source of exclusions (F4_GUARDRAILS_PLAN.md G1 step 3).
EXCLUDE_DIR_PATTERNS=(
  '**/spdlog-migration/**'      # catalog, procedure, plans, prototypes, this file
  '**/build/**'                 # any build tree checked out under a package dir
  '**/.git/**'
)
EXCLUDE_FILE_PATTERNS=(
  '**/SPDLOG_MIGRATION*.md'
  '**/MIGRATION_PLAN.md'
)

# --- Allowlist ---------------------------------------------------------------
# Format: path -> reason. A file may only be passed to --allow-file if it is
# listed here; this keeps waivers reviewable in one place instead of scattered
# across invocations.
declare -A ALLOWLIST=(
  ["larcoreobj/larcoreobj/LoggingUtil/Logging.h"]="comment-only references to messagefacility/mf:: as historical/explanatory context in the replacement header's own docs; no live mf call sites"
  ["larcoreobj/larcoreobj/LoggingUtil/Logging.cxx"]="comment-only reference to messagefacility as historical context explaining the second-sink design choice; no live mf call sites"
 )

PATTERN='messagefacility|mf::|MF_LOG_|MF_MessageLogger'

mode="scan"
declare -a scan_paths=()
declare -a allow_files=()
apply_standing_allowlist=1

while (( $# )); do
  case "$1" in
    --staged)
      mode="staged"
      shift
      ;;
    --allow-file)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --allow-file requires a path" >&2; exit 2; }
      allow_files+=("$1")
      shift
      ;;
    --no-allowlist)
      apply_standing_allowlist=0
      shift
      ;;
    --baseline-count)
      mode_count=1
      shift
      ;;
    -h|--help)
      sed -n '2,28p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      scan_paths+=("$1")
      shift
      ;;
  esac
done

# Validate explicit --allow-file entries before scanning anything.
for f in "${allow_files[@]:-}"; do
  [[ -z "$f" ]] && continue
  if [[ -z "${ALLOWLIST[$f]+x}" ]]; then
    echo "ERROR: --allow-file $f is not present in the ALLOWLIST block of this script." >&2
    echo "       Add it there with a reason before waiving it." >&2
    exit 2
  fi
done

# The standing ALLOWLIST applies automatically (no manual --allow-file needed
# per run) unless --no-allowlist was given. This keeps normal runs
# zero-manual-input while keeping every waiver reviewable in one place.
if [[ "$apply_standing_allowlist" -eq 1 ]]; then
  for f in "${!ALLOWLIST[@]}"; do
    allow_files+=("$f")
  done
fi

build_rg_exclude_args() {
  local -n out=$1
  out=()
  for p in "${EXCLUDE_DIR_PATTERNS[@]}" "${EXCLUDE_FILE_PATTERNS[@]}"; do
    out+=(--glob "!${p}")
  done
}

declare -a rg_excludes
build_rg_exclude_args rg_excludes

declare -a targets=()

if [[ "$mode" == "staged" ]]; then
  # Operate on the git repo of the current working directory.
  mapfile -t staged < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null)
  if [[ ${#staged[@]} -eq 0 ]]; then
    echo "grep-gate: no staged files in $(pwd) -- nothing to check."
    exit 0
  fi
  targets=("${staged[@]}")
else
  if [[ ${#scan_paths[@]} -gt 0 ]]; then
    # Explicit paths: accept absolute, CWD-relative, or srcs-relative
    # (e.g. `larcorealg/larcorealg/Geometry/PlaneGeo.cxx`) so the command can
    # be driven with the same <dir> argument the workflow was invoked with.
    for p in "${scan_paths[@]}"; do
      if [[ -e "$p" ]]; then
        targets+=("$p")
      else
        mpd_srcs_or_die
        if [[ -e "$SRCS_DIR/$p" ]]; then
          targets+=("$SRCS_DIR/$p")
        else
          echo "grep-gate: path not found: $p" >&2
          echo "           (tried as given, and under $SRCS_DIR/)" >&2
          exit 2
        fi
      fi
    done
  else
    mpd_srcs_or_die
    for p in "${PACKAGES[@]}"; do
      [[ -d "$SRCS_DIR/$p" ]] && targets+=("$SRCS_DIR/$p")
    done
    if [[ ${#targets[@]} -eq 0 ]]; then
      echo "grep-gate: none of (${PACKAGES[*]}) found under $SRCS_DIR" >&2
      echo "           Wrong mpd project? Set MPD_PROJECT=<name> to choose." >&2
      exit 2
    fi
  fi
fi

RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

rg --no-heading --line-number --with-filename -e "$PATTERN" \
   "${rg_excludes[@]}" \
   "${targets[@]}" > "$RESULTS" 2>/dev/null

# Filter out allowlisted files entirely (waived files must still exist and be
# migrated eventually -- a waiver silences the gate, it does not delete the
# obligation, which is why this section requires a reason per entry).
#
# Matching is by path SUFFIX (rg reports absolute paths; ALLOWLIST/--allow-file
# keys are the package-relative paths shown in the ALLOWLIST block), so
# "larcoreobj/larcoreobj/LoggingUtil/Logging.h" matches
# ".../srcs/larcoreobj/larcoreobj/LoggingUtil/Logging.h:5:...".
if [[ ${#allow_files[@]} -gt 0 ]]; then
  FILTERED="$(mktemp)"
  cp "$RESULTS" "$FILTERED"
  for f in "${allow_files[@]}"; do
    # Add handling for absolute and relative allowlist entries, which require
    # separate matching logic. 
    escaped="$(printf '%s' "$f" | sed 's/[.[\*^$()+?{|]/\\&/g')"  
    if [[ "$f" == /* ]]; then
      pattern="^${escaped}:[0-9]+:"
    else
      pattern="(^|/)${escaped}:[0-9]+:"
    fi
   
    grep -v -E "$pattern" "$FILTERED" > "${FILTERED}.tmp"  
    mv "${FILTERED}.tmp" "$FILTERED"
  done
  mv "$FILTERED" "$RESULTS"
fi

if [[ -n "${mode_count:-}" ]]; then
  # One count per offending file, for scripting / baseline comparison.
  cut -d: -f1 "$RESULTS" | sort | uniq -c | sort -rn
  [[ -s "$RESULTS" ]] && exit 1 || exit 0
fi

if [[ ! -s "$RESULTS" ]]; then
  echo "grep-gate: PASS -- no mf:: / MF_LOG_ / messagefacility / MF_MessageLogger found."
  exit 0
fi

echo "grep-gate: FAIL -- live messagefacility references found:"
echo
cat "$RESULTS"
echo
echo "Files affected: $(cut -d: -f1 "$RESULTS" | sort -u | wc -l)"
echo "Total matches:  $(wc -l < "$RESULTS")"
exit 1
