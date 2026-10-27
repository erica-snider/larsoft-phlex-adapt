#!/usr/bin/env bash
#
# Shared mpd project discovery for the spdlog-migration guard rails.
#
# WHY THIS EXISTS
# ---------------
# These scripts used to live inside the package being migrated
# (.../mpddev/srcs/larcorealg/spdlog-migration/guardrails/) and derived every
# path by walking UP a fixed number of levels:
#
#     SRCS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"     # .../mpddev/srcs
#
# They now live in a SEPARATE repository (larsoft-phlex-adapt), outside any mpd
# project, so that walk lands on an unrelated directory and every default path
# is wrong. Worse, it is wrong SILENTLY: the scripts would scan nothing and
# report success.
#
# There is also now more than one mpd project side by side (e.g. mpddev and
# larsoftobj), each with the same srcs/build/local layout, so a hardcoded
# project name is not good enough either.
#
# WHAT IT DOES
# ------------
# Discovers the mpd project from the INVOCATION directory (or an explicit
# override), not from where this script is installed. An mpd project root is a
# directory containing all of:
#     srcs/   local/spack.yaml   build/
#
# Resolution order (first match wins):
#   1. $MPD_PROJECT            -- explicit project root, or a project NAME that
#                                 is a sibling of the other known projects
#   2. walk up from $PWD       -- the normal case: you are inside
#                                 <project>/srcs/<package>/... when you invoke
#                                 the workflow
#   3. walk up from $MPD_START -- caller-supplied starting point (used when a
#                                 script needs to resolve relative to a target
#                                 path argument rather than $PWD)
#
# If no project is found, every function here FAILS LOUDLY with the directories
# it tried. A guard rail that cannot find the tree it is guarding must never
# quietly scan nothing.
#
# USAGE (bash)
#   source "$(dirname "${BASH_SOURCE[0]}")/mpd-paths.sh"
#   mpd_resolve || exit 1          # sets MPD_ROOT, MPD_SRCS, MPD_BUILD, MPD_LOCAL
#
# USAGE (other languages, e.g. gen-targets.sh's python)
#   eval "$(mpd-paths.sh --export)"            # prints KEY=VALUE lines
#   mpd-paths.sh --print root|srcs|build|local # prints one path
#
# The guard rails' OWN location (this repo) is exposed separately as
# MIGRATION_DIR / GUARDRAILS_DIR, because the two are now independent: the
# tooling lives in one repo and the code being migrated lives in another.

# NOTE: no `set -u` here -- this file is sourced into callers that set their own
# shell options, and clobbering them would be surprising.

# --- where the tooling itself lives (this repo) -----------------------------
GUARDRAILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATION_DIR="$(cd "$GUARDRAILS_DIR/.." && pwd)"        # .../spdlog-migration
PROCEDURES_DIR="$MIGRATION_DIR/procedures"
PROTOTYPES_DIR="$MIGRATION_DIR/prototypes"
PLANS_DIR="$MIGRATION_DIR/plans"
export GUARDRAILS_DIR MIGRATION_DIR PROCEDURES_DIR PROTOTYPES_DIR PLANS_DIR

# The packages this migration covers, in dependency order (F5).
# larcoreobj first: it hosts the replacement logging header.
MPD_PACKAGES=(larcoreobj larcorealg lardataobj lardataalg)

mpd_is_project_root() {
  # An mpd project root has srcs/, local/spack.yaml and build/.
  [[ -n "${1:-}" && -d "$1/srcs" && -f "$1/local/spack.yaml" && -d "$1/build" ]]
}

mpd_find_up() {
  # Walk up from $1 looking for an mpd project root. Prints it, or returns 1.
  local d
  d="$(cd "${1:-.}" 2>/dev/null && pwd)" || return 1
  while [[ -n "$d" && "$d" != "/" ]]; do
    if mpd_is_project_root "$d"; then
      printf '%s\n' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  return 1
}

