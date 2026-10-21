# Migration Plan: messagefacility to spdlog (revision 2)

**Package:** `larcorealg` (v10.00.04)
**Target:** replace `messagefacility` with `spdlog`
**Adopted convention:** every log call goes through the **spdlog default logger**; each
message begins with the **fully scoped class and method/function name** of its origin.

This document supersedes `MIGRATION_PLAN.md`. Section 13 explains why.

---

## 1. Findings from the actual source tree

All numbers below were measured directly in
`/exp/dune/app/users/esnider/code-spack/larsoft3/mpdtest/mpddev/srcs/larcorealg`.

### 1.1 Scope

| Area | Files | Log call sites |
|---|---:|---:|
| `larcorealg/Geometry/*.cxx` (production library) | 11 | 26 |
| `larcorealg/Geometry/StandaloneBasicSetup.h` | 1 | 0 (4 init calls) |
| `larcorealg/TestUtils/*.h` (public template headers) | 2 | 10 |
| `test/Geometry/*` | 5 | 356 |
| `CMakeLists.txt` | 4 | 9 references |
| `.fcl` files | 2 | `services.message` blocks |
| **Total** | **25** | **~392 call sites** |

The decisive structural fact: **93 % of the log call sites are in `test/Geometry/`,
and 100 % of the difficult patterns are in the test tree plus `unit_test_base.h`.**
The production library itself is nearly trivial to migrate — 26 single-statement
temporaries in 11 files.

### 1.2 API forms actually in use

| Form | Count | Notes |
|---|---:|---|
| `MF_LOG_ERROR(cat)` | 137 | test tree only |
| `MF_LOG_INFO(cat)` | 54 | `GeometryTestAlg.cxx` only |
| `mf::LogVerbatim(cat)` | 51 | |
| `MF_LOG_DEBUG(cat)` | 39 | 5 in production library |
| `mf::LogProblem(cat)` | 35 | 3 with an **empty** category string |
| `MF_LOG_TRACE(cat)` | 30 | |
| `mf::LogInfo(cat)` | 18 | |
| `mf::LogError(cat)` | 18 | |
| `mf::LogWarning(cat)` | 17 | |
| `MF_LOG_WARNING`, `MF_LOG_VERBATIM`, `mf::LogDebug`, `mf::LogTrace`, `mf::LogPrint` | 9 | |
| `mf::StartMessageFacility` / `SetApplicationName` / `SetContextSinglet` / `SetContextIteration` | 13 | init only |
| `mf::isDebugEnabled()` | 2 | `GeometryTestAlg.cxx:1905, 2505` |

`mf::LogAbsolute`, `mf::LogSystem`, `mf::LogImportant`, `mf::EndMessageFacility`,
`mf::FlushMessageLog` are **not** used. There is no `art::Exception` anywhere; the
package depends on the art suite only through mf, fhiclcpp and cetlib.

### 1.3 Hard patterns that constrain the design

These are the reason a naive `spdlog::info("...", args)` rewrite cannot work.

**(a) Named accumulating log objects — 13 sites.**
A log object is held in a local variable and streamed to across several statements,
often inside conditionals and loops, and flushed by its destructor.

```cpp
// test/Geometry/GeometryTestAlg.cxx:344  (GeometryTestAlg::Run)
mf::LogInfo log("GeometryTest");
log << "Tests completed:";
if (tests_run.empty()) { log << "\n  no test run"; }
else {
  log << "\n  " << tests_run.size() << " tests run:\t ";
  for (std::string const& t : tests_run) log << " " << t;
}
...
return nErrors;                    // <- message emitted here, at destruction
```

Full list: `unit_test_base.h:1128`; `GeometryTestAlg.cxx:344, 367, 503, 580, 624,
651, 682, 740, 1321, 2506, 2670, 2866`.

**(b) Log objects flowing through `Stream&&` templates — the hardest case.**
`larcorealg` exposes a generic printing protocol,
`template <typename Stream> void Print...(Stream&& out, ...)`, implemented in eight
production headers (`GeometryCore.h:632`, `CryostatGeo.h:389`, `TPCGeo.h:270`,
`PlaneGeo.h:1257`, `WireGeo.h:483`, `OpDetGeo.h:259`, `AuxDetGeo.h:188`,
`AuxDetSensitiveGeo.h:165`). These templates are instantiated **both** with
`std::ostream&` (from `WireReadoutDumper.cxx`) **and** with mf log objects:

```cpp
// test/Geometry/GeometryTestAlg.cxx:453, 458, 761 — temporary, already streamed to
tpc.PrintTPCInfo(mf::LogVerbatim("GeometryTest") << indent, indent, TPCGeo::MaxVerbosity);

// test/Geometry/GeometryTestAlg.cxx:509 — lvalue, then std::forward'ed twice more
printAuxDetGeo(log, auxDetGeom->AuxDet(iDet), "  ", "");
```

`GeometryTestAlg::printAuxDetGeo` / `printAuxDetSensitiveGeo`
(`GeometryTestAlg.h:170-197`, `.cxx:514-569`) re-`std::forward` the same stream
inside a `switch` and a loop. **Any replacement type must be usable as a
`Stream&&` template argument and survive repeated forwarding within one
expression.** This kills the "convert to `fmt` format strings" approach outright.

