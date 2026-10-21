#!/usr/bin/env bash
#
# G2 format-string lint (spdlog-migration/F4_GUARDRAILS_PLAN.md, PATTERN_CATALOG.md §1.1).
#
# Flags any spdlog::(trace|debug|info|warn|error|critical|log) call whose format
# argument is not a string literal -- the hazard that fails only at RUNTIME, and
# only for messages containing a literal '{' (see prototypes/02-*).
#
# This is a regex check, not a parser (documented limitation, see below): it is a
# net, not a proof. The real protection is that lar::log::LogStream (the LAR_LOG_*
# macros) is the only sanctioned call-site path, verified by the F3 foundation
# test. This lint exists to catch a hand-written spdlog:: call that bypasses it.
#
# Usage:
#   format-string-lint.sh [path ...]   lint the given files/dirs (default: the
#                                       four package source trees plus the
#                                       guardrails' own regression fixture)
#
# Waiver: a call may be preceded (on the line directly above, or trailing on the
# same line) by:
#     // spdlog-format-ok: <reason>
# which suppresses that one finding. Use this to annotate Logging.cxx's own two
# correct-but-non-literal-looking call sites rather than special-casing by path.
#
# Known-bad shapes explicitly flagged (all found in the wild in past reviews):
#   - a bare identifier / variable:            spdlog::info(body);
#   - a `.str()` call:                         spdlog::info(oss.str());
#   - string concatenation:                    spdlog::info(s + " x", 1);
#   - a bare identifier as spdlog::log's 2nd arg (after the level):
#                                               spdlog::log(lvl, body);
#
# Known limitation (stated per F4_GUARDRAILS_PLAN.md G2 step 5): this is a
# line-oriented regex check. A call whose format argument is split across
# multiple lines in an unusual way (not the common "call(\n  arg1,\n  arg2)"
# vertical style, which IS handled -- see below) may not be recognized. It is a
# net, not a proof.
#
# Two-sided acceptance (F4_GUARDRAILS_PLAN.md G2 step 6), run via --self-test:
#   - larcoreobj/larcoreobj/LoggingUtil/Logging.cxx must come back CLEAN;
#   - prototypes/02-runtime-format-string-hazard.cxx must be FLAGGED. A lint
#     that cannot detect the one file written to demonstrate the bug is not a
#     lint; this file is the permanent regression fixture.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"          # .../mpddev/srcs
MIGRATION_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"           # .../spdlog-migration

PACKAGES=(larcoreobj larcorealg lardataobj lardataalg)

LOGGING_CXX="$SRCS_DIR/larcoreobj/larcoreobj/LoggingUtil/Logging.cxx"
HAZARD_FIXTURE="$MIGRATION_DIR/prototypes/02-runtime-format-string-hazard.cxx"

CALL_RE='spdlog::(trace|debug|info|warn|error|critical|log)[[:space:]]*\('

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}"; }

self_test=0
declare -a targets=()

while (( $# )); do
  case "$1" in
    --self-test) self_test=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) targets+=("$1"); shift ;;
  esac
done

if [[ $self_test -eq 1 ]]; then
  echo "== G2 self-test: two-sided acceptance =="
  echo
  echo "-- expect CLEAN: $LOGGING_CXX"
  if "${BASH_SOURCE[0]}" "$LOGGING_CXX"; then
    echo "   ok (clean, as required)"
    clean_ok=1
  else
    echo "   FAIL: Logging.cxx should be clean but was flagged"
    clean_ok=0
  fi
  echo
  echo "-- expect FLAGGED: $HAZARD_FIXTURE"
  if "${BASH_SOURCE[0]}" "$HAZARD_FIXTURE"; then
    echo "   FAIL: the hazard fixture should be flagged but was reported clean"
    hazard_ok=0
  else
    echo "   ok (flagged, as required)"
    hazard_ok=1
  fi
  echo
  if [[ $clean_ok -eq 1 && $hazard_ok -eq 1 ]]; then
    echo "G2 self-test: PASSED"
    exit 0
  else
    echo "G2 self-test: FAILED"
    exit 1
  fi
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  for p in "${PACKAGES[@]}"; do
    [[ -d "$SRCS_DIR/$p" ]] && targets+=("$SRCS_DIR/$p")
  done
fi

