# Session state — messagefacility → spdlog migration

**Last updated:** 2026-09-02
**Status:** Planning complete for three packages. **No production code has been modified yet.**

Read this file first when resuming.

---

## 1. Where things stand

| Deliverable | Path | Status |
|---|---|---|
| Original plan (not mine) | `../MIGRATION_PLAN.md` | superseded; kept for reference |
| Rev 2 plan — `larcorealg` only | `../SPDLOG_MIGRATION_PLAN.md` | superseded by rev 3 **for the `Logging.h` design**; its `larcorealg` analysis is still valid |
| **Rev 3 plan — 3 packages** | `../SPDLOG_MIGRATION_PLAN_MULTIPACKAGE.md` | **current** |
| Compile-verified prototypes | `prototypes/` | reproduce with `prototypes/build-and-run.sh` |

**Production code changed so far: none.** Only planning documents and these
prototypes exist. `git status` in all three repos shows no modified tracked files.

---

## 2. The decision that matters most

The migration keeps an **`operator<<` streaming interface**; it does **not** convert
to `fmt` format strings. Three independent constraints force this:

1. `larcorealg` has 8 production headers with
   `template <typename Stream> void Print*Info(Stream&& out, ...)`, instantiated both
   with `std::ostream&` and with log objects, and re-`std::forward`ed internally.
2. `lardataalg/Dumpers/DumperBase.h:167` stores the stream **by value** in a class
   member (`Indenter<Stream>::out`).
3. `lar::dump::` manipulators and `util::quantities` rely on reaching a real
   `std::ostream&`.

The design is `lar::log::LogStream`: accumulates into an `std::ostringstream`, emits
on destruction, prefix derived at compile time from `__PRETTY_FUNCTION__`.

**Two rules that are load-bearing and must not be "optimized" away:**

- The `std::ostringstream` member must stay. Replacing it with an
  `fmt::memory_buffer` breaks ~51 `util::quantities` sites in `lardataalg` at once,
  plus all `lar::dump::` uses.
- The composed message body must be passed as an **argument**, never as a format
  string: `spdlog::log(lvl, "{}: {}", where, body)`. Passing `body` as the format
  string makes any message containing `{` fail at **runtime**
  (`lar::dump::vector3D` emits `{ 0; 0; 0 }`). Reproduced in prototype 02.

---

## 3. Prototypes — what each one proves

Run `cd prototypes && ./build-and-run.sh` (optionally with a name fragment, e.g.
`./build-and-run.sh 09`). Set `SPDLOG_DIR` if the cvmfs path has moved. Exit code 0
means every prototype behaved as expected, **including** that 08 still fails to compile.

| File | Proves |
|---|---|
| `01-spdlog-brace-and-multiline-behavior` | spdlog 1.12 emits multi-line bodies as one record; `should_log` works |
| `02-runtime-format-string-hazard` | **a body containing `{` used as a format string fails at runtime** |
| `03-logstream-vs-hard-patterns` | streaming design handles named objects, `Stream&&` forwarding, throw, `std::endl` |
| `04-function-name-macros` | `__PRETTY_FUNCTION__` is the only one carrying class scope |
| `05-constexpr-qualified-name-extraction` | the `constexpr` extractor yields `ns::Class::method` for ctors, templates, nested types |
| `06-integrated-prototype-auto-prefix` | full design end to end, `-Wall -Wextra -pedantic` clean |
| `07-no-spurious-empty-records` | a `LogStream` constructed but never streamed emits nothing |
| `08-FAILS-rev2-logstream-vs-indenter` | **rev-2 `LogStream` does NOT compile against `lardataalg`'s `Indenter`** |
| `09-move-ctor-fix-verified` | the move-ctor fix works; message emitted **exactly once**; `std::setw` works |
| `10-quantities-adl-streaming` | ostream-only ADL `operator<<` (the `quantities` shape) resolves correctly |
| `11-string_view-lifetime-across-move` | the `__PRETTY_FUNCTION__` `string_view` stays valid after the log is moved into an `Indenter` (valgrind-clean) |

Prototype **08 is expected to fail to compile.** That failure is the central finding
of rev 3; the harness treats a successful compile there as an error.

---

## 4. Measured scope (verified against the trees, not estimated)

| | `larcorealg` | `lardataobj` | `lardataalg` |
|---|---:|---:|---:|
| mf call sites | ~392 | 10 (+1 commented) | 68 |
| mf in headers | 3 | **0** | 3 |
| Named accumulating log objects | 13 | 0 | 2 |
| Log stored by value in a member | 0 | 0 | **1 (template)** |
| mf initialization calls | 13 | 0 | 0 |
| `.fcl` `message:` blocks | 2 | 0 | 0 |
| ROOT dictionaries | 1 | 7 | 0 |