**(c) `lar::dump::*` manipulators — 10 sites.**
`larcorealg/CoreUtils/DumpUtils.h:361, 397` defines
`template <typename Stream, typename Array> Stream& operator<<(Stream&&, ArrayDumper<Array>&&)`.
These are streamed into mf logs at `GeometryTestAlg.cxx:472-476, 488-490, 525, 530,
563, 568, 3014, 3021, 3042, 3049`. The replacement must be deducible as `Stream`.
Note their output contains **literal `{` and `}` characters** (`{ 0; 0; 0 }`) — see §2.3.

**(d) A log object alive across a `throw`.**
`GeometryTestAlg.cxx:1321-1325` accumulates into `mf::LogError log` and then throws;
the message is emitted during stack unwinding.

**(e) `std::endl` streamed into a log — 1 site.**
`WireReadoutStandardGeom.cxx:316`. Requires manipulator support.

**(f) Multi-line output is the house style.**
~50 statements embed `\n`, and ~226 statements are physically wrapped across source
lines. A full `WireReadoutDumper` dump is one enormous multi-line record.

**(g) Custom `operator<<` types.**
`geo::CryostatID`/`TPCID`/`PlaneID`/`WireID`, `geo::Point_t`/`Vector_t` (ROOT
`GenVector`), `geo::View_t`/`SigType_t`, `cet::exception`, ROOT `const char*`
accessors. All are ostream-insertable; none has an `fmt::formatter`.

### 1.4 Environment

spdlog is already available in the `cvmfs` spack packages tree:

```
/cvmfs/larsoft.opensciencegrid.org/spack-packages/opt/spack/
  linux-almalinux9-x86_64_v2/gcc-12.2.0/spdlog-1.12.0-dwa4wahktue5dmuyodu2bp2rjn6bomnw
```

Relevant properties, verified by inspection:

- **spdlog 1.12.0**, built as a **shared compiled library** (`libspdlog.so.1.12.0`).
- Imported target `spdlog::spdlog` carries
  `INTERFACE_COMPILE_DEFINITIONS "SPDLOG_SHARED_LIB;FMT_SHARED;SPDLOG_COMPILED_LIB"`.
- Uses **bundled fmt 9.1.0** (`SPDLOG_FMT_EXTERNAL=OFF`), so there is no external
  `fmt` dependency to reconcile, but also **no `fmt::ostream_formatter` opt-in is
  applied to our types**.
- `spdlog/mdc.h` is **absent** (added in 1.11 as an optional feature not built here),
  so mf's "context singlet / context iteration" cannot be emulated via MDC.
- CMake config at `lib64/cmake/spdlog/spdlogConfig.cmake`.

The build environment (`mpddev/local/spack.yaml`) currently lists `messagefacility`
as a spec; `spdlog` must be added.

---

## 2. Design decisions

### 2.1 Default logger only (per your instruction)

All logging goes to `spdlog::default_logger()`. Consequences, stated plainly:

- No per-category registry, no `spdlog::get(...)`, no per-category level filtering.
  The mf categories (`"Geometry"`, `"GeometryTest"`, `"ChannelsIntersect"`, ...) are
  **dropped as routing keys**.
- The `.fcl` `categories: { GeometryTest: { limit: -1 } ... }` per-category limits and
  the `timespan`-based rate limiting have **no equivalent** and are dropped. This is a
  real behavioural regression and must be documented (§8, §11).
- In exchange, the API is much smaller and no initialization is required before the
  first log call — `spdlog` lazily creates a stdout default logger. That property is
  valuable here because `BasicTesterEnvironment::~BasicTesterEnvironment`
  (`unit_test_base.h:1027`) logs during teardown.

The scoped-name prefix you specified is what replaces the category as a *filtering
aid for humans* (`grep 'geo::WireReadoutGeom::'`), and it is strictly more precise
than the old category strings, which were inconsistent (`"Geometry"` was used by four
different classes; three call sites used an empty category).

### 2.2 Streaming interface, not format strings

The `Stream&&` protocol (§1.3b), the `lar::dump` manipulators (§1.3c) and the 13
accumulating log objects (§1.3a) together make an ostream-style interface mandatory.
Converting to `fmt` format strings would require writing `fmt::formatter`
specializations for every geometry ID type, every ROOT vector type and
`cet::exception`, **and** would still not fix the `Stream&&` call sites.

So: keep `operator<<`, change only what is behind it.

### 2.3 The message body must never be parsed as a format string

This is a correctness trap, not a style point. Verified experimentally against the
installed spdlog 1.12:

```cpp
std::string s = "{ 1; 2; 3 }";          // typical lar::dump output
spdlog::info(s + " and {}", 42);
// -> [*** LOG ERROR #0001 ***] invalid format string
```

Because `lar::dump::vector3D` emits `{ ... }` and geometry IDs may print braces,
the composed message **must** be passed as an argument, never as a format string:

```cpp
spdlog::log(level, "{}: {}", where, body);   // correct
spdlog::log(level, body);                    // WRONG - body is parsed as a format
```

The `LogStream` sink in §3 does this correctly. Any hand-written call added later
must follow the same rule; §7 adds a lint check for it.

### 2.4 Automatic scoped-name prefix

The prefix is derived at compile time from `__PRETTY_FUNCTION__`, so it cannot drift
from the code and costs nothing at runtime. Verified on gcc:

| Construct | Extracted prefix |
|---|---|
| `void geo::WireReadoutGeom::ChannelsIntersect(int) const` | `geo::WireReadoutGeom::ChannelsIntersect` |
| `void geo::freeFunc()` | `geo::freeFunc` |
| `void geo::A::tmpl(T) const [with T = double]` | `geo::A::tmpl` |
| constructor | `geo::WireReadoutGeom::WireReadoutGeom` |

`__PRETTY_FUNCTION__` is a GCC/Clang extension. `larcorealg` is already built with
`-pedantic` under GCC only (top-level `CMakeLists.txt:20-23`), and the fallback to
`__func__` is one `#if`, so this is acceptable. The extraction is `constexpr` over
`std::string_view`, so no runtime string work happens on suppressed messages.

### 2.5 Level mapping

| messagefacility | spdlog level | Rationale |
|---|---|---|
| `mf::LogError`, `MF_LOG_ERROR`, `mf::LogProblem` | `err` | |
| `mf::LogWarning`, `MF_LOG_WARNING`, `mf::LogPrint` | `warn` | |
| `mf::LogInfo`, `MF_LOG_INFO`, `mf::LogVerbatim`, `MF_LOG_VERBATIM` | `info` | |
| `mf::LogDebug`, `MF_LOG_DEBUG` | `debug` | |
| `mf::LogTrace`, `MF_LOG_TRACE` | `trace` | |
| `mf::isDebugEnabled()` | `spdlog::should_log(spdlog::level::debug)` | |

The mf `Verbatim`/`Problem`/`Print` variants differ from their counterparts only in
that mf suppresses the record prefix. Under spdlog the prefix is controlled by the
pattern, globally, so the distinction disappears. That is acceptable: all 51
`LogVerbatim` and 35 `LogProblem` uses are in the test tree, where the output is read
by humans, not parsed.

**Do not set `SPDLOG_ACTIVE_LEVEL`** to compile out debug/trace. `unit_test_base.h:1112`
deliberately asserts that trace/debug statements are *not* compiled away, and the
`geometry_iterator_loop_test` fcl routes `DEBUG` to a file. Use runtime levels only.

---

## 3. New component: `larcorealg/CoreUtils/Logging.h`

A single header, no `.cxx`. This is the entire migration surface.

```cpp
#ifndef LARCOREALG_COREUTILS_LOGGING_H
#define LARCOREALG_COREUTILS_LOGGING_H

#include "spdlog/spdlog.h"

#include <ostream>
#include <sstream>
#include <string>
#include <string_view>

namespace lar::log {

  namespace detail {

    /// Extracts "ns::Class::method" from a __PRETTY_FUNCTION__ expansion.
    constexpr std::string_view qualifiedName(std::string_view pretty)
    {
      // drop the " [with T = ...]" suffix GCC appends for templates
      if (auto const b = pretty.find(" [with "); b != std::string_view::npos)
        pretty.remove_suffix(pretty.size() - b);

      // find the '(' opening the parameter list (skipping any nested parentheses)
      std::size_t depth = 0;
      std::size_t paren = std::string_view::npos;
      for (std::size_t i = pretty.size(); i-- > 0;) {
        char const c = pretty[i];
        if (c == ')') ++depth;
        else if (c == '(' && --depth == 0) { paren = i; break; }
      }
      if (paren == std::string_view::npos) return pretty;

      // walk back to the space separating the return type, ignoring <> contents
      std::string_view const head = pretty.substr(0, paren);
      int angle = 0;
      for (std::size_t i = head.size(); i-- > 0;) {
        char const c = head[i];
        if (c == '>') ++angle;
        else if (c == '<') --angle;
        else if (c == ' ' && angle == 0) return head.substr(i + 1);
      }
      return head;
    }

  } // namespace detail

  /**
   * @brief Accumulates a message via `operator<<` and emits it on destruction.
   *
   * Satisfies the `Stream&&` protocol used by `geo::*::Print*Info()` and by
   * `lar::dump::` manipulators, so it can be passed where a `std::ostream` was
   * previously expected.
   */
  class LogStream {

    std::ostringstream buf_;
    std::string_view where_;
    spdlog::level::level_enum level_;
    bool active_;

  public:

    LogStream(spdlog::level::level_enum level, std::string_view where)
      : where_{where}, level_{level}, active_{spdlog::should_log(level)}
    {}

    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;

    ~LogStream()
    {
      if (!active_) return;
      auto const body = buf_.str();
      if (body.empty()) return;   // nothing was streamed: emit nothing
      // NOTE: body is an *argument*, never a format string (see plan 2.3).
      if (where_.empty()) spdlog::log(level_, "{}", body);
      else                spdlog::log(level_, "{}: {}", where_, body);
    }

    /// Whether the message will actually be emitted.
    explicit operator bool() const noexcept { return active_; }

    template <typename T>
    LogStream& operator<<(T const& value)
    {
      if (active_) buf_ << value;
      return *this;
    }

    /// Supports `std::endl` and other `std::ostream` manipulators.
    LogStream& operator<<(std::ostream& (*manip)(std::ostream&))
    {
      if (active_) buf_ << manip;
      return *this;
    }

  }; // class LogStream

  /// Equivalent of `mf::isDebugEnabled()`.
  inline bool debugEnabled() { return spdlog::should_log(spdlog::level::debug); }

  /// Sets up the default logger. Optional: spdlog works without it.
  void setup(std::string const& appName = "larcorealg",
             spdlog::level::level_enum level = spdlog::level::info);

} // namespace lar::log

#if defined(__GNUC__) || defined(__clang__)
#  define LAR_LOG_WHERE_ (::lar::log::detail::qualifiedName(__PRETTY_FUNCTION__))
#else
#  define LAR_LOG_WHERE_ (::std::string_view{__func__})
#endif

#define LAR_LOG(level) ::lar::log::LogStream((level), LAR_LOG_WHERE_)

#define LAR_LOG_ERROR   LAR_LOG(::spdlog::level::err)
#define LAR_LOG_WARNING LAR_LOG(::spdlog::level::warn)
#define LAR_LOG_INFO    LAR_LOG(::spdlog::level::info)
#define LAR_LOG_DEBUG   LAR_LOG(::spdlog::level::debug)
#define LAR_LOG_TRACE   LAR_LOG(::spdlog::level::trace)

#endif // LARCOREALG_COREUTILS_LOGGING_H
```

