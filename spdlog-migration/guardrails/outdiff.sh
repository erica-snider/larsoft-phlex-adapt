#!/usr/bin/env bash
#
# G3.3 / G3.4 output-diff harness (spdlog-migration/F4_GUARDRAILS_PLAN.md).
#
# The only guard rail that catches a silently vanished log level
# (PATTERN_CATALOG.md §4.2): builds/checks/reports normalized before/after
# test output, per test, using the manifest gen-targets.sh produces.
#
# Usage:
#   outdiff.sh baseline <test>       capture+normalize+store as the baseline
#                                    for <test>. Refuses to overwrite an
#                                    existing baseline without --force
#                                    (F4_GUARDRAILS_PLAN.md finding 6: a
#                                    baseline is unrecoverable once the
#                                    corresponding file has been migrated).
#   outdiff.sh baseline --all-mf     baseline every test with has_mf_sites=1
#                                    in targets.tsv (regenerate that manifest
#                                    first with gen-targets.sh if it's stale)
#   outdiff.sh baseline --force <test|--all-mf>
#                                    same, allowing overwrite (use only when
#                                    you deliberately mean to re-baseline,
#                                    e.g. after a confirmed intentional output
#                                    change)
#   outdiff.sh check <test>          re-run, normalize, diff against the
#                                    stored baseline; exit non-zero + print a
#                                    unified diff on any difference
#   outdiff.sh check --all-mf        run `check` for every baselined test,
#                                    summarizing pass/fail per test
#   outdiff.sh levels <test>         GATE B step 2 support: count records by
#                                    mf severity level in baseline vs current,
#                                    fail if any level's count drops to zero
#                                    when it was non-zero before. See the
#                                    LIMITATION note below.
#   outdiff.sh report                summarize every test with a stored
#                                    baseline: matched / differing / missing
#
# Parallelism: `baseline --all-mf`, `check --all-mf`, and `report` each run
# many independent `ctest -V` invocations (one per test), which is the
# dominant cost and has no correctness reason to be serial -- each test is
# already isolated by ctest's own `-R "^<test>$"` selection. These three run
# their per-test work via `xargs -P` instead of a serial loop. Default
# parallelism is 4 concurrent tests; override with `OUTDIFF_JOBS=<N>` (a
# conservative default, not `nproc`, since this may run on a shared machine
# alongside other users' builds). The environment is activated exactly once,
# in this top-level process, BEFORE any parallel fan-out -- see
# activate_env()'s comment for why concurrent activation is avoided.
#
# OUTPUT FORMAT (current, and what these scripts are calibrated against):
#   Logging.cxx sets pattern  "[LOG-%l] %v"
#   Logging.h   emits         "[in <scope>]: <body>"  (or "[in ?]: " with no scope)
#   => a migrated record's first line reads:
#        [LOG-info] [in geo::WireReadoutGeom::ChannelsIntersect]: channel 7 ...
#      and continuation lines of a multi-line body are emitted BARE.
# normalize.sed rule (1c) strips that decoration; if the format in
# Logging.h/Logging.cxx changes again, rule (1c), extract_prefix_sidecar()
# and do_levels_one()'s [LOG-...] parser must be updated together.
#
# NOTE: the stored baselines predate this format (they are messagefacility
# captures and contain no "[LOG-" lines at all). They remain VALID as the
# "before" side and must NOT be recaptured -- a pre-migration baseline is
# unrecoverable once the source is migrated (F4_GUARDRAILS_PLAN.md finding 6).
# Only the "after" side needed to learn the new format.
#
# `levels` is a REAL comparison in both directions. The earlier bare-`%v`
# pattern carried no level indicator, so a per-level count could not be
# recovered from migrated output; the current "[LOG-%l]" pattern restores it.
# `levels` therefore now reads the level from EITHER messagefacility's
# `%MSG-<x>` banners (pre-migration side) or the `[LOG-<level>]` prefix
# (migrated side), maps them onto a common label, and fails when a level that
# had records in the baseline has none now -- i.e. it directly catches the
# silently-vanished trace/debug regression that PATTERN_CATALOG.md §4.2 calls
# the most likely invisible failure of this migration.
# `check` (the full normalized body diff) remains the authoritative
# per-message detector; `levels` is the cheap, specific check for a whole
# level disappearing. Run both.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # .../spdlog-migration/guardrails

