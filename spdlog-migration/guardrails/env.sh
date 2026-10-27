# Build/test environment activation for the spdlog-migration guard rails.
#
# SOURCE this file; do not execute it.
#     source <...>/spdlog-migration/guardrails/env.sh
#
# It discovers the mpd project from your CURRENT DIRECTORY (see mpd-paths.sh),
# so run it from inside the project you intend to work on -- normally
# <project>/srcs/<package>. Override with MPD_PROJECT=<name|abs path>.
#
# Previously this file hardcoded `spack mpd select mpddev` and an absolute path
# to the subspack checkout. Both are wrong now that the tooling lives in a
# separate repository and more than one mpd project exists side by side; a
# hardcoded project would silently build/test the WRONG tree.
#
# See procedures/BUILDING_WITH_SPACK_MPD.md.

# --- locate the project ------------------------------------------------------
_env_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mpd-paths.sh
source "$_env_sh_dir/mpd-paths.sh"

if ! mpd_resolve; then
  echo "env.sh: not activating anything." >&2
  return 1 2>/dev/null || exit 1
fi

echo "env.sh: mpd project '$MPD_NAME' at $MPD_ROOT"

# --- spack bootstrap ---------------------------------------------------------
# The spack instance is normally a sibling of the mpd projects (…/subspack).
# SPACK_SETUP may be set explicitly to point elsewhere.
_mpd_parent="$(dirname "$MPD_ROOT")"
_spack_setup="${SPACK_SETUP:-}"
if [[ -z "$_spack_setup" ]]; then
  for _cand in "$_mpd_parent/subspack/setup-env.sh" \
               "$_mpd_parent/spack/share/spack/setup-env.sh"; do
    [[ -f "$_cand" ]] && { _spack_setup="$_cand"; break; }
  done
fi

if [[ -z "$_spack_setup" || ! -f "$_spack_setup" ]]; then
  echo "env.sh: could not find the spack setup script." >&2
  echo "        Looked under: $_mpd_parent" >&2
  echo "        Set SPACK_SETUP=/abs/path/to/setup-env.sh and re-source." >&2
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
source "$_spack_setup"

# --- select the project and activate its environment -------------------------
# `spack mpd select` takes the project NAME; the environment lives in local/.
spack mpd select "$MPD_NAME" >/dev/null 2>&1 \
  || echo "env.sh: WARNING -- 'spack mpd select $MPD_NAME' failed (continuing)" >&2
spack env activate "$MPD_LOCAL" \
  || { echo "env.sh: 'spack env activate $MPD_LOCAL' FAILED" >&2
       return 1 2>/dev/null || exit 1; }

# --- sanity check ------------------------------------------------------------
# BUILDING_WITH_SPACK_MPD.md: gcc 12.5.0 is required; anything else means the
# environment is wrong and you must stop rather than build against it.
_gcc_ver="$(gcc --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [[ "$_gcc_ver" != "12.5.0" ]]; then
  echo "env.sh: WARNING -- gcc is '${_gcc_ver:-not found}', expected 12.5.0." >&2
  echo "        The environment is not set up correctly; STOP and fix it" >&2
  echo "        before building or trusting any guard-rail result." >&2
fi

echo "env.sh: activated $MPD_LOCAL (gcc ${_gcc_ver:-unknown})"

unset _env_sh_dir _mpd_parent _spack_setup _cand _gcc_ver