### 3.1 Status: prototyped and verified

This design was compiled with `g++ -std=c++17 -Wall -Wextra -pedantic` against the
installed spdlog 1.12 and exercised against every hard pattern from §1.3. Confirmed
working:

- named accumulating object with conditionals and loops (§1.3a);
- lvalue `LogStream` bound to `Stream&&` and `std::forward`ed through two further
  template levels, in a loop and a `switch` (§1.3b);
- temporary streamed to, then passed as `Stream&&`
  (`PrintPlaneInfo(LAR_LOG_INFO << "  ", indent, 8)`) (§1.3b);
- `lar::dump::vector3D` manipulator streamed in (§1.3c);
- log alive across a `throw`, emitted during unwinding (§1.3d);
- `std::endl` (§1.3e);
- multi-line bodies emitted as one record (§1.3f);
- message bodies containing literal `{`/`}` and `{}` emitted verbatim (§2.3);
- suppressed levels: nothing formatted, nothing emitted;
- a `LogStream` constructed but never streamed to emits **no** record.

### 3.2 Known limitations, stated up front

- **Not a drop-in for `if (cond) LAR_LOG_INFO << ...; else ...`** — same dangling-else
  hazard mf had. Braces required, as before.
- **One `std::ostringstream` per emitted message.** This is what mf did too, so it is
  not a regression, but it forfeits spdlog's zero-allocation fast path. Given that the
  production library logs 26 times total, this is irrelevant there; in the test tree
  it is dwarfed by the geometry work. Do not "optimize" this away — doing so breaks
  §1.3b.
- **`operator bool` is `explicit`**, so `if (LAR_LOG_TRACE)` compiles. Do not use it:
  it constructs a temporary. Use `lar::log::debugEnabled()` instead.

---

## 4. Migration steps

### Phase 0 — Environment (0.5 day)

1. Add `spdlog` to `mpddev/local/spack.yaml` `specs:`.
2. Re-concretize and confirm `spdlog@1.12.0` resolves to the existing cvmfs install
   (it should be reused, not rebuilt).
3. Confirm `find_package(spdlog)` succeeds in a scratch CMake project.

**Exit criterion:** `spdlogConfig.cmake` found; `spdlog::spdlog` links.

### Phase 1 — Introduce `Logging.h` (1 day)

1. Add `larcorealg/CoreUtils/Logging.h` as in §3.
2. Add `Logging.cxx` containing only `lar::log::setup()`.
3. Extend `larcorealg/CoreUtils/CMakeLists.txt`: add `Logging.cxx` to the existing
   `cet_make_library(SOURCE ...)` and `spdlog::spdlog` to its `PUBLIC` libraries
   (public, because `Logging.h` is an installed header that includes `spdlog/spdlog.h`).
4. Add `find_package(spdlog REQUIRED EXPORT)` to the top-level `CMakeLists.txt`,
   next to the existing `find_package` calls.
5. Add a unit test `test/CoreUtils/Logging_test.cxx` covering the §3.1 checklist,
   especially: brace-containing bodies, `Stream&&` forwarding, suppressed levels,
   empty-body suppression.

**Exit criterion:** the new test passes; nothing else has changed yet; the build is
green with both mf and spdlog present.

### Phase 2 — Production library (1 day)

11 files, 26 call sites, all single-statement temporaries. Purely mechanical.

- `AuxDetGeo.cxx` (1), `AuxDetGeometryCore.cxx` (1), `AuxDetReadoutGeom.cxx` (2),
  `AuxDetSensitiveGeo.cxx` (1), `CryostatGeo.cxx` (1), `GeometryCore.cxx` (5),
  `Intersections.cxx` (1), `PlaneGeo.cxx` (1), `TPCGeo.cxx` (1),
  `WireReadoutGeom.cxx` (8), `WireReadoutStandardGeom.cxx` (4).

Per file: swap the include, drop the category argument, drop any manual
class/method prefix already present in the text (the macro now supplies it).

```cpp
// before — larcorealg/Geometry/WireReadoutGeom.cxx:551
mf::LogError("ChannelsIntersect")
  << "1st channel " << c1 << " maps to no wire (is it a real one?)";

// after
LAR_LOG_ERROR << "1st channel " << c1 << " maps to no wire (is it a real one?)";
// emits: geo::WireReadoutGeom::ChannelsIntersect: 1st channel 7 maps to no wire ...
```

Also in this phase:

- **`WireGeo.cxx:14`**: delete the `messagefacility` include. It has **zero** `mf::`
  uses — a dead include. No replacement needed.