mpd_resolve() {
  # Sets and exports MPD_ROOT / MPD_SRCS / MPD_BUILD / MPD_LOCAL / MPD_NAME.
  # Returns 1 (with an explanation on stderr) if no project can be found.
  local root=""

  if [[ -n "${MPD_PROJECT:-}" ]]; then
    if mpd_is_project_root "$MPD_PROJECT"; then
      root="$(cd "$MPD_PROJECT" && pwd)"
    else
      # Allow a bare project NAME, resolved as a sibling of any project we can
      # find from here (so `MPD_PROJECT=larsoftobj` works from inside mpddev).
      local anchor
      if anchor="$(mpd_find_up "$PWD")"; then
        local cand="$(dirname "$anchor")/$MPD_PROJECT"
        mpd_is_project_root "$cand" && root="$(cd "$cand" && pwd)"
      fi
    fi
    if [[ -z "$root" ]]; then
      echo "mpd-paths: MPD_PROJECT='$MPD_PROJECT' is not an mpd project root" >&2
      echo "           (needs srcs/, local/spack.yaml and build/)" >&2
      return 1
    fi
  fi

  if [[ -z "$root" ]]; then
    root="$(mpd_find_up "${MPD_START:-$PWD}")" || true
  fi

  if [[ -z "$root" ]]; then
    echo "mpd-paths: could not locate an mpd project." >&2
    echo "  Looked upward from: ${MPD_START:-$PWD}" >&2
    echo "  An mpd project root must contain: srcs/  local/spack.yaml  build/" >&2
    echo "  Run this from inside an mpd project (e.g. <project>/srcs/<package>)," >&2
    echo "  or set MPD_PROJECT=/abs/path/to/project (or a project name)." >&2
    return 1
  fi

  MPD_ROOT="$root"
  MPD_NAME="$(basename "$root")"
  MPD_SRCS="${MPD_SRCS_OVERRIDE:-$root/srcs}"
  MPD_BUILD="${BUILD_DIR:-$root/build}"
  MPD_LOCAL="${LOCAL_DIR:-$root/local}"
  export MPD_ROOT MPD_NAME MPD_SRCS MPD_BUILD MPD_LOCAL
  return 0
}

mpd_require() {
  # mpd_resolve or die -- for scripts that cannot do anything useful without it.
  mpd_resolve || exit 1
}

# --- CLI mode, for non-bash consumers ---------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:---export}" in
    --export)
      mpd_resolve || exit 1
      printf 'MPD_ROOT=%s\n'       "$MPD_ROOT"
      printf 'MPD_NAME=%s\n'       "$MPD_NAME"
      printf 'MPD_SRCS=%s\n'       "$MPD_SRCS"
      printf 'MPD_BUILD=%s\n'      "$MPD_BUILD"
      printf 'MPD_LOCAL=%s\n'      "$MPD_LOCAL"
      printf 'MIGRATION_DIR=%s\n'  "$MIGRATION_DIR"
      printf 'GUARDRAILS_DIR=%s\n' "$GUARDRAILS_DIR"
      ;;
    --print)
      mpd_resolve || exit 1
      case "${2:-root}" in
        root)       printf '%s\n' "$MPD_ROOT"  ;;
        name)       printf '%s\n' "$MPD_NAME"  ;;
        srcs)       printf '%s\n' "$MPD_SRCS"  ;;
        build)      printf '%s\n' "$MPD_BUILD" ;;
        local)      printf '%s\n' "$MPD_LOCAL" ;;
        migration)  printf '%s\n' "$MIGRATION_DIR" ;;
        guardrails) printf '%s\n' "$GUARDRAILS_DIR" ;;
        *) echo "mpd-paths: unknown key '${2:-}'" >&2; exit 2 ;;
      esac
      ;;
    --check)
      if mpd_resolve; then
        echo "mpd project : $MPD_NAME"
        echo "  root      : $MPD_ROOT"
        echo "  srcs      : $MPD_SRCS"
        echo "  build     : $MPD_BUILD   $([[ -d $MPD_BUILD ]] && echo OK || echo MISSING)"
        echo "  local     : $MPD_LOCAL   $([[ -f $MPD_LOCAL/spack.yaml ]] && echo OK || echo MISSING)"
        echo "tooling"
        echo "  migration : $MIGRATION_DIR"
        echo "  guardrails: $GUARDRAILS_DIR"
      else
        exit 1
      fi
      ;;
    -h|--help)
      sed -n '2,60p' "${BASH_SOURCE[0]}"
      ;;
    *)
      echo "mpd-paths: unknown option '$1' (try --check, --export, --print <key>)" >&2
      exit 2
      ;;
  esac
fi