# The mpd project is DISCOVERED from the invocation directory; it is no longer
# derivable from this script's location, because the guard rails now live in
# the larsoft-phlex-adapt repo rather than inside the package being migrated.
# shellcheck source=mpd-paths.sh
source "$SCRIPT_DIR/mpd-paths.sh"
mpd_require                                                      # MPD_ROOT/SRCS/BUILD/LOCAL

SRCS_DIR="$MPD_SRCS"
MPDDEV_DIR="$MPD_ROOT"

BUILD_DIR="$MPD_BUILD"
LOCAL_DIR="$MPD_LOCAL"
ENV_SH="$SCRIPT_DIR/env.sh"
NORMALIZE_SED="$SCRIPT_DIR/normalize.sed"

# Baselines and the target manifest are PER MPD PROJECT. The tooling repo is
# shared between projects, but a baseline is a capture of one project's test
# output: comparing mpddev's "after" against larsoftobj's "before" would be
# meaningless, and silently so. They are therefore namespaced by project name.
#
# Historical note: the original single-project layout kept these flat in
# guardrails/{baselines,targets.tsv}. Those files are the mpddev captures and
# are migrated into baselines/mpddev/ on first use (see migrate_legacy_layout).
BASELINE_DIR="$SCRIPT_DIR/baselines/$MPD_NAME"
TARGETS_TSV="$BASELINE_DIR/targets.tsv"
LEGACY_BASELINE_DIR="$SCRIPT_DIR/baselines"
LEGACY_TARGETS_TSV="$SCRIPT_DIR/targets.tsv"