- **`WireReadoutStandardGeom.cxx:316`**: drop the trailing `<< std::endl` (it produced
  a stray blank line under mf too). Supported either way.
- **`WireReadoutDumper.h:45-54`**: update the doc comment; the documented idiom
  becomes `LAR_LOG_INFO << dumper.toStream();`, which works because `LogStream`
  forwards to an `ostringstream`.
- Remove `messagefacility::MF_MessageLogger` from
  `larcorealg/Geometry/CMakeLists.txt:170`. It is `PRIVATE`, so this does not change
  the public link interface.

**Exit criterion:** `larcorealg::Geometry` builds and links with no mf reference; all
existing tests still pass (they still use mf themselves at this point — the two
libraries coexist fine).

### Phase 3 — Public test-support headers (1.5 days)

This is the phase that changes public API. Handle it deliberately.

**3a. `larcorealg/Geometry/StandaloneBasicSetup.h`**

Current (`:113-120`):

```cpp
mf::StartMessageFacility(pset.get<fhicl::ParameterSet>("services.message"));
mf::SetApplicationName(applName);
mf::SetContextSinglet("main");
mf::SetContextIteration("");
```

Replace with a `SetupLogging(fhicl::ParameterSet const&, std::string appName)` that:

- reads `services.message.destinations.*.threshold` if present and maps the highest-
  verbosity threshold to an spdlog level (`DEBUG`->debug, `INFO`->info, `WARNING`->warn,
  `ERROR`->err); otherwise defaults to `info`;
- calls `lar::log::setup(appName, level)`;
- **does not throw** if `services.message` is absent (behaviour change — the current
  code throws, which is hostile for a standalone helper).

Keep `SetupMessageFacility` as a deprecated inline forwarder for one release:

```cpp
[[deprecated("use lar::standalone::SetupLogging()")]]
inline void SetupMessageFacility(fhicl::ParameterSet const& pset,
                                 std::string applName = "standalone")
{ SetupLogging(pset, std::move(applName)); }
```

This matters because `StandaloneBasicSetup` is an exported CMake target
(`Geometry/CMakeLists.txt:73-79`) with out-of-package callers.

Also drop `messagefacility::MF_MessageLogger` from that target's INTERFACE libs and
add `larcorealg::CoreUtils`; `fhiclcpp` and `cetlib` remain genuinely required.

**3b. `larcorealg/TestUtils/unit_test_base.h`**

Three distinct changes:

1. `BasicEnvironmentConfiguration::DefaultInit()` (`:289-310`) embeds a raw-string
   **messagefacility destination DSL**. Replace with an spdlog-shaped default
   (a level plus an optional file destination). Keep the FHiCL key `"message"` so
   existing user configurations do not break outright, but ignore the mf-specific
   sub-keys and **emit one warning** naming the ignored keys.
2. `SetupMessageFacility()` (`:1089-1117`) becomes `SetupLogging()`. The
   `messageLevels` self-test block (`:1108-1113`) is rewritten in terms of the five
   `LAR_LOG_*` macros. Retain the deliberate assertion that debug/trace are **not**
   compiled away (§2.5).
3. The virtual `SetupMessageFacility` overloads (`:653-661`) are renamed, with
   deprecated forwarders, since subclasses outside this package may override them.

`mf::SetContextIteration`/`SetContextSinglet` have no replacement (§1.4: no MDC in
this build). Their three uses in `geometry_loader_test.cxx:79, 89, 101` are simply
deleted; the scoped-name prefix conveys strictly more.

**3c. `larcorealg/TestUtils/geometry_unit_test_base.h`** — 2 trivial call sites
(`:253, 287`). Remove `messagefacility::MF_MessageLogger` from both targets in
`larcorealg/TestUtils/CMakeLists.txt:17, 36`.

**Exit criterion:** all downstream-visible names either migrated or deprecated-with-
forwarder; `larcorealg::unit_test_base` and `larcorealg::geometry_unit_test_base`
link without mf.

### Phase 4 — Test tree (3–4 days)

356 call sites, but only ~15 are hard.

**Order of work:**

1. **The three test mains** (`geometry_test.cxx`, `geometry_loader_test.cxx`,
   `geometry_iterator_loop_test.cxx`) — 1 log call each, plus the
   `SetContextIteration` deletions. Do these first so the tests run.
2. **`GeometryIteratorLoopTestAlg.cxx`** (150 sites) — all single-statement
   temporaries, dominated by `MF_LOG_ERROR`. Fully mechanical.
3. **`GeometryTestAlg.cxx`** (203 sites) — mechanical except for the 12 named-object
   sites and the 4 `Stream&&` call sites listed in §1.3a/b. Migrate the mechanical
   bulk first, then hand-migrate the hard sites one at a time, each verified by
   diffing that test's output.
4. Remove `messagefacility::MF_MessageLogger` from `test/Geometry/CMakeLists.txt:41,
   92, 105`.

For the named-object sites, the transformation is a one-line substitution because
`LogStream` has the same lifetime semantics as an mf log object:

```cpp
// before                                    // after
mf::LogVerbatim log("GeometryTest");         auto log = LAR_LOG_INFO;
mf::LogError log("GeometryTest");            auto log = LAR_LOG_ERROR;
mf::LogInfo log("WirePitch");                auto log = LAR_LOG_INFO;
```

For `GeometryTestAlg.cxx:1905, 2505`: `mf::isDebugEnabled()` -> `lar::log::debugEnabled()`.

