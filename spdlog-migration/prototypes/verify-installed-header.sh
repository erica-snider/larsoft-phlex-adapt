#!/bin/bash
#
# Compile and run 12-installed-header-F3-checklist.cxx against the REAL installed
# header (larcoreobj/LoggingUtil/Logging.h) and the compiled spdlog library.
#
# This is the PROCEDURE.md F3 gate: "foundation test green". Run it before
# starting any migration, and after any edit to Logging.h / Logging.cxx.
#
# Unlike build-and-run.sh (which compiles header-only and works with the system
# compiler), this links libspdlog.so and therefore needs the same gcc the library
# was built with: the system g++ 11.5 lacks GLIBCXX_3.4.30 and fails at link time.
#
# Usage:  ./verify-installed-header.sh
# Env:    SPDLOG_DIR, GCC_DIR, SRCS_DIR to override the cvmfs/source locations.

set -u

SPDLOG_DIR="${SPDLOG_DIR:-$(spack location -i spdlog 2>/dev/null || true)}"
FMT_DIR="${FMT_DIR:-$(spack location -i fmt 2>/dev/null || true)}"
GCC_DIR="${GCC_DIR:-$(spack location -i gcc@12.5.0 2>/dev/null || true)}"
# SRCS_DIR is discovered from the invocation directory (this script now lives
# in the larsoft-phlex-adapt tooling repo, outside any mpd project), unless
# overridden explicitly. See guardrails/mpd-paths.sh.
if [[ -z "${SRCS_DIR:-}" ]]; then
  _proto_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=../guardrails/mpd-paths.sh
  source "$_proto_dir/../guardrails/mpd-paths.sh"
  mpd_resolve || exit 1
  SRCS_DIR="$MPD_SRCS"
fi

LARCOREOBJ="$SRCS_DIR/larcoreobj"
SRC="$(dirname "${BASH_SOURCE[0]}")/12-installed-header-F3-checklist.cxx"

# fmt is OPTIONAL: spdlog may be built with bundled fmt
# (SPDLOG_FMT_EXTERNAL=OFF), in which case spdlog/fmt/bundled/format.h exists
# and there is no separate fmt install to point at. Requiring $FMT_DIR
# unconditionally makes this gate unrunnable against such a build.
USE_EXTERNAL_FMT=0
if [[ -n "${FMT_DIR:-}" && -e "$FMT_DIR/include/fmt/format.h" ]]; then
  USE_EXTERNAL_FMT=1
elif [[ -e "$SPDLOG_DIR/include/spdlog/fmt/bundled/format.h" ]]; then
  USE_EXTERNAL_FMT=0
else
  echo "ERROR: neither an external fmt ($FMT_DIR/include/fmt/format.h) nor a"
  echo "       bundled one ($SPDLOG_DIR/include/spdlog/fmt/bundled/format.h) was found."
  exit 1
fi

for p in "$SPDLOG_DIR/include" \
  "$GCC_DIR/bin/g++" "$LARCOREOBJ/larcoreobj/LoggingUtil/Logging.h"; do
  if [[ ! -e "$p" ]]; then
    echo "ERROR: not found: $p"
    if [[ "$p" == *LoggingUtil* ]]; then
      echo "       The logging header (F2) is not present in this mpd project."
      echo "       srcs: $SRCS_DIR"
    fi
    exit 1
  fi
done

declare -a FMT_CFLAGS=() FMT_LDFLAGS=()
if [[ $USE_EXTERNAL_FMT -eq 1 ]]; then
  FMT_CFLAGS=(-I"$FMT_DIR/include")
  FMT_LDFLAGS=(-L"$FMT_DIR/lib64" -lfmt
               -Wl,-rpath,"$FMT_DIR/lib" -Wl,-rpath,"$FMT_DIR/lib64")
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "=============================================================="
echo "  F3 gate: installed header verification"
echo "=============================================================="
echo "  header:  $LARCOREOBJ/larcoreobj/LoggingUtil/Logging.h"
echo "  srcs:    $SRCS_DIR"
echo "  spdlog:  $SPDLOG_DIR"
if [[ $USE_EXTERNAL_FMT -eq 1 ]]; then
  echo "  fmt:     $FMT_DIR (external)"
else
  echo "  fmt:     bundled with spdlog"
fi
echo "  gcc:     $("$GCC_DIR/bin/g++" --version | head -1)"
echo

"$GCC_DIR/bin/g++" -std=c++17 -Wall -Wextra -pedantic \
  -DSPDLOG_SHARED_LIB -DFMT_SHARED -DSPDLOG_COMPILED_LIB \
  -I"$LARCOREOBJ" -I"$SPDLOG_DIR/include" "${FMT_CFLAGS[@]}" \
  "$SRC" "$LARCOREOBJ/larcoreobj/LoggingUtil/Logging.cxx" \
  -L"$SPDLOG_DIR/lib64" -lspdlog "${FMT_LDFLAGS[@]}" \
  -Wl,-rpath,"$SPDLOG_DIR/lib64" \
  -Wl,-rpath,"$GCC_DIR/lib64" \
  -o "$OUT/verify" 2> "$OUT/build.err"

if [[ $? -ne 0 ]]; then
  echo "!! COMPILE FAILED:"
  sed 's/^/    /' "$OUT/build.err"
  exit 1
fi

if [[ -s "$OUT/build.err" ]]; then
  echo "!! COMPILED WITH WARNINGS (the header must be warning-clean):"
  sed 's/^/    /' "$OUT/build.err"
  exit 1
fi

SINK="$OUT/sink.log"

"$OUT/verify" "$SINK" > "$OUT/run.out" 2>&1
rc=$?
cat "$OUT/run.out"
echo

fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then
    echo "  ok   $1 (expected $2, got $3)"
  else
    echo "  FAIL $1 (expected $2, got $3)"
    fail=1
  fi
}

echo "--- assertions ---"
check "program exit code" 0 "$rc"
check "CASE 12 move emits exactly once" 1 \
  "$(sed -n '/CASE 12/,/CASE 13/p' "$OUT/run.out" | grep -c 'emitted exactly once')"
check "CASE 13+14 emit nothing" 0 \
  "$(sed -n '/CASE 13/,/CASE 15/p' "$OUT/run.out" | grep -vc '^---')"
check "CASE 5 braces survive verbatim" 1 \
  "$(grep -c 'point { 0; 0; 0 }' "$OUT/run.out")"
check "CASE 6 no fmt error" 0 \
  "$(grep -c 'LOG ERROR' "$OUT/run.out")"
check "CASE 19 file sink written" 2 \
  "$(wc -l < "$SINK" | tr -d ' ')"

if (( fail )); then
  echo
  echo "F3 GATE: FAILED"
  exit 1
fi

echo
echo "F3 GATE: PASSED"