migrate_legacy_layout() {
  # One-time, idempotent move of the flat single-project layout into the
  # per-project one. Only runs when the flat layout still has capture files.
  shopt -s nullglob
  local legacy=("$LEGACY_BASELINE_DIR"/*.txt)
  shopt -u nullglob
  if [[ ${#legacy[@]} -gt 0 || -f "$LEGACY_TARGETS_TSV" ]]; then
    # The flat captures were taken from mpddev; only adopt them as such.
    local dest="$LEGACY_BASELINE_DIR/mpddev"
    mkdir -p "$dest"
    if [[ ${#legacy[@]} -gt 0 ]]; then
      echo "outdiff: migrating ${#legacy[@]} legacy baseline file(s) -> baselines/mpddev/" >&2
      mv "${legacy[@]}" "$dest/" 2>/dev/null || true
    fi
    if [[ -f "$LEGACY_TARGETS_TSV" ]]; then
      echo "outdiff: migrating legacy targets.tsv -> baselines/mpddev/targets.tsv" >&2
      mv "$LEGACY_TARGETS_TSV" "$dest/targets.tsv" 2>/dev/null || true
    fi
  fi
}
migrate_legacy_layout
mkdir -p "$BASELINE_DIR"

# Conservative default (not `nproc`): this may run on a shared build machine
# alongside other users' work. Override with OUTDIFF_JOBS=<N>.
OUTDIFF_JOBS="${OUTDIFF_JOBS:-4}"

mkdir -p "$BASELINE_DIR"

usage() { sed -n '2,45p' "${BASH_SOURCE[0]}"; }

# --- environment plumbing ----------------------------------------------------
# Activate once per PROCESS, gated on an EXPORTED environment variable rather
# than a plain shell variable: `baseline --all-mf` / `check --all-mf` /
# `report` fan out to worker subprocesses (see "Parallelism" above), each a
# fresh invocation of this same script file, so a plain shell variable would
# not survive across that fork/exec boundary and each worker would re-run
# `spack env activate` concurrently -- a real hazard, since `spack mpd
# select`/`env activate` reads and writes shared per-project state, and
# concurrent activation was exactly the kind of environment fragility
# BUILDING_WITH_SPACK_MPD.md and F4_GUARDRAILS_PLAN.md's G0 finding warn
# about. Activating once in the top-level process and exporting the real PATH
# / LD_LIBRARY_PATH / etc. environment variables it produces means every
# worker subprocess inherits a fully-activated environment for free and this
# sentinel lets each one detect that and skip re-activating.
activate_env() {
  [[ "${OUTDIFF_ENV_READY:-0}" == "1" ]] && return 0
  # shellcheck disable=SC1090
  source "$ENV_SH" >/dev/null 2>&1
  spack env activate "$LOCAL_DIR" >/dev/null 2>&1
  export OUTDIFF_ENV_READY=1
}

run_test_raw() {
  # Runs the named test via ctest -V and prints the per-line-prefixed raw
  # transcript (stdout+stderr merged, as ctest -V captures it) to stdout.
  # Uses ctest itself (not a hand-built command line) so the exact same
  # environment variables / working directory ctest normally provides are
  # honored -- see BUILDING_WITH_SPACK_MPD.md on ctest being the actual test
  # runner underneath `spack mpd test`.
  local test="$1"
  activate_env
  ctest --test-dir "$BUILD_DIR" -R "^${test}\$" -V 2>&1
}

extract_body() {
  # Strip ctest's own "<N>: " per-line test-id prefix, leaving only what the
  # test process itself printed. The prefix number is test-run-specific, so
  # it is matched generically (a leading run of digits then ": ") rather than
  # hardcoded, and only lines carrying that prefix are kept -- this also
  # drops ctest's own before/after summary lines (blank last-column padding,
  # "Start N: ...", pass/fail banner, timing summary), which are ctest
  # process noise, not test output.
  grep -E '^[0-9]+: ' | sed -E 's/^[0-9]+: //'
}

capture_and_normalize() {
  # Prints the fully normalized body for a test run to stdout. Also, as a
  # side effect, writes the extracted-but-not-yet-normalized body to
  # $2 (if given) so callers needing the pre-normalization text (e.g. the
  # `levels` command, which needs the %MSG banners normalize.sed rule 1 would
  # otherwise delete) can inspect it.
  local test="$1"
  local raw_out="${2:-}"
  local raw
  raw="$(run_test_raw "$test" | extract_body)"
  if [[ -n "$raw_out" ]]; then
    printf '%s\n' "$raw" > "$raw_out"
  fi
  printf '%s\n' "$raw" | sed -E -f "$NORMALIZE_SED"
}

extract_prefix_sidecar() {
  # Captures every stripped spdlog scoped-name prefix (normalize.sed rule 2)
  # to a sidecar, per PATTERN_CATALOG.md §2.4: "a WRONG prefix is a real
  # defect worth seeing." Uses the SAME exclusion list as normalize.sed rule 2
  # so it stays in lockstep with what that rule actually strips.
  local raw_file="$1"
  {
    # (a) DECORATED form emitted by the current Logging.h/Logging.cxx:
    #       [LOG-<level>] [in <scope>]: body
    #     Captured as the bare "<scope>: " so sidecars stay comparable with
    #     ones captured before the format change. Kept in lockstep with
    #     normalize.sed rule (1c); if that rule changes, change this too.
    grep -oE '^\[LOG-(trace|debug|info|warning|error|critical)\] \[in [^]]*\]: ' "$raw_file" 2>/dev/null \
      | sed -E 's/^\[LOG-[a-z]+\] \[in //; s/\]: /: /'
    # (b) UNCONFIGURED-logger form (lar::log::setup() never called): same, but
    #     with spdlog's default timestamp+level decoration in front.
    grep -oE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+\] \[(trace|debug|info|warning|error|critical)\] \[in [^]]*\]: ' "$raw_file" 2>/dev/null \
      | sed -E 's/^.*\[in //; s/\]: /: /'
    # (c) LEGACY bare form (normalize.sed rule 2), with the same exclusion list
    #     that rule uses so the sidecar reflects exactly what gets stripped.
    grep -oE '^[A-Za-z_][A-Za-z0-9_:<>~,() ]*: ' "$raw_file" 2>/dev/null \
      | grep -vE '^(Info in <|Environment variable|Working Directory:|Test timeout computed to be:|Test selection:|Geometry file:|Running on detector:|Comparing two wires|Returned wire would be:)'
  } | sort | uniq -c | sort -rn
}

baseline_path() { echo "$BASELINE_DIR/$1.txt"; }
raw_path()      { echo "$BASELINE_DIR/$1.raw.txt"; }
prefix_path()   { echo "$BASELINE_DIR/$1.prefixes.txt"; }

all_mf_tests() {
  [[ -f "$TARGETS_TSV" ]] || { echo "outdiff: $TARGETS_TSV not found -- run gen-targets.sh first" >&2; exit 2; }
  awk -F'\t' 'NR>1 && $5=="1" {print $1}' "$TARGETS_TSV"
}

do_baseline_one() {
  local test="$1"
  local force="$2"
  local bpath rpath ppath
  bpath="$(baseline_path "$test")"
  rpath="$(raw_path "$test")"
  ppath="$(prefix_path "$test")"

  if [[ -e "$bpath" && "$force" -ne 1 ]]; then
    echo "outdiff baseline: SKIP $test -- baseline already exists (use --force to overwrite)"
    return 0
  fi

  echo "outdiff baseline: capturing $test ..."
  local norm
  norm="$(capture_and_normalize "$test" "$rpath")"
  printf '%s\n' "$norm" > "$bpath"
  extract_prefix_sidecar "$rpath" > "$ppath"
  echo "outdiff baseline: stored $bpath ($(wc -l < "$bpath") lines)"
}

do_check_one() {
  local test="$1"
  local bpath rpath
  bpath="$(baseline_path "$test")"
  rpath="$(mktemp)"

  if [[ ! -e "$bpath" ]]; then
    echo "outdiff check: $test -- NO BASELINE (run: outdiff.sh baseline $test)"
    rm -f "$rpath"
    return 2
  fi

  local norm
  norm="$(capture_and_normalize "$test" "$rpath")"
  local cur
  cur="$(mktemp)"
  printf '%s\n' "$norm" > "$cur"

  # Reapply the current normalization rules to stored baselines as well as
  # current captures. Baselines may have been created before a newly approved
  # normalization rule was added (for example, the MessageFacility started. ->
  # Logging started. rename); applying the rules only to the current side
  # would make an approved equivalent change appear different until every
  # baseline was destructively regenerated.
  local base_norm
  base_norm="$(mktemp)"
  sed -E -f "$NORMALIZE_SED" "$bpath" > "$base_norm"

  local difftmp
  difftmp="$(mktemp)"
  if diff -u "$base_norm" "$cur" > "$difftmp"; then
    echo "outdiff check: $test -- MATCH"
    rm -f "$cur" "$rpath" "$base_norm" "$difftmp"
    return 0
  else
    echo "outdiff check: $test -- DIFFERS"
    cat "$difftmp"
    rm -f "$cur" "$rpath" "$base_norm" "$difftmp"
    return 1
  fi
}

do_levels_one() {
  local test="$1"
  local braw="$(raw_path "$test")"
  if [[ ! -e "$braw" ]]; then
    echo "outdiff levels: $test -- NO BASELINE RAW CAPTURE (run: outdiff.sh baseline $test)"
    return 2
  fi

  echo "outdiff levels: $test"
  echo "  -- baseline level counts (from %MSG-<x> banners) --"
  local base_counts
  base_counts="$(grep -oE '^%MSG-[a-zA-Z] ' "$braw" | sort | uniq -c || true)"
  if [[ -z "$base_counts" ]]; then
    echo "     (no %MSG banners in baseline -- was this test already migrated when baselined?)"
  else
    echo "$base_counts" | sed 's/^/     /'
  fi

  local craw
  craw="$(mktemp)"
  run_test_raw "$test" | extract_body > "$craw"

  # Current-side counts come from EITHER form:
  #  - pre-migration, still-mf code:  %MSG-<x> banners (as the baseline);
  #  - migrated code: the "[LOG-<level>]" record prefix emitted by the current
  #    Logging.cxx pattern ("[LOG-%l] %v").
  # The second case is why this check is now a real comparison rather than the
  # no-op it was under the earlier bare-%v pattern: the level IS recoverable
  # from migrated output, so a silently vanished trace/debug level
  # (PATTERN_CATALOG.md §4.2 -- "the most likely invisible regression") is
  # caught here directly instead of only indirectly via the body diff.
  #
  # spdlog level names are mapped onto mf's severity letters so the two sides
  # are comparable. Mapping (mf letter <- spdlog level):
  #     i <- info          w <- warning      e <- error
  #     d <- debug, trace  s <- critical
  # mf emits both debug and trace as %MSG-d, so they are merged here too;
  # that makes this check conservative (it cannot tell trace from debug), and
  # the authoritative per-message detector remains `outdiff.sh check`.
  echo "  -- current level counts (from %MSG-<x> banners and/or [LOG-<level>]) --"
  local cur_counts
  cur_counts="$(
    {
      grep -oE '^%MSG-[a-zA-Z] ' "$craw" 2>/dev/null | sed -E 's/^%MSG-([a-zA-Z]) /\1/'
      grep -oE '^\[LOG-(trace|debug|info|warning|error|critical)\] ' "$craw" 2>/dev/null \
        | sed -E 's/^\[LOG-//; s/\] $//' \
        | sed -E 's/^info$/i/; s/^warning$/w/; s/^error$/e/; s/^debug$/d/; s/^trace$/d/; s/^critical$/s/'
    } | sort | uniq -c || true
  )"
  # Re-render to the "%MSG-<x> " shape the baseline side uses, so the
  # comparison loop below sees identical labels on both sides.
  cur_counts="$(echo "$cur_counts" | awk 'NF==2 {printf "%7d %%MSG-%s \n", $1, $2}')"
  if [[ -z "${cur_counts//[[:space:]]/}" ]]; then
    echo "     none found."
    echo "     This means the test emitted NO level-tagged records at all, in"
    echo "     either format. If the baseline had records, the comparison below"
    echo "     will FAIL -- which is the intended behaviour, not a limitation."
    cur_counts=""
  else
    echo "$cur_counts" | sed 's/^/     /'
  fi

  # Compare: any baseline level with count>0 that is now 0 or absent is a FAIL.
  local fail=0
  while read -r cnt lvl; do
    [[ -z "$lvl" ]] && continue
    local cur_cnt
    cur_cnt="$(echo "$cur_counts" | awk -v l="$lvl" '$2==l {print $1}')"
    cur_cnt="${cur_cnt:-0}"
    if [[ "$cnt" -gt 0 && "$cur_cnt" -eq 0 ]]; then
      echo "  FAIL: level '$lvl' had $cnt record(s) in baseline, 0 now."
      fail=1
    fi
  done <<< "$base_counts"

  rm -f "$craw"
  if (( fail )); then
    echo "outdiff levels: $test -- FAIL (a level's records vanished)"
    return 1
  else
    echo "outdiff levels: $test -- PASS"
    return 0
  fi
}

list_baselined_tests() {
  local bpath test
  for bpath in "$BASELINE_DIR"/*.txt; do
    [[ -e "$bpath" ]] || continue
    [[ "$bpath" == *.raw.txt || "$bpath" == *.prefixes.txt ]] && continue
    test="$(basename "$bpath" .txt)"
    echo "$test"
  done
}

# --- parallel dispatch --------------------------------------------------
#
# `baseline --all-mf`, `check --all-mf`, and `report` all fan out per-test
# work via `xargs -P` (see "Parallelism" in the header comment). Each worker
# is a fresh re-exec of THIS SCRIPT (argv, no shell string interpolation --
# test names go through as plain argv arguments, never substituted into a
# `bash -c` string), so there is no in-process function to share; instead
# each worker writes its full stdout+stderr and exit code to files in a
# per-run scratch directory, and the parent reads those back AFTER `xargs`
# has waited for every worker to finish, printing them in stable, original
# test-list order. This keeps concurrent ctest runs from interleaving their
# output (xargs -P gives no ordering or atomicity guarantee across children's
# stdout) while still parallelizing the actual expensive work.
safe_name() {
  # Defensive filename sanitization for the scratch-file path -- ctest test
  # names observed in this tree are plain identifiers (letters, digits, `_`),
  # but this guards against a future test name containing a path separator
  # from escaping the scratch directory.
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

make_scratch_dir() {
  mktemp -d
}

run_parallel_worker_subcommand() {
  # $1 = worker subcommand (e.g. __worker-check), remaining args appended
  # after each test name read from stdin (one test per line).
  local worker="$1"
  shift
  xargs -P "$OUTDIFF_JOBS" -I{} "$SCRIPT_DIR/outdiff.sh" "$worker" "$@" {}
}

do_report() {
  activate_env
  local scratch
  scratch="$(make_scratch_dir)"
  trap 'rm -rf "$scratch"' RETURN

  mapfile -t tests < <(list_baselined_tests)
  if [[ ${#tests[@]} -eq 0 ]]; then
    echo "outdiff report: matched=0 differing=0 missing=0 (no baselines found)"
    return 0
  fi

  printf '%s\n' "${tests[@]}" \
    | OUTDIFF_SCRATCH="$scratch" run_parallel_worker_subcommand __worker-check-tofile

  local matched=0 differing=0 missing=0
  local t safe rc
  for t in "${tests[@]}"; do
    safe="$(safe_name "$t")"
    rc="$(cat "$scratch/$safe.rc" 2>/dev/null || echo 3)"
    case "$rc" in
      0) matched=$((matched+1)) ;;
      2) missing=$((missing+1)) ;;
      *) differing=$((differing+1)) ;;
    esac
  done
  echo "outdiff report: matched=$matched differing=$differing missing=$missing"
}

# --- parallel "--all-mf" drivers for baseline / check --------------------
#
# Same scratch-directory pattern as do_report: fan out via xargs -P, have
# each worker capture its own output+exit code to a file, then the parent
# replays them in the ORIGINAL test-list order once every worker has
# finished. This avoids interleaved output from concurrent `ctest -V` runs
# while still doing the actual work in parallel.

do_baseline_all_mf() {
  local force="$1"
  activate_env
  local scratch
  scratch="$(make_scratch_dir)"
  trap 'rm -rf "$scratch"' RETURN

  mapfile -t tests < <(all_mf_tests)
  if [[ ${#tests[@]} -eq 0 ]]; then
    echo "outdiff baseline: no has_mf_sites=1 tests in $TARGETS_TSV"
    return 0
  fi

  printf '%s\n' "${tests[@]}" \
    | OUTDIFF_SCRATCH="$scratch" run_parallel_worker_subcommand __worker-baseline-tofile "$force"

  local t safe
  for t in "${tests[@]}"; do
    safe="$(safe_name "$t")"
    [[ -e "$scratch/$safe.out" ]] && cat "$scratch/$safe.out"
  done
}

do_check_all_mf() {
  activate_env
  local scratch
  scratch="$(make_scratch_dir)"
  trap 'rm -rf "$scratch"' RETURN

  mapfile -t tests < <(all_mf_tests)
  if [[ ${#tests[@]} -eq 0 ]]; then
    echo "outdiff check: no has_mf_sites=1 tests in $TARGETS_TSV"
    return 0
  fi

  printf '%s\n' "${tests[@]}" \
    | OUTDIFF_SCRATCH="$scratch" run_parallel_worker_subcommand __worker-check-tofile

  local fail=0
  local t safe rc
  for t in "${tests[@]}"; do
    safe="$(safe_name "$t")"
    [[ -e "$scratch/$safe.out" ]] && cat "$scratch/$safe.out"
    rc="$(cat "$scratch/$safe.rc" 2>/dev/null || echo 3)"
    [[ "$rc" != "0" ]] && fail=1
  done
  return $fail
}

# --- main ---------------------------------------------------------------

cmd="${1:-}"
[[ -z "$cmd" ]] && { usage; exit 2; }
shift || true

case "$cmd" in
  # Hidden internal worker subcommands, invoked only via xargs re-exec of
  # this same script from run_parallel_worker_subcommand -- not part of the
  # documented CLI. Each writes its captured output/exit-code pair to
  # $OUTDIFF_SCRATCH (inherited from the parent's environment) so the parent
  # can replay results in stable order after all workers finish.
  __worker-baseline-tofile)
    force="$1"; test="$2"
    safe="$(safe_name "$test")"
    out="$(do_baseline_one "$test" "$force" 2>&1)"
    rc=$?
    printf '%s\n' "$out" > "$OUTDIFF_SCRATCH/$safe.out"
    echo "$rc" > "$OUTDIFF_SCRATCH/$safe.rc"
    ;;
  __worker-check-tofile)
    test="$1"
    safe="$(safe_name "$test")"
    out="$(do_check_one "$test" 2>&1)"
    rc=$?
    printf '%s\n' "$out" > "$OUTDIFF_SCRATCH/$safe.out"
    echo "$rc" > "$OUTDIFF_SCRATCH/$safe.rc"
    ;;
  baseline)
    force=0
    if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
    target="${1:-}"
    [[ -z "$target" ]] && { echo "ERROR: baseline requires <test> or --all-mf" >&2; exit 2; }
    if [[ "$target" == "--all-mf" ]]; then
      do_baseline_all_mf "$force"
    else
      do_baseline_one "$target" "$force"
    fi
    ;;
  check)
    target="${1:-}"
    [[ -z "$target" ]] && { echo "ERROR: check requires <test> or --all-mf" >&2; exit 2; }
    if [[ "$target" == "--all-mf" ]]; then
      do_check_all_mf
      exit $?
    else
      do_check_one "$target"
    fi
    ;;
  levels)
    target="${1:-}"
    [[ -z "$target" ]] && { echo "ERROR: levels requires <test>" >&2; exit 2; }
    do_levels_one "$target"
    ;;
  report)
    do_report
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "ERROR: unknown command '$cmd'" >&2
    usage
    exit 2
    ;;
esac
