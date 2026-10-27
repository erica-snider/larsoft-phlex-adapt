#!/bin/bash
#
# Build and run the messagefacility -> spdlog migration prototypes.
#
# These are the compile-verification programs behind the design decisions in
# ../../SPDLOG_MIGRATION_PLAN.md (rev 2) and
# ../../SPDLOG_MIGRATION_PLAN_MULTIPACKAGE.md (rev 3).
#
# Usage:  ./build-and-run.sh [name-fragment]
# e.g.    ./build-and-run.sh 09        # just the move-ctor test
#         ./build-and-run.sh           # everything
#
# NOTE: 08-FAILS-* is EXPECTED to fail to compile. That failure is the finding:
#       it proves the rev-2 LogStream cannot satisfy lardataalg's Indenter.

set -u

SPDLOG_DIR="${SPDLOG_DIR:-/cvmfs/larsoft.opensciencegrid.org/spack-packages/opt/spack/linux-almalinux9-x86_64_v2/gcc-12.2.0/spdlog-1.12.0-dwa4wahktue5dmuyodu2bp2rjn6bomnw}"

if [[ ! -d "$SPDLOG_DIR/include" ]]; then
  echo "ERROR: spdlog headers not found at:"
  echo "  $SPDLOG_DIR/include"
  echo "Set SPDLOG_DIR to an spdlog installation (1.12.0 was used originally)."
  exit 1
fi

CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -Wall -Wextra -I$SPDLOG_DIR/include"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

filter="${1:-}"
rc_all=0

for src in $(ls -1 *.cxx | sort); do
  base="${src%.cxx}"
  [[ -n "$filter" && "$base" != *"$filter"* ]] && continue

  # 12 includes the real installed header and links libspdlog, so it needs the
  # gcc that spdlog was built with. It has its own driver.
  if [[ "$base" == 12-* ]]; then
    echo "  (skipping $base -- run ./verify-installed-header.sh instead)"
    echo
    continue
  fi

  echo "=============================================================="
  echo "  $base"
  echo "=============================================================="

  expect_fail=0
  [[ "$base" == *FAILS* ]] && expect_fail=1

  if $CXX $CXXFLAGS "$src" -o "$OUT/$base" 2> "$OUT/$base.err"; then
    if (( expect_fail )); then
      echo "  !! UNEXPECTED: this was expected to FAIL to compile but succeeded."
      rc_all=1
    fi
    "$OUT/$base"
  else
    if (( expect_fail )); then
      echo "  EXPECTED COMPILE FAILURE (this is the finding):"
      grep -m3 'error:' "$OUT/$base.err" | sed 's/^/    /'
    else
      echo "  !! UNEXPECTED COMPILE FAILURE:"
      head -30 "$OUT/$base.err" | sed 's/^/    /'
      rc_all=1
    fi
  fi
  echo
done

exit $rc_all