**Do not attempt a regex-driven bulk rewrite.** ~226 of these statements are wrapped
across source lines and the `<<` chains contain string literals with parentheses and
braces. Use a `clang-tidy` check or `clang-format`-aware script, or accept a careful
manual pass file by file. A naive `sed` will silently corrupt continuation lines.

**Exit criterion:** `rg 'messagefacility|mf::|MF_LOG' larcorealg test` returns nothing
outside documentation.

### Phase 5 — Build system and configuration cleanup (0.5 day)

1. Remove `find_package(messagefacility REQUIRED EXPORT)` from the top-level
   `CMakeLists.txt:29`. **Note:** because it is `EXPORT`, it is re-exported in
   `larcorealgConfig.cmake`; removing it is an interface change for every downstream
   package. Announce it.
2. Remove `messagefacility` from `mpddev/local/spack.yaml` only after confirming no
   sibling package in the dev area still needs it.
3. Rewrite the `services.message` blocks in `test/Geometry/test_geometry.fcl:15-45`
   and `test_geometry_iterator_loop.fcl:15-44`. Both configure a `file` destination,
   a `cout` destination and a `cerr` destination with per-category limits. Under a
   single default logger the honest translation is a level plus, at most, a
   two-sink (console + file) setup. **The per-category limits and `timespan` rate
   limiting are dropped** — record this in the file as a comment so the loss is not
   silently forgotten.

### Phase 6 — Validation (1.5 days)

1. `ctest` for the whole package; every test must pass.
2. **Output comparison.** For `geometry_test` and `geometry_iterator_loop_test`,
   capture stdout before and after and diff after normalizing timestamps and the
   record prefix. The *message bodies* should be identical modulo the added scoped-name
   prefix. Any other difference is a migration bug.
3. Specifically verify the two multi-line-heavy paths, since they exercise §1.3b:
   `GeometryTestAlg::printAuxiliaryDetectors` and `printWiresInTPC` (enabled via
   `RunTests: ["+PrintWires"]`, already set in `test_geometry.fcl:62`).
4. Confirm the debug-level file destination behaviour of
   `test_geometry_iterator_loop.fcl` is reproduced or consciously dropped.
5. Grep sweep: no `mf::`, no `MF_LOG_`, no `messagefacility` anywhere.

---

## 5. File-by-file checklist

### Production library — Priority 1
- [ ] `larcorealg/Geometry/WireReadoutGeom.cxx` (8)
- [ ] `larcorealg/Geometry/GeometryCore.cxx` (5)
- [ ] `larcorealg/Geometry/WireReadoutStandardGeom.cxx` (4) — incl. `std::endl` at :316
- [ ] `larcorealg/Geometry/AuxDetReadoutGeom.cxx` (2)
- [ ] `larcorealg/Geometry/AuxDetGeo.cxx` (1)
- [ ] `larcorealg/Geometry/AuxDetGeometryCore.cxx` (1)
- [ ] `larcorealg/Geometry/AuxDetSensitiveGeo.cxx` (1)
- [ ] `larcorealg/Geometry/CryostatGeo.cxx` (1)
- [ ] `larcorealg/Geometry/Intersections.cxx` (1)
- [ ] `larcorealg/Geometry/PlaneGeo.cxx` (1)
- [ ] `larcorealg/Geometry/TPCGeo.cxx` (1)
- [ ] `larcorealg/Geometry/WireGeo.cxx` — **delete dead include only**
- [ ] `larcorealg/Geometry/WireReadoutDumper.h` — doc comment only

### Public headers — Priority 2 (API change)
- [ ] `larcorealg/Geometry/StandaloneBasicSetup.h` — `SetupLogging()` + deprecated forwarder
- [ ] `larcorealg/TestUtils/unit_test_base.h` — default config, `SetupLogging()`, level self-test, 1 named-object site
- [ ] `larcorealg/TestUtils/geometry_unit_test_base.h` (2)

### Test tree — Priority 3
- [ ] `test/Geometry/geometry_test.cxx` (1)
- [ ] `test/Geometry/geometry_loader_test.cxx` (1 + 3 `SetContextIteration`)
- [ ] `test/Geometry/geometry_iterator_loop_test.cxx` (1)
- [ ] `test/Geometry/GeometryIteratorLoopTestAlg.cxx` (150, all mechanical)
- [ ] `test/Geometry/GeometryTestAlg.cxx` (203, incl. 12 named objects + 4 `Stream&&` sites + 2 `isDebugEnabled`)

### Build and configuration
- [ ] `CMakeLists.txt:29` — drop `find_package(messagefacility ... EXPORT)`, add `spdlog`
- [ ] `larcorealg/CoreUtils/CMakeLists.txt` — add `Logging.cxx`, `spdlog::spdlog` PUBLIC
- [ ] `larcorealg/Geometry/CMakeLists.txt:76, 170`
- [ ] `larcorealg/TestUtils/CMakeLists.txt:17, 36`
- [ ] `test/Geometry/CMakeLists.txt:41, 92, 105`
- [ ] `test/Geometry/test_geometry.fcl:15-45`
- [ ] `test/Geometry/test_geometry_iterator_loop.fcl:15-44`
- [ ] `mpddev/local/spack.yaml` — add `spdlog`, later drop `messagefacility`

---

## 6. Worked examples

**Simple temporary (the 370-site majority):**

