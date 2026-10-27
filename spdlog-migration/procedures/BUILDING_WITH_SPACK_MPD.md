# BUILDING_WITH_SPACK_AND_MPD.md

# Instructions for building with spack and mpd

The C++ code we are using is packaged with Spack and is being developed
with `spack mpd`.

## Where this tooling lives

The migration tooling (guard rails, procedures, prototypes) lives in the
**`larsoft-phlex-adapt`** repository, under `spdlog-migration/`. It is *outside*
any mpd project, and is shared across projects.

The mpd project you operate on is **discovered from your current directory**: a
project root is a directory containing `srcs/`, `local/spack.yaml` and `build/`.
Run the guard rails from inside the project's `srcs` tree. Check what was
discovered at any time with:

```
<...>/spdlog-migration/guardrails/mpd-paths.sh --check
```

Override with `MPD_PROJECT=<name|absolute path>`. More than one project may exist
side by side (e.g. `mpddev`, `larsoftobj`) at different migration stages, so
confirm the project before trusting any result.

## Building

After initializing the build environment by **sourcing**
`spdlog-migration/guardrails/env.sh` (it activates the spack environment for the
discovered project), use the following command to build the code in that
project's `srcs`:
```
spack mpd build
```
To run the unit tests, from the package root directory:
```
spack mpd test -- [ctest arguments]
```
where "ctest arguments" are passed directly to the `ctest` command line (run internally by
`spack mpd test`).

Alternatively, `cmake` and `ctest` commands can be run directly within the
project's `build` directory after first activating the spack environment:
```
spack env activate <path to local>
```
where "path to local" is the absolute path, or the relative path from the current directory
to that project's `local` directory. So, if in the `build` directory, then:
```
spack env activate ../local
```
then `ctest ...`, etc.

The version of gcc currently needed is v12.5.0. If after activating the spack environment, this 
is not the version you get in response to `gcc --version` , then there is a problem with the
engironment and you should stop immediately.