Bulk of `larcorealg`: `test/Geometry/GeometryTestAlg.cxx` (203) and
`GeometryIteratorLoopTestAlg.cxx` (150) — 93 % of its sites are in the test tree.
Bulk of `lardataalg`: `test/DetectorInfo/DetectorTimingsStandard_test.cc` (51).

**Build order is forced:** `larcorealg` → `lardataobj` → `lardataalg`.
(`lardataalg` depends on both; `lardataobj` depends on neither.)

---

## 5. Environment facts already established

- spdlog **1.12.0**, shared/compiled build, bundled **fmt 9.1.0**, at
  `/cvmfs/larsoft.opensciencegrid.org/spack-packages/opt/spack/linux-almalinux9-x86_64_v2/gcc-12.2.0/spdlog-1.12.0-dwa4wahktue5dmuyodu2bp2rjn6bomnw`
- `spdlog::spdlog` carries `SPDLOG_SHARED_LIB;FMT_SHARED;SPDLOG_COMPILED_LIB`.
- **No `spdlog/mdc.h`** in this build → mf's context singlet/iteration cannot be
  emulated; those uses are simply dropped.
- `spdlog` is **not yet** in `mpddev/local/spack.yaml`; `messagefacility` still is.
- Local `g++` is 11.5.0; the spack toolchain is gcc 12.2.0. Prototypes compile under both.

---

## 6. Blocking question (must be answered before Phase A)

**Where should `Logging.h` live?**

`lardataobj` does **not** depend on `larcorealg`, so the rev-2 location
(`larcorealg/CoreUtils/Logging.h`) does not work for all three packages.

- **(a)** Add `lardataobj` → `larcorealg` dependency — layering regression for a pure
  data-product library, visible downstream.
- **(b)** `lardataobj` uses spdlog directly — duplicates the prefix macro.
- **(c, recommended)** Put it in **`larcoreobj`**, which both already depend on.
  **Needs confirmation that `larcoreobj` is in scope for edits.**

Second, non-blocking question: should the two hot-path guards in `lardataobj` (§8 of
rev 3) be one-shot, counted, or demoted to `debug`?

Also still open from rev 2 §11: output pattern (timestamped vs bare `%v` — bare makes
the before/after output diff much easier), whether to keep the two `.fcl` file
destinations, and the deprecation window for `SetupMessageFacility` forwarders.

---

## 7. Traps to re-read before writing any code

1. **Missing move constructor** — the defect in both the original plan and rev 2.
   Any log type returned by value or stored by value needs one, and it must
   **disarm the source** so the message emits exactly once.
2. **Never pass the body as a format string** (§2 above, prototype 02).
3. **Do not narrow `lar::dump::`** `operator<<` in
   `larcorealg/CoreUtils/DumpUtils.h:361,397` from `template <typename Stream>` to
   `std::ostream&`. `lardataalg/MCDumpers/MCDumpers.h:262` needs it generic.
4. **Do not set `SPDLOG_ACTIVE_LEVEL`.** `larcorealg/TestUtils/unit_test_base.h:1112`
   deliberately asserts trace/debug are *not* compiled away.
5. **Two hot-path log sites in `lardataobj` need guards:**
   `RecoBase/Event.cxx:29` (called 2× per `operator<` → O(n log n) on a sort) and
   `RawData/raw.cxx:1064` (inside the Huffman decompression loop). mf rate-limited
   these by category; spdlog will not.
6. **Silent level regression:** the 3 `MF_LOG_TRACE` calls in `lardataalg`'s
   `*TestHelpers.h` are visible today because `unit_test_base.h:294-309` sets
   `threshold: DEBUG`. spdlog defaults to `info` → they vanish with no compile error
   and no test failure. The init shim must set the level explicitly.
7. **No regex/`sed` bulk rewrite in `larcorealg`.** ~226 statements wrap across source
   lines and contain literals with braces and parentheses.
8. **Stale `// will throw` comments** at `lardataobj/Simulation/SimChannel.cxx:63` and
   `OpDetBacktrackerRecord.cxx:43,147` are wrong — mf's `LogError` does not throw.
   Delete them; do not "restore" throwing behaviour.
9. **`lardataalg/Dumpers/RawData/OpDetWaveform.h:122`** — `operator()` forwards its
   `Stream&&` as an lvalue (missing `std::forward`), so `dump()` and `operator()`
   have *different* ownership semantics. Both work, but test both.

---

## 8. Next action when resuming

1. Answer the `Logging.h` location question (§6).
2. Then start **Phase A** of `../SPDLOG_MIGRATION_PLAN_MULTIPACKAGE.md`:
   add spdlog to `spack.yaml`, create `Logging.h` with the rev-3 fixes (move ctor +
   `std::ios_base` manipulator overload), and write its unit test — the test should
   cover the same cases as prototypes 07, 09, 10 and 11.

Nothing in Phases B-E should begin until the Phase A foundation test is green.
