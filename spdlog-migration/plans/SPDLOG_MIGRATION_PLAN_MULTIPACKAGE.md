# Migration Plan: messagefacility to spdlog — larcorealg + lardataobj + lardataalg (revision 3)

**Packages:** `larcorealg` (v10.00.04), `lardataobj`, `lardataalg`
**Target:** replace `messagefacility` with `spdlog`
**Convention (unchanged):** all logging via the **spdlog default logger**; each message
begins with the **fully scoped class and method/function name** of its origin.

This document supersedes `SPDLOG_MIGRATION_PLAN.md` (revision 2), which covered
`larcorealg` only. Revision 2's analysis of `larcorealg` remains valid and is not
repeated in full; §2 here lists the **one change to its core design** that the new
packages force, and §3 onward covers the additions.

---

## 0. Answer to the question asked

**Yes — there are new use cases, and one of them breaks the revision-2 design.**

Four findings, in descending order of importance:

| # | New use case | Where | Impact |
|---|---|---|---|
| **1** | **A log object is stored *by value* as a class member**, not merely forwarded | `lardataalg/Dumpers/DumperBase.h:167` (`Indenter<Stream>::out`) | **Revision 2's `LogStream` does not compile.** Requires a move constructor. Verified. |
| **2** | `std::setw` / `std::setprecision` / `std::fixed` streamed into a log | `lardataalg` test + `Dumpers` | Requires an `std::ios_base` manipulator overload that revision 2 lacks |
| **3** | mf-using classes are **ROOT-persisted data products** with `classes_def.xml` entries | `lardataobj` RawData / Simulation / RecoBase | Investigated: **safe**, but must be verified, not assumed |
| **4** | A dimensional-analysis type system streamed into logs via **ostream-only ADL** `operator<<` | `lardataalg/Utilities/quantities.h` etc., ~51 sites | Works, but it is the largest single point of compile failure; must be smoke-tested first |

Findings 1 and 2 are **corrections to `Logging.h`**. Findings 3 and 4 are risks to
manage, not design changes.

Everything else in the two new packages is *easier* than `larcorealg`: no
initialization code, no `.fcl` message blocks, no `isDebugEnabled`, no empty
categories, no log-across-throw, and no Boost.Test interaction.

---

## 1. Measured scope across all three packages

| | `larcorealg` | `lardataobj` | `lardataalg` |
|---|---:|---:|---:|
| mf call sites | ~392 | **10** (+1 commented) | **68** |
| Files with mf | 20 + 4 CMake | 5 + 4 CMake | 9 + 3 CMake |
| mf in headers | 3 | **0** | **3** |
| Named accumulating log objects | 13 | 0 | **2** |
| Log stored by value in a member | 0 | 0 | **1 (template)** |
| `Stream&&` protocol entry points | 8 headers | **31** (unused w/ mf today) | `DumperBase` + `MCDumpers` |
| iomanip into logs | 0 | 0 | **yes** |
| mf initialization calls | 13 | **0** | **0** |
| `.fcl` `message:` blocks | 2 | **0** | **0** |
| ROOT dictionaries | 1 | **7** | 0 |
| `mf::isDebugEnabled` | 2 | 0 | 0 |
| Boost.Test + mf together | no | no | no |

### 1.1 `lardataobj` — 10 live call sites, 5 files

| Form | Count | Locations |
|---|---:|---|
| `mf::LogWarning` | 7 | `RawData/raw.cxx:1064`; `RecoBase/Event.cxx:29, 40`; `Simulation/SimChannel.cxx:158, 223`; `Simulation/OpDetBacktrackerRecord.cxx:254, 318` |
| `MF_LOG_ERROR` | 3 | `Simulation/SimChannel.cxx:64`; `Simulation/OpDetBacktrackerRecord.cxx:44, 148` |

`RawData/OpDetPulse.cxx:22` has its only `mf::LogWarning` **inside a `/* */` comment**;
the `#include` at `:15` and the target's mf link can simply be deleted.

**No mf in any `lardataobj` header.** All 10 sites are single-statement temporaries in
`.cxx` files. This package is the easiest of the three.

### 1.2 `lardataalg` — 68 call sites, 9 files

