#!/usr/bin/env python3
"""
G3.1 manifest generator (spdlog-migration/F4_GUARDRAILS_PLAN.md).

Regenerates guardrails/targets.tsv: the "source file -> ctest test(s)" mapping
that makes the G3 output-diff harness per-file-automatable instead of a
by-hand exercise.

Named .sh per the plan's artifact list, but is a self-contained python3
script (no separate interpreter setup needed beyond python3, which is already
required by the surrounding toolchain). Run directly:

    ./gen-targets.sh                 # regenerate guardrails/targets.tsv
    ./gen-targets.sh --check         # regenerate to a temp file and diff
                                      # against the committed targets.tsv;
                                      # exit non-zero on drift (for CI-style
                                      # "did someone forget to regenerate")
    ./gen-targets.sh --build-dir P --local-dir Q   # override the mpddev
                                      # build/ and local/ directories if this
                                      # script is ever reused against a
                                      # different checkout layout

How it works (no manual per-file bookkeeping -- this is the automation the
per-file requirement in F4_GUARDRAILS_PLAN.md G3.1 asks for):

  1. Activate the spack mpd build/test environment via env.sh + `spack env
     activate`, matching BUILDING_WITH_SPACK_MPD.md.
  2. Ask ctest for every registered test and its launch command
     (`ctest --show-only=json-v1`).
  3. For each test, find its executable in the command line, then walk the
     ninja build graph (`ninja -t query`) outward from that executable:
     direct .o inputs, and any in-build-tree .so it links against, recursing
     into THOSE libraries' .o inputs too. External (cvmfs/system) .so's are
     recorded as linked libs but not recursed into (no local source to map).
  4. For every .o file discovered this way, ninja gives the exact .cxx/.cc
     source that produced it (`ninja -t query <obj>`, first plain line) --
     that source enters the test's "source_files" column.
  5. For the SAME .o files, `ninja -t deps <obj>` gives the exact transitive
     header closure GCC recorded when it last compiled that file. Any header
     in that closure is also attributed to the test -- this is what lets a
     test be marked has_mf_sites=1 even when the mf call lives only in a
     header (e.g. TestUtils/unit_test_base.h), not in the test's own .cxx.
  6. has_mf_sites is 1 iff any attributed source OR header appears in the
     live-site list reported by grep-gate.sh (G1) right now, for the same
     unmigrated tree. Re-running this script after files are migrated will
     correctly flip has_mf_sites to 0 for tests whose mf sites have all been
     migrated -- there is nothing to hand-edit.

Requires: the build tree to already exist and be ninja-generated (true for
`spack mpd build`, per BUILDING_WITH_SPACK_MPD.md), and Python 3.8+.
"""
import json
import os
import subprocess
import sys
import shlex
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent            # .../spdlog-migration/guardrails
MIGRATION_DIR = SCRIPT_DIR.parent                        # .../spdlog-migration
LARCOREALG_DIR = MIGRATION_DIR.parent                     # .../larcorealg
SRCS_DIR = LARCOREALG_DIR.parent                           # .../mpddev/srcs
MPDDEV_DIR = SRCS_DIR.parent                                # .../mpddev

DEFAULT_BUILD_DIR = MPDDEV_DIR / "build"
DEFAULT_LOCAL_DIR = MPDDEV_DIR / "local"
ENV_SH = SCRIPT_DIR / "env.sh"
GREP_GATE = SCRIPT_DIR / "grep-gate.sh"
TARGETS_TSV = SCRIPT_DIR / "targets.tsv"

PACKAGES = ["larcoreobj", "larcorealg", "lardataobj", "lardataalg"]


_ENV_CACHE = {}


def get_activated_env(build_dir: Path, local_dir: Path) -> dict:
    """
    Activate the mpd/spack environment ONCE (source env.sh + spack env
    activate) and capture the resulting environment variables, so every
    subsequent ninja/ctest call is a plain subprocess with that env attached
    instead of re-sourcing spack setup on every single invocation. Sourcing
    spack's setup is the dominant cost (roughly a second each); a BFS over a
    dependency graph makes thousands of ninja calls, so this reduces total
    runtime from hours to seconds.
    """
    key = (str(build_dir), str(local_dir))
    if key in _ENV_CACHE:
        return _ENV_CACHE[key]

    # Print a NUL-separated KEY=VALUE dump after activation so values
    # containing newlines/equals are still parsed correctly.
    marker = "___GEN_TARGETS_ENV_START___"
    full = (
        f"source {shlex.quote(str(ENV_SH))} >/dev/null 2>&1 && "
        f"spack env activate {shlex.quote(str(local_dir))} >/dev/null 2>&1 && "
        f"echo {marker} && env -0"
    )
    proc = subprocess.run(
        ["bash", "-lc", full],
        cwd=str(build_dir),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=False,
    )
    out = proc.stdout
    idx = out.find((marker + "\n").encode())
    if idx == -1 or proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode(errors="replace"))
        raise SystemExit("gen-targets: failed to activate the mpd/spack environment")
    raw = out[idx + len(marker) + 1:]
    env = {}
    for chunk in raw.split(b"\x00"):
        if not chunk:
            continue
        if b"=" not in chunk:
            continue
        k, v = chunk.split(b"=", 1)
        try:
            env[k.decode()] = v.decode()
        except UnicodeDecodeError:
            continue
    _ENV_CACHE[key] = env
    return env


