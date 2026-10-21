# BUILDING_WITH_SPACK_AND_MPD.md

# Instructions for building with spack and mpd

The C++ code we are using is packaged with Spack and is being developed
with `spack mpd`.

After initializing the build environment with larcorealg/spdlog-migration/guardrails/env.sh, 
use the following commmand to build the code in mpddev/srcs:
````
spack mpd build
```
To run the unit tests, from the package root directory:
```
spack mpd test -- [ctest arguments]
```
where "ctest arguments" are passed directly to the `ctest` command line (run internally by
`spack mpd test`).

Alternatively, `cmake` and `ctest` commands can be run directly within the
mpddev/build directory after first activating the spack environment:
```
spack env activate <path to local>
```
where "path to local" is the absolute path, or the relative path from the current directory
to the `mpddev/local` directory. So, if in the `build` directory, then:
```
spack env activate ../local
```
then `ctest ...`, etc.

The version of gcc currently needed is v12.5.0. If after activating the spack environment, this 
is not the version you get in response to `gcc --version` , then there is a problem with the
engironment and you should stop immediately.