| Form | Count | Notes |
|---|---:|---|
| `mf::LogVerbatim` | 29 live (+1 in a doc comment) | 25 in `DetectorTimingsStandard_test.cc` |
| `mf::LogProblem` | 25 | all in `DetectorTimingsStandard_test.cc`; used as a *test-failure reporter* |
| `mf::LogWarning` | 5 | 2 production, 3 in `*TestHelpers.h` |
| `mf::LogError` | 4 | test summaries |
| `MF_LOG_TRACE` | 3 | all in `*TestHelpers.h` |
| `mf::LogInfo` | 2 | one is a **named object** (`DetectorPropertiesStandard.cxx:70`) |

Neither new package calls `StartMessageFacility`, `SetApplicationName`,
`SetContextSinglet`, `SetContextIteration`, or `isDebugEnabled`. **Both rely entirely
on `larcorealg`'s `unit_test_base.h` for initialization**, so the init shim built in
revision 2 Phase 3 covers all three packages with no extra work.

### 1.3 Build order

`lardataalg` → depends on → `lardataobj`, `larcorealg`, `larcoreobj`
`lardataobj` → depends on → `larcoreobj` (**not** `larcorealg`)

Both new packages carry `find_package(messagefacility REQUIRED EXPORT)`
(`lardataobj/CMakeLists.txt:29`, `lardataalg/CMakeLists.txt:28`) — the same
downstream-visible `EXPORT` issue flagged in revision 2 §12.

**Migration order is forced: `larcorealg` → `lardataobj` → `lardataalg`.**
`lardataalg` cannot compile until `larcorealg`'s `Logging.h` and its
`lar::dump::` manipulators are in place, because `MCDumpers.h:262` streams
`lar::dump::vector3D` into a generic `Stream`.

---

## 2. REQUIRED CHANGE to `Logging.h` (revision 2 §3)

### 2.1 The defect

`lardataalg/Dumpers/DumperBase.h:166-177` stores the stream **by value**:

```cpp
template <typename Stream>
class Indenter {
  Stream out;                     // <-- BY VALUE, not a reference
  DumperBase const& dumper;
public:
  Indenter(Stream out, DumperBase const& dumper)
    : out(std::forward<Stream>(out)), dumper(dumper)
  {}
  ...
};

template <typename Stream>
decltype(auto) indenter(Stream&& out) const
{ return Indenter<Stream>(std::forward<Stream>(out), *this); }   // :215-217
```

Called as the public API documents (`Dumpers/RawData/OpDetWaveform.h:39`),
`dump(mf::LogVerbatim("dumper"), waveform)`, `Stream` deduces to a **value type**,
so `Indenter` **owns** the log object and flushes it when the `Indenter` dies at the
end of `dump()` — long after the caller's full-expression ended.

Revision 2's `LogStream` declares a destructor and deletes the copy constructor, so
**no move constructor is implicitly generated**. I compiled the revision-2 class
against a reduction of `Indenter` and it fails:

```
error: use of deleted function 'lar::log::LogStream::LogStream(const lar::log::LogStream&)'
  return Indenter<Stream>(std::forward<Stream>(out), *this);
```