def run_in_env(build_dir: Path, local_dir: Path, cmd: list) -> str:
    """Run `cmd` (an argv list -- no shell) inside the captured mpd/spack env."""
    env = get_activated_env(build_dir, local_dir)
    proc = subprocess.run(
        cmd,
        cwd=str(build_dir),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        raise SystemExit(f"gen-targets: command failed (rc={proc.returncode}): {' '.join(cmd)}")
    return proc.stdout


def get_ctest_json(build_dir: Path, local_dir: Path) -> dict:
    out = run_in_env(build_dir, local_dir, ["ctest", "--show-only=json-v1"])
    # ctest sometimes prints a non-JSON warning line before the JSON on some
    # setups; find the first '{' to be defensive.
    start = out.find("{")
    return json.loads(out[start:])


def ninja_query(build_dir: Path, local_dir: Path, target: str) -> str:
    return run_in_env(build_dir, local_dir, ["ninja", "-t", "query", target])


def parse_query_inputs(query_output: str):
    """Return the list of dependency paths listed under the 'input:' block."""
    deps = []
    in_input = False
    for line in query_output.splitlines():
        if line.strip().startswith("input:"):
            in_input = True
            continue
        if line.strip().startswith("outputs:"):
            break
        if not in_input:
            continue
        s = line.strip()
        if s.startswith("||"):
            s = s[2:].strip()
        elif s.startswith("|"):
            s = s[1:].strip()
        if s:
            deps.append(s)
    return deps


def find_executable_in_command(command: list, build_dir: Path):
    for item in command:
        p = Path(item)
        if not p.is_absolute():
            continue
        try:
            if p.is_file() and os.access(p, os.X_OK) and str(build_dir) in str(p):
                return p
        except OSError:
            continue
    return None


def collect_closure(build_dir: Path, local_dir: Path, exe_target: str, cache: dict):
    """
    BFS outward from the executable target through .o and in-tree .so nodes.
    Returns (objs, libs) where objs is the set of ninja .o targets (relative
    to build_dir) reachable, and libs is the set of .so basenames linked
    (including external ones, recorded but not recursed into).

    NOTE: a .o node is a leaf for this BFS's purposes -- it depends only on
    its source file and headers (both recovered separately, in bulk, from a
    single `ninja -t deps` dump; see load_all_object_deps). We do NOT call
    `ninja -t query` on .o targets here, only on executables and .so targets,
    of which there are ~70 in this tree versus ~300 objects -- this is what
    keeps this script's runtime in seconds rather than requiring one process
    spawn per object.
    """
    visited_targets = set()
    objs = set()
    libs = set()

    frontier = [exe_target]
    while frontier:
        t = frontier.pop()
        if t in visited_targets:
            continue
        visited_targets.add(t)

        if t.endswith(".o"):
            objs.add(t)
            continue  # leaf: do not query further, see docstring

        if t in cache:
            deps = cache[t]
        else:
            out = ninja_query(build_dir, local_dir, t)
            deps = parse_query_inputs(out)
            cache[t] = deps

        for d in deps:
            if d.endswith(".o"):
                objs.add(d)
                # no need to add to frontier: .o is always a leaf (see above)
            elif ".so" in d:
                libs.add(Path(d).name)
                # Recurse only into in-build-tree libraries (relative target
                # paths like "larcorealg/lib/lib....so"); external libraries
                # (absolute cvmfs/.spack-env paths) have no local source to
                # attribute and are recorded as linked libs only.
                if not d.startswith("/") and d not in visited_targets:
                    frontier.append(d)
    return objs, libs


def load_all_object_deps(build_dir: Path, local_dir: Path):
    """
    One bulk `ninja -t deps` call (no target arg) dumps the recorded
    source+header closure for every object in the build, in one process
    spawn. Returns {obj_target: (source_path_or_None, [header_paths])}.

    This is the key performance choice in this script: querying per-object
    (~300 objects) would mean ~300 subprocess spawns; this is one.
    """
    out = run_in_env(build_dir, local_dir, ["ninja", "-t", "deps"])
    result = {}
    cur_obj = None
    cur_src = None
    cur_hdrs = []

    def flush():
        if cur_obj is not None:
            result[cur_obj] = (cur_src, cur_hdrs)

    for line in out.splitlines():
        if line and not line[0].isspace():
            # New "target: #deps N, deps mtime ..." header line.
            flush()
            cur_obj = line.split(":", 1)[0].strip()
            cur_src = None
            cur_hdrs = []
            continue
        s = line.strip()
        if not s:
            continue
        if s.endswith((".cxx", ".cc", ".cpp", ".C")) and cur_src is None:
            cur_src = s
        elif s.endswith((".h", ".hh", ".hpp", ".H")):
            cur_hdrs.append(s)
    flush()
    return result


def load_mf_files(build_dir: Path) -> set:
    """Live mf-reference files per grep-gate.sh (G1), the single source of
    truth for 'does this file still need migrating'."""
    proc = subprocess.run(
        [str(GREP_GATE), "--baseline-count"] + [str(SRCS_DIR / p) for p in PACKAGES],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    files = set()
    for line in proc.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            files.add(parts[1])
    return files


def package_of_build_target(exe_path: Path, build_dir: Path) -> str:
    """Package name from a BUILD-TREE executable path
    (build_dir/<pkg>/bin/<exe> or build_dir/<pkg>/test/.../<exe>)."""
    try:
        rel = exe_path.relative_to(build_dir)
        return rel.parts[0]
    except ValueError:
        return "?"


def main():
    args = sys.argv[1:]
    check_mode = "--check" in args
    build_dir = DEFAULT_BUILD_DIR
    local_dir = DEFAULT_LOCAL_DIR
    for i, a in enumerate(args):
        if a == "--build-dir" and i + 1 < len(args):
            build_dir = Path(args[i + 1]).resolve()
        if a == "--local-dir" and i + 1 < len(args):
            local_dir = Path(args[i + 1]).resolve()

    if not build_dir.is_dir():
        raise SystemExit(f"gen-targets: build dir not found: {build_dir}")
    if not local_dir.is_dir():
        raise SystemExit(f"gen-targets: local dir not found: {local_dir}")

    print(f"gen-targets: build_dir={build_dir}", file=sys.stderr)
    print(f"gen-targets: local_dir={local_dir}", file=sys.stderr)

    print("gen-targets: querying ctest for registered tests...", file=sys.stderr)
    ctest_data = get_ctest_json(build_dir, local_dir)
    tests = ctest_data.get("tests", [])
    print(f"gen-targets: {len(tests)} tests registered", file=sys.stderr)

    print("gen-targets: loading live mf-reference file list from grep-gate...", file=sys.stderr)
    mf_files = load_mf_files(build_dir)
    print(f"gen-targets: {len(mf_files)} files currently carry live mf references", file=sys.stderr)

    print("gen-targets: loading full object dependency graph (ninja -t deps, one call)...", file=sys.stderr)
    obj_deps = load_all_object_deps(build_dir, local_dir)
    print(f"gen-targets: {len(obj_deps)} objects known to ninja", file=sys.stderr)

    query_cache = {}

    rows = []
    for t in tests:
        name = t.get("name", "?")
        command = t.get("command", [])
        exe = find_executable_in_command(command, build_dir)
        if exe is None:
            rows.append((name, "?", "", "", "0", "NOTE:no-executable-found-in-command"))
            continue

        exe_target = str(exe.relative_to(build_dir))
        objs, libs = collect_closure(build_dir, local_dir, exe_target, query_cache)

        sources = set()
        headers = set()
        for obj in objs:
            src, hdrs = obj_deps.get(obj, (None, []))
            if src:
                sources.add(src)
            headers.update(hdrs)

        attributed = sources | headers
        has_mf = any(s in mf_files for s in attributed)

        pkg = package_of_build_target(exe, build_dir)

        def rel_to_srcs(p: str) -> str:
            try:
                return str(Path(p).relative_to(SRCS_DIR))
            except ValueError:
                return p

        source_list = ";".join(sorted(rel_to_srcs(s) for s in sources))
        lib_list = ";".join(sorted(libs))
        rows.append((name, pkg, source_list, lib_list, "1" if has_mf else "0", ""))

    rows.sort(key=lambda r: (r[1], r[0]))

    out_lines = ["test_name\tpackage\tsource_files\tlinked_libs\thas_mf_sites\tnote"]
    for r in rows:
        out_lines.append("\t".join(r))
    content = "\n".join(out_lines) + "\n"

    if check_mode:
        if not TARGETS_TSV.exists():
            print("gen-targets --check: FAIL -- targets.tsv does not exist yet", file=sys.stderr)
            sys.exit(1)
        existing = TARGETS_TSV.read_text()
        if existing == content:
            print("gen-targets --check: PASS -- targets.tsv is up to date", file=sys.stderr)
            sys.exit(0)
        else:
            print("gen-targets --check: FAIL -- targets.tsv is stale; re-run without --check", file=sys.stderr)
            sys.exit(1)

    TARGETS_TSV.write_text(content)
    n_mf = sum(1 for r in rows if r[4] == "1")
    print(f"gen-targets: wrote {TARGETS_TSV} ({len(rows)} tests, {n_mf} marked has_mf_sites=1)", file=sys.stderr)


if __name__ == "__main__":
    main()