# Collect candidate files (.h .hh .hpp .cxx .cc .cpp), excluding the migration
# scaffolding directory itself UNLESS it was named explicitly on the command
# line (so --self-test / explicit fixture linting still works).
declare -a files=()
for t in "${targets[@]}"; do
  if [[ -f "$t" ]]; then
    files+=("$t")
  elif [[ -d "$t" ]]; then
    while IFS= read -r -d '' f; do
      files+=("$f")
    done < <(find "$t" \( -path '*/spdlog-migration/*' -o -path '*/build/*' -o -path '*/.git/*' \) -prune -o \
                   -type f \( -name '*.h' -o -name '*.hh' -o -name '*.hpp' \
                              -o -name '*.cxx' -o -name '*.cc' -o -name '*.cpp' \) -print0)
  fi
done

fail=0
findings=0

is_literal_start() {
  # True if $1 (the text right after the opening paren, possibly after a level
  # expression for spdlog::log) begins with a string literal: an optional
  # leading whitespace then a double quote.
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"   # trim leading whitespace
  [[ "$s" == \"* ]]
}

for f in "${files[@]}"; do
  # mapfile the whole file so we can look at "the line before" for a waiver
  # comment and so a call's argument list can be re-joined across up to a
  # handful of continuation lines (the common vertical cet_test/cet_make style
  # this repo actually uses -- see PATTERN_CATALOG.md §5.1 on wrapped statements).
  mapfile -t lines < "$f"
  n=${#lines[@]}

  for (( i = 0; i < n; i++ )); do
    line="${lines[$i]}"

    # Skip a line that is pure comment (// ... or already inside a /* */ block
    # up to the match) -- a prose mention like "spdlog::log()/should_log()"
    # inside a comment is not a call site. This only strips a leading "//"
    # comment; a code line with a trailing "// comment" still matches on its
    # code portion, which is what we want.
    code_part="$line"
    if [[ "$line" =~ ^[[:space:]]*//  ]]; then
      continue
    fi
    # Strip a trailing // comment before matching, so a real call followed by
    # an explanatory comment isn't confused, and so a comment-only occurrence
    # of "spdlog::log(...)" text after // on an otherwise-code line is ignored.
    code_part="${line%%//*}"

    [[ "$code_part" =~ $CALL_RE ]] || continue

    func="${BASH_REMATCH[1]}"

    # Reject a zero-argument mention like "spdlog::log()" (used only in prose
    # to name the function, e.g. "spdlog::log()/should_log()") -- a real call
    # always has at least a level argument.
    if [[ "$code_part" =~ spdlog::${func}[[:space:]]*\([[:space:]]*\) ]]; then
      continue
    fi

    # Waived on this line (trailing comment) or the line above?
    waived=0
    if [[ "$line" == *"spdlog-format-ok:"* ]]; then waived=1; fi
    if (( i > 0 )) && [[ "${lines[$((i-1))]}" == *"spdlog-format-ok:"* ]]; then waived=1; fi
    if (( waived )); then continue; fi

    # Re-join this line with up to 5 following lines so a wrapped call's first
    # argument can be inspected even when the '(' is followed by a newline.
    joined="$line"
    j=$i
    while [[ "$joined" != *')'* ]] && (( j < n - 1 )) && (( j - i < 5 )); do
      ((j++))
      joined+=" ${lines[$j]}"
    done

    # Extract everything after the matched "spdlog::func(" opening paren.
    after="${joined#*"${func}"}"
    after="${after#*(}"

    if [[ "$func" == "log" ]]; then
      # spdlog::log(level, fmt, ...): skip the first (level) argument by
      # cutting at the first top-level comma. This is line-oriented, so it
      # uses a simple first-comma heuristic -- adequate because level
      # expressions in this codebase are short enums, never containing commas
      # or nested calls with commas (documented limitation, see header).
      after="${after#*,}"
    fi

    if ! is_literal_start "$after"; then
      echo "$f:$((i+1)): spdlog::$func(...) format argument is not a string literal"
      echo "    ${line#"${line%%[![:space:]]*}"}"
      findings=$((findings+1))
      fail=1
    fi
  done
done

echo
if (( fail )); then
  echo "format-string-lint: FAIL -- $findings non-literal format argument(s) found."
  echo "See PATTERN_CATALOG.md §1.1: passing a runtime string as the format string"
  echo "fails at RUNTIME for any message containing a literal '{'. Fix by passing"
  echo "the composed text as an ARGUMENT: spdlog::info(\"{}\", composed_text)."
  echo "If this is a deliberately-reviewed exception, annotate the line above with:"
  echo "    // spdlog-format-ok: <reason>"
  exit 1
else
  echo "format-string-lint: PASS -- no non-literal spdlog:: format arguments found."
  exit 0
fi