This is exactly the class of defect I criticized in the *original* `MIGRATION_PLAN.md`
(revision 2 §12: "returns `StreamLogger` by value... the move constructor is not
implicitly generated"). It did not matter for `larcorealg`; it is fatal for `lardataalg`.

### 2.2 The fix

Add a move constructor that **transfers the buffer and disarms the source**, so the
message is emitted exactly once by whichever object survives. Also add the
`std::ios_base` manipulator overload required by `std::setw` (§3.2).

```cpp
    // Move constructor: required because dump::DumperBase::Indenter<Stream>
    // stores the stream BY VALUE (lardataalg/Dumpers/DumperBase.h:167).
    // The source is disarmed so the message is emitted exactly once.
    LogStream(LogStream&& other)
      : buf_{std::move(other.buf_)}
      , where_{other.where_}
      , level_{other.level_}
      , active_{other.active_}
    { other.active_ = false; }

    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;
    LogStream& operator=(LogStream&&) = delete;   // mf also deletes move-assign

    /// Supports `std::setw`, `std::setprecision`, `std::fixed`, ...
    LogStream& operator<<(std::ios_base& (*manip)(std::ios_base&))
    {
      if (active_) buf_ << manip;
      return *this;
    }
```

Deleting move-assignment matches messagefacility's own contract
(`MaybeLogger_& operator=(MaybeLogger_&&) = delete;`), so no downstream code can
depend on it.

### 2.3 Verification performed

Compiled with `g++ -std=c++17 -Wall -Wextra -pedantic` against the installed
spdlog 1.12, and run under valgrind (clean):

| Case | Result |
|---|---|
| `Indenter<LogStream>` owning a moved-in log (prvalue arg) | works, one record |
| `Indenter<LogStream&>` holding a reference (lvalue arg, via `operator()`) | works, one record |
| explicit `auto b = std::move(a);` | **emitted exactly once**, not twice |
| `std::setw` / column-formatted table (the `DetectorPropertiesStandard_test.cc:161` shape) | works |
| `where_` (`std::string_view` into a `__PRETTY_FUNCTION__` static) surviving the move out of the caller's frame | valgrind-clean; string literals have static storage duration |
| ostream-only ADL `operator<<` for a `quantities`-shaped type | works |

Sample output of the `Indenter` case:

```
info: dump::raw::OpDetWaveformDumper::dump: OpDetWaveform ch=3 with 6 samples
 1024 2048
```

### 2.4 A behavioural note on the scoped prefix in dumpers

When a `LogStream` is created at a call site and then moved into an `Indenter`, the
prefix records **the call site**, not the dumper internals:

```cpp
void MyModule::dumpWaveforms() {
  dumper.dump(LAR_LOG_INFO, waveform);
}
// -> "MyModule::dumpWaveforms: on channel #3 ..."
```

That is the desirable behaviour — the reader wants to know who asked for the dump —
but it must be documented, because it differs from what a reader might expect if they
assume the prefix is captured where the message is *composed*.

---

## 3. Genuinely new patterns, and what to do about each

### 3.1 Log object stored by value in a class member

Covered by §2. **One code site, in a public installed header.** Beyond the `Logging.h`
fix, the only work is updating the doc comment at
`lardataalg/Dumpers/RawData/OpDetWaveform.h:33-41`, which is the *specification* of
the `Stream` contract:

```cpp
 * for (raw::OpDetWaveform const& waveform: waveforms)
-*   dump(mf::LogVerbatim("dumper"), waveform);
+*   dump(LAR_LOG_INFO, waveform);
```

Note `Dumpers` neither includes nor links messagefacility — the dumper is
mf-agnostic by construction. Nothing to unlink there.

**Pre-existing defects found in this header; fix or leave, but do not be surprised by them:**

- `DumperBase.h:110` — `template <typename Stream> Stream& indented(Stream&& out, ...)`
  returns an *lvalue reference* to what may be a temporary. Latent dangling reference,
  present today with mf. Do not make it worse.
- `OpDetWaveform.h:122` — `operator()` takes `Stream&&` but forwards `stream` as an
  **lvalue** (`dump(stream, waveform)`, missing `std::forward`). So the two public
  entry points have *different* ownership semantics: `dump()` moves the log in,
  `operator()` binds a reference to the caller's temporary. Both work with the fixed
  `LogStream` (verified), but any test must cover both paths.

### 3.2 iomanip streamed into logs

New vs `larcorealg`, which had only a single `std::endl`. Sites:

```cpp
// lardataalg/test/DetectorInfo/DetectorPropertiesStandard_test.cc:161-179
mf::LogVerbatim log("detp_test");
log << std::setw(columnSizes[0]) << "Drift:"
    << " | " << std::setw(columnSizes[1]) << "time [us]" ...;
for (auto const& TPCID : geom.Iterate<geo::TPCID>()) {
  log << "\n" << std::setw(columnSizes[0]) << TPCID << " | " ...;
}
```
```cpp
// lardataalg/Dumpers/RawData/OpDetWaveform.h:220-221
for (auto digit : DigitBuffer)
  out << " " << std::setw(4) << digit;
```

`std::setw` returns an unspecified type convertible to a manipulator taking
`std::ios_base&` — **not** `std::ostream&` — hence the second overload in §2.2.
mf supports this via `MaybeLogger_::operator<<(std::ios_base& (*)(std::ios_base&))`.

`DetectorPropertiesStandard_test.cc:161` is the hardest single site in either new
package: named object + iomanip + loop + embedded `\n`. It is handled by the fixed
`LogStream` unchanged apart from the constructor.

### 3.3 ROOT data products and dictionaries — investigated, and it is safe

`lardataobj` has **7 `build_dictionary()` targets**, and all four mf-using classes are
ROOT-persisted with `ClassVersion` entries:

- `raw::OpDetPulse` — `RawData/classes_def.xml:34`
- `sim::SimChannel` — `Simulation/classes_def.xml:50`
- `sim::OpDetBacktrackerRecord` — `Simulation/classes_def.xml:72`
- `recob::Event` — `RecoBase/classes_def.xml:112`

I checked whether logging can be triggered during ROOT I/O. **It cannot**, for three
independent reasons:

1. **No mf-using header exists.** Zero `mf::`/`messagefacility` matches in any
   `lardataobj/**/*.h`. The dictionary source, generated from `classes.h`, never sees
   the messagefacility headers. (This is the key structural difference from
   `larcorealg`.)
2. **No `ClassDef`/`ClassDefNV` and no hand-written `Streamer()` anywhere** in either
   new package. LArSoft uses selection XML + `genreflex`.
3. **Every `<ioread>` schema-evolution rule is a trivial member assignment.** I read
   all of them in the three `classes_def.xml` files; none calls `raw::Uncompress()`,
   `SimChannel::AddIonizationElectrons()`, `recob::Event::Energy()`, or any other
   mf-touching function.

**Conclusion: no logging occurs during deserialization, so there is no risk of the
spdlog default logger being invoked from a ROOT streamer at static-init time.**
Revision 2's choice of spdlog's *lazily created* default logger already makes even
that scenario safe, but it is worth having confirmed rather than assumed.

One adjacent item worth knowing: `Simulation/Compatibility/load_fixit_file.cxx:17`
runs a file-loading function in a **namespace-scope initializer** (`auto rc = load_fixit_file();`),
i.e. before `main()`. It contains no logging today. **Do not add any.** If it ever needs
logging, spdlog's lazy default logger handles it; messagefacility would not have.

### 3.4 `util::quantities` — ostream-only ADL, ~51 sites, one shared failure mode

`lardataalg` has a dimensional-analysis system whose stream support is
**non-templated and `std::ostream`-only**:

```cpp
// lardataalg/Utilities/quantities.h:826
template <typename... Args>
std::ostream& operator<<(std::ostream& out, Quantity<Args...> const q)
{ return out << q.value() << " " << q.unit(); }

// also: quantities.h:477 (ScaledUnit), intervals.h:428 (Interval), intervals.h:895 (Point)
```

These work with mf only because `mf::MaybeLogger_::operator<<` is a fully generic
template that funnels into a real `std::ostringstream`. `LogStream` does the same, so
they work — **verified** with a reduction of the `Quantity`/`Point` shape:

```
info: testTriggerTime: DetectorTimings::TriggerTime() => 4.5 us
error: testTriggerTime: Trigger time expected to be 4.5 us, but got 1.25 us instead
```

**The risk is concentration, not correctness.** All ~51 sites in
`DetectorTimingsStandard_test.cc` stream quantities. If the replacement type ever
stops reducing to `std::ostream&` — e.g. if someone "optimizes" `LogStream` to write
directly into an `fmt::memory_buffer` — **all 51 fail at once**. Mitigation:
a single-file smoke test compiled *before* the bulk edit (Phase D1 below), and an
explicit comment in `Logging.h` stating that the `std::ostringstream` member is load-bearing.

### 3.5 `mf::LogProblem` as a test-assertion framework

`DetectorTimingsStandard_test.cc` is a plain `int main()` (no Boost), and its 25
`LogProblem` calls **are** the failure reporter:

```cpp
if (time.value() == expectedTime) {
  mf::LogVerbatim("DetectorTimingsStandard_test") << "DetectorTimings::TriggerTime() => " << time;
}
else {
  ++nErrors;
  mf::LogProblem("DetectorTimingsStandard_test")
    << "Trigger time expected to be " << expectedTime << " ... but got " << time << " instead";
}
```

Under a single default logger with a default level of `info`, an `err`-level message
is still emitted, and `nErrors` still drives the exit code — so **test semantics are
preserved**. But note: 25 identical `if/else` pairs make this the most mechanically
`sed`-able file in all three packages, and also the one where a bad `sed` would
silently convert failures into successes. Migrate it with the level mapping
`LogProblem -> LAR_LOG_ERROR` and verify by deliberately breaking one assertion.

### 3.6 Patterns confirmed ABSENT in both new packages

Checked explicitly, so the plan does not carry dead weight:

- no `mf::isDebugEnabled()`;
- no mf initialization of any kind;
- no `.fcl` `message:` service blocks (all 15 `lardataalg` fcl files checked);
- no log object alive across a `throw` (the one that looks like it,
  `SimChannel.cxx:60-68`, has a **stale `// will throw` comment** — mf's `LogError`
  does not throw; do not "restore" throwing behaviour);
- no log objects captured directly in lambdas (though an `Indenter` holding one is
  captured by reference at `OpDetWaveform.h:172-183`, which works);
- no mf + Boost.Test co-occurrence — the 13 Boost tests in `lardataobj` and the
  mf-using tests in `lardataalg` are disjoint sets;
- no empty-category log objects.

---

## 4. Revised `Logging.h` (delta only)

Apply to the revision 2 §3 listing. Full class shown for the changed parts:

```cpp
  class LogStream {

    std::ostringstream buf_;   // load-bearing: quantities/dump manipulators rely on
                               // this reducing to std::ostream& (plan rev3 3.4)
    std::string_view where_;
    spdlog::level::level_enum level_;
    bool active_;

  public:

    LogStream(spdlog::level::level_enum level, std::string_view where)
      : where_{where}, level_{level}, active_{spdlog::should_log(level)}
    {}

    /// Move constructor. REQUIRED: dump::DumperBase::Indenter<Stream> stores the
    /// stream by value (lardataalg/Dumpers/DumperBase.h:167). Disarms the source
    /// so the message is emitted exactly once.
    LogStream(LogStream&& other)
      : buf_{std::move(other.buf_)}
      , where_{other.where_}
      , level_{other.level_}
      , active_{other.active_}
    { other.active_ = false; }

    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;
    LogStream& operator=(LogStream&&) = delete;

    ~LogStream()
    {
      if (!active_) return;
      auto const body = buf_.str();
      if (body.empty()) return;
      // body is an ARGUMENT, never a format string (plan rev2 2.3).
      if (where_.empty()) spdlog::log(level_, "{}", body);
      else                spdlog::log(level_, "{}: {}", where_, body);
    }

    explicit operator bool() const noexcept { return active_; }

    template <typename T>
    LogStream& operator<<(T const& value) { if (active_) buf_ << value; return *this; }

    /// `std::endl`, `std::flush`, ...
    LogStream& operator<<(std::ostream& (*manip)(std::ostream&))
    { if (active_) buf_ << manip; return *this; }

    /// `std::setw`, `std::setprecision`, `std::fixed`, ... (plan rev3 3.2)
    LogStream& operator<<(std::ios_base& (*manip)(std::ios_base&))
    { if (active_) buf_ << manip; return *this; }

  }; // class LogStream
```

Add `#include <ios>` alongside `<ostream>`.

### 4.1 Where `Logging.h` lives

Keep it in `larcorealg/CoreUtils/Logging.h` as planned. `lardataalg` already depends
on `larcorealg` (`lardataalg/CMakeLists.txt:37`), so it gets it for free.

**`lardataobj` does *not* currently depend on `larcorealg`.** Two options:

- **(a) Add the dependency.** One `find_package(larcorealg REQUIRED EXPORT)` line.
  Simple, but couples a pure data-product library to an algorithm library — LArSoft
  has deliberately kept `lardataobj` free of `larcorealg`, and this would be a
  layering regression visible to every downstream package.
- **(b) Have `lardataobj` use spdlog directly.** Its 10 call sites are all
  single-statement temporaries needing none of `LogStream`'s machinery — but then
  the scoped-prefix convention has to be applied by hand, or the macro duplicated.
- **(c, recommended) Put `Logging.h` in `larcoreobj`**, which *both* `larcorealg`
  and `lardataobj` already depend on. It is a header-only utility with no algorithm
  content, so it belongs there on merit, not merely for convenience.

I recommend **(c)**. It costs one extra file move during Phase A and avoids both a
layering regression and code duplication. Confirm `larcoreobj` is in scope for edits
before committing to it; if it is not, take **(a)** and document the layering change.

This is the one open decision that blocks Phase A. See §9.

---

## 5. Revised phase plan

Revision 2's Phases 0-6 become Phase A (all packages share the foundation), then one
phase per package in dependency order.

### Phase A — Foundation (was rev2 Phases 0-1) — 1.5 days

1. Add `spdlog` to `mpddev/local/spack.yaml` specs; confirm it resolves to the
   existing cvmfs install (`spdlog-1.12.0-dwa4wahktue5dmuyodu2bp2rjn6bomnw`).
2. Decide the `Logging.h` home (§4.1). **Blocking.**
3. Add `Logging.h` + `Logging.cxx` (`lar::log::setup()` only) **with the §2.2 fixes**.
4. `find_package(spdlog REQUIRED EXPORT)` in the top-level CMake of whichever package
   hosts it.
5. Unit test covering the revision 2 §3.1 checklist **plus** the four new cases:
   move-once semantics, `Indenter`-by-value ownership, `Indenter`-by-reference,
   `std::setw`.

**Exit:** foundation test green; no production file changed yet.

### Phase B — `larcorealg` (was rev2 Phases 2-5) — 6.5 days

Unchanged from revision 2 §4. ~392 sites; the bulk is `GeometryTestAlg.cxx` (203)
and `GeometryIteratorLoopTestAlg.cxx` (150).

One addition: when migrating `larcorealg/CoreUtils/DumpUtils.h`, **do not narrow**
`template <typename Stream> Stream& operator<<(Stream&&, ArrayDumper<Array>&&)`
(`:361, 397`) to `std::ostream&`. `lardataalg/MCDumpers/MCDumpers.h:262` streams
`lar::dump::vector3D` into a generic `Stream`, and downstream code calls
`DumpMCTruth(LAR_LOG_INFO, truth)`. Narrowing it would break `lardataalg` and every
experiment package.

### Phase C — `lardataobj` — 1 day

The easiest package. 10 sites, 5 files, no headers, no init, no fcl.

1. `RawData/OpDetPulse.cxx` — delete the include at `:15` and the commented-out log
   at `:22`; drop nothing else (the file has zero live mf uses).
2. `RawData/raw.cxx:1064` — see the rate-limiting note below.
3. `RecoBase/Event.cxx:29, 40` — see the rate-limiting note below.
4. `Simulation/SimChannel.cxx:64, 158, 223` — mechanical. Also **delete the stale
   `// will throw` comment at `:63`**; it has been wrong for years.
5. `Simulation/OpDetBacktrackerRecord.cxx:44, 148, 254, 318` — mechanical; same stale
   comment at `:43` and `:147`.
6. Drop `messagefacility::MF_MessageLogger` from `RawData/CMakeLists.txt:17`,
   `Simulation/CMakeLists.txt:27`, `RecoBase/CMakeLists.txt:48` (all `PRIVATE`, so no
   interface change), and `find_package(messagefacility ... EXPORT)` from
   `CMakeLists.txt:29` (interface change — announce).
7. **Rebuild dictionaries and run a read-back test.** Even though §3.3 shows I/O is
   unaffected, this is a data-product library; confirm `ClassVersion`/checksums in the
   three `classes_def.xml` files are unchanged and that existing ROOT files still read.

**Two rate-limiting regressions to handle here** (the same class of problem as
revision 2 §8):

- `RecoBase/Event.cxx:29` — `Event::Energy()` warns *every call*, and
  `operator<(Event, Event)` (`:71-74`) calls it **twice per comparison**. Sorting a
  `std::vector<recob::Event>` therefore emits O(n log n) warnings. mf capped these by
  category; spdlog will not. **Add an explicit one-shot guard** (a function-local
  `static std::once_flag`, or emit at `debug` level).
- `RawData/raw.cxx:1064` — inside the `for` loop of
  `raw::UncompressHuffman()` (`:1026`), reachable once per corrupt ADC word. A
  malformed waveform could emit thousands. **Add a per-call counter guard.**

**Exit:** `lardataobj` builds, links and passes its 13 Boost tests with no mf.

### Phase D — `lardataalg` — 2.5 days

**D1. Smoke test first (0.25 day).** Before touching the 51-site file, migrate exactly
one `mf::LogVerbatim` that streams a `util::quantities` value (e.g.
`DetectorTimingsStandard_test.cc:83`) and compile. This proves §3.4 in the real build
rather than in my reduction. If it fails, stop — everything else depends on it.

**D2. Production library (0.5 day).**
- `DetectorInfo/DetectorPropertiesStandard.cxx:70` — the **named object** in
  `ValidateAndConfigure()`; keep the enclosing `{ }` block, which exists so the
  message flushes before the `fhicl::Table` validation at `:81` can throw.
- `DetectorInfo/DetectorPropertiesStandard.cxx:228, 237` — mechanical.

**D3. The three `*TestHelpers.h` (0.5 day).** `DetectorClocksStandardTestHelpers.h`,
`DetectorPropertiesStandardTestHelpers.h`, `LArPropertiesStandardTestHelpers.h`.
Each has one `MF_LOG_TRACE` + one `mf::LogWarning`, identical in shape. Because these
are **public installed headers**, `lardataalg::DetectorInfo_TestHelpers` must carry
the logging dependency as `INTERFACE`, replacing
`messagefacility::MF_MessageLogger` at `DetectorInfo/CMakeLists.txt:33`.
Also fix the stale UPS-era dependency lists in their header comments (`mf_MessageLogger`,
`lardata_DetectorInfo`).

**D4. `Dumpers` doc comment (0.25 day).** `Dumpers/RawData/OpDetWaveform.h:39`.
Exercise **both** entry points (`dump()` and `operator()`) in a test — they have
different ownership semantics (§3.1).

**D5. Test tree (1 day).** `DetectorTimingsStandard_test.cc` (51),
`DetectorPropertiesStandard_test.cc` (4, incl. the `std::setw` named object at `:161`),
`DetectorClocksStandard_test.cc` (2), `LArPropertiesStandard_test.cc` (2).
Fix the copy-paste category `"clocks_test"` at `DetectorTimingsStandard_test.cc:714`
while you are there — it becomes a scoped name anyway.

**D6. CMake (0.25 day).** `DetectorInfo/CMakeLists.txt:14, 33`,
`test/DetectorInfo/CMakeLists.txt:61`, and `CMakeLists.txt:28`.

**Exit:** all three packages build with no messagefacility reference.

### Phase E — Cross-package validation — 1.5 days

Revision 2 §4 Phase 6, extended:

1. Full `ctest` across all three packages.
2. Normalized before/after stdout diff for the `larcorealg` geometry tests and all
   four `lardataalg` `DetectorInfo` tests.
3. **`lardataobj` ROOT read-back test** (Phase C.7).
4. **Deliberately break one assertion** in `DetectorTimingsStandard_test.cc` and
   confirm it still fails the test (§3.5).
5. Grep sweep across all three trees.
6. **Level check:** `larcorealg`'s default test config uses `threshold: DEBUG`
   (`unit_test_base.h:294-309`), so the three `MF_LOG_TRACE` calls in the
   `*TestHelpers.h` are visible today. spdlog defaults to `info`, so they would
   **silently vanish** — no compile error, no test failure. The init shim must set
   the level explicitly. This is the most likely invisible regression in the whole
   migration.

---

## 6. Revised effort estimate

| Phase | Scope | Days |
|---|---|---:|
| A | Foundation (spdlog, `Logging.h` + fixes, tests) | 1.5 |
| B | `larcorealg` (~392 sites) | 6.5 |
| C | `lardataobj` (10 sites + dictionaries + 2 rate limits) | 1.0 |
| D | `lardataalg` (68 sites + 3 headers + dumper contract) | 2.5 |
| E | Cross-package validation | 1.5 |
| **Total** | | **13.0** |

Revision 2 estimated 9.5 days for `larcorealg` alone; the two new packages add
3.5 days, of which roughly half is validation rather than editing. The new packages
are 78 call sites against `larcorealg`'s ~392, but they carry the *design* risk.

---

## 7. Updated file-by-file checklist (new packages only)

For `larcorealg`, use revision 2 §5 unchanged.

### `lardataobj`
- [ ] `lardataobj/RawData/OpDetPulse.cxx` — delete include `:15` + dead comment `:22`
- [ ] `lardataobj/RawData/raw.cxx:1064` — migrate **+ add loop guard**
- [ ] `lardataobj/RecoBase/Event.cxx:29, 40` — migrate **+ one-shot guard** (`operator<` hot path)
- [ ] `lardataobj/Simulation/SimChannel.cxx:64, 158, 223` — migrate; delete stale `// will throw` at `:63`
- [ ] `lardataobj/Simulation/OpDetBacktrackerRecord.cxx:44, 148, 254, 318` — migrate; stale comments `:43, :147`
- [ ] `lardataobj/CMakeLists.txt:29` — drop `find_package(messagefacility ... EXPORT)`
- [ ] `lardataobj/RawData/CMakeLists.txt:17`
- [ ] `lardataobj/Simulation/CMakeLists.txt:27`
- [ ] `lardataobj/RecoBase/CMakeLists.txt:48`
- [ ] Rebuild all 7 dictionaries; verify `ClassVersion`/checksums unchanged; ROOT read-back test

### `lardataalg`
- [ ] `lardataalg/DetectorInfo/DetectorPropertiesStandard.cxx:70` (named object), `:228, :237`
- [ ] `lardataalg/DetectorInfo/DetectorClocksStandardTestHelpers.h:26, 54, 59`
- [ ] `lardataalg/DetectorInfo/DetectorPropertiesStandardTestHelpers.h:26, 69, 76`
- [ ] `lardataalg/DetectorInfo/LArPropertiesStandardTestHelpers.h:26, 54, 59`
- [ ] `lardataalg/Dumpers/RawData/OpDetWaveform.h:39` — doc comment; test both entry points
- [ ] `lardataalg/test/DetectorInfo/DetectorTimingsStandard_test.cc` (51; fix category at `:714`)
- [ ] `lardataalg/test/DetectorInfo/DetectorPropertiesStandard_test.cc` (4; `std::setw` object at `:161`)
- [ ] `lardataalg/test/DetectorInfo/DetectorClocksStandard_test.cc` (2)
- [ ] `lardataalg/test/DetectorInfo/LArPropertiesStandard_test.cc` (2)
- [ ] `lardataalg/CMakeLists.txt:28`
- [ ] `lardataalg/DetectorInfo/CMakeLists.txt:14, 33` (`:33` is INTERFACE — header dep)
- [ ] `lardataalg/test/DetectorInfo/CMakeLists.txt:61`
- [ ] Verify `larcorealg`'s `lar::dump::` stayed `Stream`-generic (used by `MCDumpers.h:262`)

---

## 8. Additions to the "accepted losses" table (rev2 §8)

| Lost capability | Where | Mitigation |
|---|---|---|
| Category rate limiting on `recob::Event::Energy()` | `Event.cxx:29`, called 2× per `operator<` | **one-shot guard required** — O(n log n) otherwise |
| Category rate limiting in Huffman decompression | `raw.cxx:1064`, inside a loop | **counter guard required** |
| `threshold: DEBUG` visibility of `MF_LOG_TRACE` in test helpers | 3 `*TestHelpers.h` sites | init shim must set level explicitly, or they vanish silently |

The first two are the only places in any of the three packages where a log statement
sits in a genuinely hot path. Both are in `lardataobj`. Neither existed in `larcorealg`.

---

## 9. Open questions

Carried forward from revision 2 §11 (output pattern, file destinations, deprecation
window), plus one new blocking item:

1. **Where should `Logging.h` live?** (§4.1) `larcoreobj` (recommended — both
   packages already depend on it), `larcorealg` + a new `lardataobj`→`larcorealg`
   dependency (layering regression), or duplicate for `lardataobj`. **This blocks
   Phase A.** Is `larcoreobj` in scope for edits?
2. Should the two hot-path guards in `lardataobj` (§8) be one-shot, counted, or
   simply demoted to `debug`? Demoting is the smallest change but hides real
   data corruption in the Huffman case.

---

## 10. Summary of changes from revision 2

| Item | Revision 2 | Revision 3 |
|---|---|---|
| `LogStream` move constructor | absent (implicitly deleted) | **added, with disarm-on-move** — was a compile error |
| `std::ios_base` manipulator overload | absent | **added** — `std::setw` support |
| `std::ostringstream` member | incidental | **documented as load-bearing** (§3.4) |
| Scope | `larcorealg` | three packages, dependency-ordered |
| Header location | `larcorealg/CoreUtils/` | **open question** (§4.1) — `lardataobj` does not depend on `larcorealg` |
| ROOT dictionary risk | not applicable | **investigated, safe** (§3.3) |
| Hot-path logging | none | **two sites in `lardataobj` need guards** (§8) |
| Phases | 0-6 | A-E |
| Estimate | 9.5 days | 13.0 days |

Revision 2's core judgements all survive contact with the new packages: the streaming
interface (not format strings), the never-parse-the-body rule, the compile-time
scoped-name prefix, the default-logger convention, and the phase-per-commit rollback
strategy. The one thing it got wrong is the same thing the *original*
`MIGRATION_PLAN.md` got wrong — a missing move constructor — which is a good argument
for compiling a design against real call sites before writing it into a plan.