```cpp
// larcorealg/Geometry/CryostatGeo.cxx:43
- MF_LOG_DEBUG("Geometry") << "cryostat  volume is " << fVolume->GetName();
+ LAR_LOG_DEBUG << "cryostat volume is " << fVolume->GetName();
// -> geo::CryostatGeo::CryostatGeo: cryostat volume is volCryostat
```

**Named accumulating object (13 sites):**

```cpp
// test/Geometry/GeometryTestAlg.cxx:503
- mf::LogVerbatim log("GeometryTest");
+ auto log = LAR_LOG_INFO;
  log << "There are " << nAuxDets << " auxiliary detectors:";
  for (unsigned int iDet = 0; iDet < nAuxDets; ++iDet) {
    log << "\n[#" << iDet << "] ";
    printAuxDetGeo(log, auxDetGeom->AuxDet(iDet), "  ", "");   // unchanged
  }
```

**`Stream&&` call site (4 sites) — no change beyond the constructor:**

```cpp
// test/Geometry/GeometryTestAlg.cxx:453
- tpc.PrintTPCInfo(mf::LogVerbatim("GeometryTest") << indent, indent, TPCGeo::MaxVerbosity);
+ tpc.PrintTPCInfo(LAR_LOG_INFO << indent, indent, TPCGeo::MaxVerbosity);
```

**Runtime level query (2 sites):**

```cpp
// test/Geometry/GeometryTestAlg.cxx:2505
- if (mf::isDebugEnabled()) {
-   mf::LogTrace log("GeometryTest");
+ if (lar::log::debugEnabled()) {
+   auto log = LAR_LOG_TRACE;
```

**Log alive across a throw (1 site) — works unchanged:**

```cpp
// test/Geometry/GeometryTestAlg.cxx:1321
- mf::LogError log("GeometryTest");
+ auto log = LAR_LOG_ERROR;
  log << wireIDs.size() << " wire IDs associated with channel #" << channel << ":";
  for (auto const& wid : wireIDs) log << "\n  " << wid;
  throw cet::exception("BadChannelLookup") << ... ;   // log flushes during unwinding
```

---

## 7. Guard rails

Add these before Phase 4, not after:

1. **A CI grep gate**: fail the build if `mf::` / `MF_LOG_` / `messagefacility` reappears.
2. **A format-string lint**: fail on `spdlog::(info|warn|error|debug|trace|critical|log)\(`
   whose first (or post-level) argument is not a string literal. This catches the
   §2.3 hazard, which fails at *runtime*, not compile time, and only for messages
   that happen to contain braces — exactly the kind of bug that ships.
3. **Output-diff harness** (Phase 6.2) checked in as a script, so the comparison can
   be repeated after each file.

---

## 8. Accepted behavioural losses

State these explicitly in the release notes; do not let them be discovered later.

| Lost capability | Where it was used | Mitigation |
|---|---|---|
| Per-category message routing and limits | both `.fcl` files, `unit_test_base.h` default config | scoped-name prefix is greppable; global level only |
| `timespan`-based rate limiting | `GeometryBadInputPoint: { limit: 5 timespan: 1000 }` | none; the category is in the production library's hot path — check whether `GeometryCore.cxx:481` can flood |
| `statistics` destination (end-of-job summary) | `unit_test_base.h` default config | none |
| Context singlet / iteration | `StandaloneBasicSetup.h`, `geometry_loader_test.cxx` | subsumed by the scoped-name prefix |
| Verbatim (prefix-free) output | 51 `LogVerbatim` + 35 `LogProblem` sites, all in tests | choose a minimal spdlog pattern for tests |
| Compile-time debug suppression | never enabled here | intentionally not adopted (§2.5) |

The `GeometryBadInputPoint` rate limit is the one worth checking before you drop it:
`GeometryCore.cxx:481` warns per out-of-world point, and mf was capping it at 5 per
1000 s. Under spdlog it will warn every time. If that path can be hit in a loop, add
an explicit counter guard at the call site.

---

## 9. Effort estimate

| Phase | Work | Days |
|---|---|---:|
| 0 | spack/spdlog availability | 0.5 |
| 1 | `Logging.h` + test + CMake | 1.0 |
| 2 | production library (11 files, 26 sites) | 1.0 |
| 3 | public headers, API + deprecation | 1.5 |
| 4 | test tree (356 sites, ~15 hard) | 3.5 |
| 5 | build system + `.fcl` | 0.5 |
| 6 | validation, output diffing | 1.5 |
| **Total** | | **9.5** |

The estimate is dominated by Phase 4's volume and Phase 3's API risk, not by
technical difficulty — the design work is already done and verified (§3.1).

---

## 10. Rollback

Phases 2, 3 and 4 are independently revertible because `Logging.h` (Phase 1) is
purely additive and mf and spdlog coexist without conflict. Commit one phase per
commit, and within Phase 4 one file per commit. If a phase misbehaves, revert that
commit; nothing else depends on it.

The one irreversible-in-practice step is removing
`find_package(messagefacility ... EXPORT)` from the top-level CMake (Phase 5.1),
because downstream packages consume it. Do that last, after everything else is green.

---

## 11. Open questions for you

1. **Output pattern.** Do you want the spdlog pattern to include a timestamp and
   level (`[%Y-%m-%d %H:%M:%S.%e] [%^%l%$] %v`), or the minimal `%v` that most
   closely reproduces the current `LogVerbatim`-heavy test output? The test-output
   diff in Phase 6 is much easier with `%v`.
2. **File destinations.** Both `.fcl` files write a log file
   (`geometry_lartpcdetector.txt`, `debug.log`). Keep them as a second spdlog sink,
   or drop them?
3. **`GeometryBadInputPoint` rate limiting** (§8) — is that warning path reachable in
   a loop in practice? If so, an explicit guard is needed.
4. **Deprecation window.** Keep the `SetupMessageFacility` forwarders for one release,
   or break downstream immediately?

---

## 12. Notes on the previous plan (`MIGRATION_PLAN.md`)

The earlier plan is a reasonable generic template, but applying it as written would
have failed. Specific issues:

**Factually wrong in ways that change the plan.**

- It reports "464 occurrences" and per-file counts that do not match the tree:
  `GeometryTestAlg.cxx` has 203 log call sites (it says 176), and
  `GeometryIteratorLoopTestAlg.cxx` has 150 (it says 151, counting the include).
  More importantly, it lists `unit_test_base.h` at 21 and `StandaloneBasicSetup.h` at
  12 occurrences; the real figures are 10 log calls and 4 init calls. The distribution
  matters because it determines that **93 % of the work is in the test tree**, which
  the old plan never states.
- It lists `larcorealg/CMakeLists.txt` as containing a messagefacility reference. It
  does not — that file is six lines of `add_subdirectory`. The reference is in the
  **top-level** `CMakeLists.txt:29`, and crucially it is `find_package(... EXPORT)`,
  which the old plan never mentions even though it is the one change with
  downstream-visible consequences.
- It claims `WireGeo.cxx` has "1 occurrence" needing migration. It has a dead include
  and zero uses.

**Technically unsound recommendations.**

- **Option B (named loggers with format strings) is recommended, and it cannot work
  here.** Converting `<<` chains to `logger->info("...{}...", args)` breaks every one
  of the four `Stream&&` call sites (`GeometryTestAlg.cxx:453, 458, 509, 761`), because
  those pass the log object *itself* into templates that stream to it. It also breaks
  all 10 `lar::dump::` manipulator uses, and would require `fmt::formatter`
  specializations for `geo::WireID`, `geo::Point_t`, `cet::exception` and friends. The
  old plan does not mention the `Stream&&` protocol at all — it is the single most
  important constraint in this package.
- **Its Appendix B `StreamLogger` has a real bug.** `LogInfo()` etc. return
  `StreamLogger` **by value**, but the class declares a destructor and no move
  constructor, so the move constructor is not implicitly generated; the code as
  written does not compile in C++17 without a copy/move constructor, and adding a
  copy constructor would emit the message twice. My §3 `LogStream` is constructed
  directly by a macro instead, sidestepping this.
- **Its `StreamLogger` destructor calls `logger_->log(level_, stream_.str())`.** With
  spdlog 1.12 that overload treats the string as a **format string**, so any message
  containing `{` — which includes every `lar::dump::vector3D` output, `{ 0; 0; 0 }` —
  produces `[*** LOG ERROR ***] invalid format string` instead of the message. I
  reproduced this against the installed library. This is the sort of defect that
  passes review and then corrupts exactly the diagnostic output you need most.
- `GetLogger()` as written (`spdlog::get` then `stdout_color_mt`) has a **race**: two
  threads can both miss and both attempt registration, and the loser throws
  `spdlog_ex`. It also allocates a logger per category, forever. Moot under the
  default-logger convention, but it illustrates that the sketch was not tested.
- It recommends `SPDLOG_ACTIVE_LEVEL` compile-time filtering as a feature. Here that
  would break `unit_test_base.h:1112`, which deliberately asserts that trace/debug
  are *not* compiled away.

**Things it omits entirely.**

- The `Stream&&` printing protocol (8 production headers) — the hardest constraint.
- The 13 named accumulating log objects and their destructor-flush semantics,
  including one that must survive a `throw`.
- `mf::isDebugEnabled()`, `std::endl`, empty-category log objects.
- The mf destination DSL embedded as a raw string in `unit_test_base.h:289-310`, and
  the `messageLevels` FHiCL knob that is part of that header's public contract.
- The two `.fcl` `services.message` blocks, and the fact that per-category limits and
  `timespan` rate limiting have no spdlog equivalent.
- Any statement of what is *lost* in the migration (§8 here).
- The actual spdlog build available on cvmfs: 1.12.0, compiled (not header-only),
  bundled fmt 9.1.0, no MDC header — all of which constrain the design.

**Process points.**

- Its success criterion "log output is clear and useful" is not checkable. Replace
  with a normalized before/after output diff (§6.2), which is.
- Its timeline (9–13 days) is about right in total, but it allocates 2 days to the
  core library and 2–3 to tests. The real split is ~1 day for the library and ~3.5
  for the tests.
- It proposes a compatibility layer redefining `MF_LOG_*` and aliasing into
  `namespace mf`. Do not do this. Squatting on another project's namespace to keep
  464 call sites unchanged converts a finished migration into a permanent one, and
  the aliases (`using LogInfo = lar::logging::LogInfo;`) are ill-formed anyway —
  `LogInfo` there is a *function*, not a type.

What the old plan gets right and is retained here: the phased structure, the level
mapping table, the file-by-file checklist, and the instinct that a stream wrapper
(its Option C) is the low-disruption path. Option C was the correct answer; the plan
recommended Option B instead.
