# fhiclcpp::ParameterSet usage analysis

Scope: every repository under
`/exp/dune/app/users/esnider/code-spack/larsoft3/mpdtest/mpddev/srcs`

| repo | branch | HEAD | fhicl? |
|---|---|---|---|
| `larcorealg` | `feature/es-spdlog-migration-gpt-luna-5-6` | `a88caba` | yes, heavy |
| `larcoreobj` | `feature/es-spdlog-migration-gpt-luna-5-6` | `22a191a` | yes, producer only |
| `lardataalg` | `feature/es-spdlog-migration-gpt-luna-5-6` | `675bbf4` | yes, heavy |
| `lardataobj` | `feature/es-spdlog-migration-gpt-luna-5-6` | `9175652` | **no fhicl dependency at all** |

Excluded from the inventory: `larcorealg/spdlog-migration/**` (migration scratch and
captured baselines, not source), and `*.md` planning documents that only discuss fhicl.

Counts: **177 `ParameterSet` tokens in 51 source files**, plus `fhicl::Table` / `Atom` /
`Sequence` / `OptionalAtom` / `OptionalTable` / `OptionalSequence` / `TupleAs` /
`TableFragment` / `detail::encode` / `detail::decode` uses, plus 11 `CMakeLists.txt` with
a `fhiclcpp` dependency.

---

## 0. Executive summary

The thing that matters most for planning is that the surface is **much smaller and much
more regular than the raw token count suggests**.

**Only three consumption idioms exist in the whole tree:**

| # | idiom | instances | difficulty |
|---|---|---|---|
| A | raw `pset.get<T>(key)` / `get<T>(key, default)` in a constructor or `Configure` body | 4 classes | low — mechanical |
| B | `fhicl::Table<Config>` validated-config struct (the art "Config" idiom) | 4 classes | **lowest** — the plain struct already exists in all but name |
| C | degenerate ctor that takes `fhicl::ParameterSet const&` and ignores it entirely | 3 classes | trivial to write, but see §6.1 — it is load-bearing for SFINAE |

**And four files are not consumers at all — they are *producers* of fhicl vocabulary:**

- `larcoreobj/SimpleTypesAndConstants/geo_types_fhicl.h`
- `larcoreobj/SimpleTypesAndConstants/readout_types_fhicl.h`
- `lardataalg/Utilities/quantities_fhicl.h`
- `lardataalg/Utilities/intervals_fhicl.h`

These define `fhicl::Table`-compatible config types and `encode`/`decode` customization
points for *other people's* config structs. They contain no configuration of their own to
extract. They belong wholesale in the interface repositories; there is no "target struct"
to design for them. This is the single largest simplification available, and it is easy to
miss because they account for a large share of the fhicl token count.

**Three structural edge cases** drive the real design work (§6):

1. Nested parameter sets: the keys `"Builder"` and `"SortingParameters"` are sub-`ParameterSet`s
   passed down to a different class. They become nested plain structs, and they are what
   makes the interface layer a *tree* of extractors rather than a flat list.
2. `geo::AuxDetGeometryCore` **stores** a `fhicl::ParameterSet` as a data member and
   validates it lazily, much later, inside `LoadGeometryFile()`.
3. The `TestUtils` test harness is built on *runtime-computed* dotted key paths
   (`"services." + name`, `"physics.analyzers." + name`) and on
   `std::is_constructible_v<T, fhicl::ParameterSet>` as a dispatch trait. This is the only
   part of the tree where a mechanical transformation does not apply.

**`lardataobj` needs no work.** It has no fhicl include, no fhicl symbol, and no fhicl
CMake reference. No `lardataobj-interface` repository should be created.

---

## 1. Inventory by repository

### 1.1 `larcorealg` — 30 live source files + 5 CMakeLists

#### 1.1.1 Consumer classes and functions

| file | entity | role | keys read | required? | forwards to |
|---|---|---|---|---|---|
| `larcorealg/Geometry/GeometryCore.{h,cxx}` | `geo::GeometryCore::GeometryCore(fhicl::ParameterSet const&, unique_ptr<GeometryBuilder>, unique_ptr<GeoObjectSorter>)` | CTOR_ARG | `"RelativePath"` `std::string` = `""`; `"GDML"` `std::string`; `"SurfaceY"` `double`; `"PositionEpsilon"` `double` = `1.e-4` | GDML, SurfaceY **required**; other two optional | whole pset → `details::maybe_default_detector_name` |
| `larcorealg/Geometry/details/maybe_default_detector_name.{h,cxx}` | `std::string geo::details::maybe_default_detector_name(fhicl::ParameterSet const&, std::string const&)` | FUNCTION_ARG | `"Name"` `std::string` via `get_if_present` | optional | — |
| `larcorealg/Geometry/AuxDetGeometryCore.{h,cxx}` | `geo::AuxDetGeometryCore::AuxDetGeometryCore(fhicl::ParameterSet const&, unique_ptr<AuxDetGeoObjectSorter>, unique_ptr<AuxDetInitializer>)` | CTOR_ARG + **MEMBER** | `"RelativePath"` = `""`; `"GDML"`; `"Builder"` **nested `ParameterSet`** = `{}`; `"ThrowIfAbsent"` `bool` = `true` | GDML **required** | whole pset → `maybe_default_detector_name`; `"Builder"` → stored in `fBuilderParameters` |
| `larcorealg/Geometry/AuxDetGeometryCore.h:200` | `fhicl::ParameterSet fBuilderParameters;` | **MEMBER** | — | — | consumed lazily in `LoadGeometryFile()` |
| `larcorealg/Geometry/AuxDetGeometryCore.cxx:88` | `AuxDetGeometryCore::LoadGeometryFile()` | **INTERNAL, delayed** | re-validates `fBuilderParameters` as `fhicl::Table<GeometryBuilderStandard::Config>` with ignorable set `{"tool_type"}` | — | `geo::GeometryBuilderStandard` |
| `larcorealg/Geometry/GeometryExtractor.h` | `geo::GeometryExtractor::Config`; `explicit GeometryExtractor(Config const&)` | **FHICL_TYPES_CONFIG** | `"maxDepth"` `GeoNodePath::Depth_t` = `numeric_limits<>::max()` | optional | — |
| `larcorealg/Geometry/GeometryBuilderStandard.{h,cxx}` | `geo::GeometryBuilderStandard::Config`; `explicit GeometryBuilderStandard(fhicl::Table<Config> const&)` | **FHICL_TYPES_CONFIG** | `fhicl::TableFragment<GeometryExtractor::Config> extractor` (flattens `"maxDepth"`); `"opDetGeoName"` `std::string` = `"volOpDetSensitive"` | both optional | `GeometryExtractor` |
| `larcorealg/Geometry/WireReadoutGeomBuilderStandard.{h,cxx}` | `Config`; ctor from `fhicl::Table<Config>` **and** ctor from `fhicl::ParameterSet` | **FHICL_TYPES_CONFIG** + CTOR_ARG | `TableFragment<GeometryExtractor::Config> extractor` | optional | `GeometryExtractor`; pset ctor delegates via a throwaway `fhicl::Table<Config>{pset}` |
| `larcorealg/Geometry/WireReadoutStandardGeom.{h,cxx}` | `geo::WireReadoutStandardGeom::WireReadoutStandardGeom(fhicl::ParameterSet const&, GeometryCore const*, unique_ptr<WireReadoutSorter>)` | CTOR_ARG | `"Builder"` **nested `ParameterSet`** = `{}` | optional | `geo::WireReadoutGeomBuilderStandard` |
| `larcorealg/Geometry/GeoObjectSorterStandard.{h,cxx}` | `explicit GeoObjectSorterStandard(fhicl::ParameterSet const&)` | CTOR_ARG, **degenerate** | **none** | — | — |
| `larcorealg/Geometry/AuxDetGeoObjectSorterStandard.{h,cxx}` | `explicit AuxDetGeoObjectSorterStandard(fhicl::ParameterSet const&)` | CTOR_ARG, **degenerate** | **none** | — | — |
| `larcorealg/Geometry/WireReadoutSorterStandard.{h,cxx}` | `explicit WireReadoutSorterStandard(fhicl::ParameterSet const&)` | CTOR_ARG, **degenerate** | **none** | — | — |

The three degenerate constructors have empty bodies and an unnamed parameter. They exist
solely so that `std::is_constructible_v<T, fhicl::ParameterSet>` is true — see §6.1.

#### 1.1.2 Standalone entry points (`lar::standalone`)

These are the non-art driver layer. They are the natural seam, because they already play
exactly the role the interface layer is meant to play.

| file | entity | role | keys |
|---|---|---|---|
| `Geometry/StandaloneBasicSetup.h` | `fhicl::ParameterSet ParseConfiguration(std::string, cet::filepath_maker&)` and the 1-arg overload | returns a pset; calls `fhicl::ParameterSet::make` | — |
| `Geometry/StandaloneBasicSetup.h` | `void SetupMessageFacility(fhicl::ParameterSet const&, std::string)` | FUNCTION_ARG, **vestigial** — body is `(void)pset;` after the spdlog migration | none |
| `Geometry/StandaloneGeometrySetup.{h,cxx}` | `GeometryFor(fhicl::ParameterSet const&, unique_ptr<GeoObjectSorter>)` | FUNCTION_ARG | `"Builder"` nested = `{}` → `GeometryBuilderStandard`; whole pset → `GeometryCore` |
| `Geometry/StandaloneGeometrySetup.cxx` | `AuxDetGeometryFor(fhicl::ParameterSet const&, unique_ptr<AuxDetGeoObjectSorter>, unique_ptr<AuxDetInitializer>)` | FUNCTION_ARG | none directly; whole pset → `AuxDetGeometryCore` |
| `Geometry/StandaloneGeometrySetup.h` | `template <typename T> detail::make_unique_maybe_default(fhicl::ParameterSet const&)` | TEMPLATE_PARAM | uses `pset.is_empty()` then `if constexpr (std::is_constructible_v<T>)` |
| `Geometry/StandaloneGeometrySetup.h` | `SetupGeometry<ObjectSorter>(pset)`, `SetupAuxDetGeometry<ObjectSorter>(pset)`, `SetupReadout<ObjectSorter, WireGeom>(pset, geom)` | TEMPLATE_PARAM | each reads `"SortingParameters"` nested = `{}` |

#### 1.1.3 Test harness (`larcorealg/TestUtils`, `larcorealg/test`)

| file | entity | role | notes |
|---|---|---|---|
| `TestUtils/unit_test_base.h:685` | `fhicl::ParameterSet params;` | **MEMBER** | whole-document pset held for the fixture lifetime |
| `TestUtils/unit_test_base.h:607` | `fhicl::ParameterSet const& Parameters() const` | accessor | — |
| `TestUtils/unit_test_base.h:610` | `fhicl::ParameterSet ServiceParameters(std::string) const` | **runtime key** | `params.get<fhicl::ParameterSet>(config.ServiceParameterSetPath(name))` → `"services." + name` |
| `TestUtils/unit_test_base.h:616` | `fhicl::ParameterSet TesterParameters(std::string) const` | **runtime key** | `"physics.analyzers." + name` |
| `TestUtils/unit_test_base.h:1035` | `CompileParameterSet(std::string cfg)` | INTERNAL | FHiCL *string* → pset via `ParameterSet::make` |
| `TestUtils/unit_test_base.h:1049` | `ParseParameters(std::string config_path)` | INTERNAL | uses `fhicl::parse_document` + `cet::filepath_first_absolute_or_lookup_with_dot`; the **only** user of `fhiclcpp/parse.h` and `fhiclcpp/intermediate_table.h` in the tree |
| `TestUtils/unit_test_base.h:1089` | `SetupMessageFacility(pset, appl_name)` | INTERNAL | reads `"services.message"` via the 2-arg `get_if_present(key, out)` overload, prints `to_indented_string(1)`, then discards it — dead after the spdlog migration |
| `TestUtils/unit_test_base.h:1141` | function-local `struct OptionsFromConfig_t` | **FHICL_TYPES_CONFIG** | `"messageLevels"` `bool` = `false`; `"printOptions"` `bool` = `false`; declared *inside a function body* |
| `TestUtils/unit_test_base.h:1175` | `params.get<fhicl::ParameterSet>("test", {})` | nested | → `fhicl::Table<OptionsFromConfig_t>` validation |
| `TestUtils/geometry_unit_test_base.h:238` | `template <typename ObjectSorter> createSorter(fhicl::ParameterSet const& pset [[maybe_unused]])` | **TEMPLATE_PARAM** | `is_constructible_v<ObjectSorter>` then `is_constructible_v<ObjectSorter, fhicl::ParameterSet>`; **no `else`** |
| `TestUtils/geometry_unit_test_base.h:266` | `GeometryTesterEnvironment<...>::CreateNewGeometry()` | TEST_ONLY | `services.Geometry` (runtime path, required) → `"Builder"` = `{}`, `"SortingParameters"` = `{}` |
| `TestUtils/ProviderTestHelpers.h`, `TestUtils/ProviderList.h` | `setupProvider<Prov>(Args&&...)`, `ProviderList::setup<T>(Args&&...)` | **invisible coupling** | zero fhicl includes; perfect-forwards an unconstrained pack documented as a pset |
| `test/Geometry/GeometryTestAlg.{h,cxx}` | `geo::GeometryTestAlg::GeometryTestAlg(GeometryCore const*, WireReadoutGeom const*, AuxDetGeometryCore const*, fhicl::ParameterSet const&)` | CTOR_ARG | `"DisableWireBoundaryCheck"` `bool` = `false`; `"ExpectedWirePitches"` `vector<double>` = `{}`; `"ExpectedPlanePitches"` `vector<double>` = `{}`; `"ComputeMass"` `bool` = `true`; `"ForgiveExceptions"` `vector<string>` = `{}`; `"RunTests"` `vector<string>` = `{}` — all optional. Richest key set in the repo |
| `test/Geometry/geometry_loader_test.cxx` | `main` | TEST_ONLY | `"services.Geometry"` **required**; `"services.WireGeom"` = `{}`; `"services.AuxDetGeometry"` = `{}`; a command-line-supplied path defaulting to `"physics.analyzers.geotest"` |
| `test/Geometry/geometry_{test,iterator_test,geoid_test,standardchannelmapping_test,thirdplaneslope_test,iterator_loop_test}.cxx` | — | TEST_ONLY | include `fhiclcpp/ParameterSet.h` but use **no** fhicl symbol; they call `SetupReadout({}, ...)`. Removable includes |

#### 1.1.4 Producer header

`larcorealg/Geometry/geo_vectors_fhicl.h` — namespace `lar::fhicl::geo`:

```cpp
using Length_t = ::fhicl::Atom<::geo::Length_t>;
template <typename Point>
using Point3D  = ::fhicl::TupleAs<Point(::geo::Length_t, ::geo::Length_t, ::geo::Length_t)>;
using Vector_t = Point3D<::geo::Vector_t>;
using Point_t  = Point3D<::geo::Point_t>;
```

Pure alias templates, no runtime code, **zero in-tree users**. Already isolated as its own
`INTERFACE` CMake target `larcorealg::geo_vectors_fhicl` linking only `fhiclcpp::types`.

### 1.2 `larcoreobj` — producer only

| file | what it is |
|---|---|
| `larcoreobj/SimpleTypesAndConstants/geo_types_fhicl.h` | Maps `geo::CryostatID`, `TPCID`, `OpDetID`, `PlaneID`, `WireID` onto fhicl validated-config objects. Defines `ValidIDConfig` (`isValid` `bool` = `true`), `IDConfig<IDtype>` specializations adding one `fhicl::Atom` per index (`C`, `T`, `O`, `P`, `W`) with a conditional-presence lambda `[this](){ return valid(); }`, four parameter aliases per ID (`Table`, `OptionalTable`, `Sequence<Table>`, `OptionalSequence<Table>`), the `readID`/`readOptionalID`/`readIDsequence`/`readOptionalIDsequence` reader family, the unified `readParameter` overload set, and the `IDparameterTraits` traits class. 20 user-facing typedefs. |
| `larcoreobj/SimpleTypesAndConstants/readout_types_fhicl.h` | Same for `readout::TPCsetID` (atom `S`, `unsigned short`) and `readout::ROPID` (atom `R`). Must open `namespace geo::fhicl` to specialize, then re-exports everything into `readout::fhicl`. 12 typedefs. |
| `larcoreobj/test/SimpleTypesAndConstants/geo_types_fhicl_test.cc` | 1724 lines, 6 Boost cases, 50 helpers. The only `fhicl::ParameterSet` construction in the repo, inside a `validateConfig<Config>(std::string)` harness. |
| `larcoreobj/test/SimpleTypesAndConstants/readout_types_fhicl_test.cc` | 1014 lines, 3 Boost cases, 28 helpers. `validateConfig` duplicated byte-for-byte from the geo test. |

No class or function in `larcoreobj` *consumes* a `ParameterSet`. There is nothing here to
convert to a plain config struct.

### 1.3 `lardataalg` — 10 source files + 6 CMakeLists

#### 1.3.1 `DetectorClocksStandard` — idiom A, raw `get<>`

`lardataalg/DetectorInfo/DetectorClocksStandard.{h,cxx}`

Constructor `DetectorClocksStandard(fhicl::ParameterSet const& pset)` reads, in the
member-init list, nine `double` keys by index through a `fConfigName[]` array, plus two
strings:

| key | type | default | required |
|---|---|---|---|
| `"G4RefTime"` | `double` | — | yes |
| `"TriggerOffsetTPC"` | `double` | — | yes |
| `"FramePeriod"` | `double` | — | yes |
| `"ClockSpeedTPC"` | `double` | — | yes |
| `"ClockSpeedOptical"` | `double` | — | yes |
| `"ClockSpeedTrigger"` | `double` | — | yes |
| `"ClockSpeedExternal"` | `double` | — | yes |
| `"DefaultTrigTime"` | `double` | — | yes |
| `"DefaultBeamTime"` | `double` | — | yes |
| `"TrigModuleName"` | `std::string` | — | yes |
| `"G4RefCorrTrigModuleName"` | `std::string` | `"baddefault"` | no |

Also `bool IsRightConfig(fhicl::ParameterSet const&) const` — **validation only**: asserts
`"module_label"` is absent and all nine `fConfigName` entries are present, via `has_key`.
This is a `ParameterSet`-shaped predicate with no plain-struct analogue; see §6.5.

`"InheritClockConfig"` is documented in the header but **never read anywhere in the tree** —
it is consumed by the art service wrapper outside `lardataalg`.

#### 1.3.2 `DetectorPropertiesStandard` — idiom B, `fhicl::Table<Configuration_t>`

`lardataalg/DetectorInfo/DetectorPropertiesStandard.{h,cxx}`

Public nested `struct Configuration_t` already is, structurally, the plain config struct.
Constructor takes `(fhicl::ParameterSet const& pset, GeometryCore const*, WireReadoutGeom const*,
LArProperties const*, std::set<std::string> const& ignore_params = {})` and forwards to the
private `ValidateAndConfigure(pset, ignore_params)`, which builds
`fhicl::Table<Configuration_t> const config{p, ignorable_keys}` and copies 23 values out.

| key | type | default | required |
|---|---|---|---|
| `"Efield"` | `std::vector<double>` | — | yes |
| `"Electronlifetime"` | `double` | — | yes |
| `"Temperature"` | `double` | — | yes |
| `"ElectronsToADC"` | `double` | — | yes |
| `"NumberTimeSamples"` | `unsigned int` | — | yes |
| `"ReadOutWindowSize"` | `unsigned int` | — | yes |
| `"TimeOffsetU"` | `double` | — | **conditional** |
| `"TimeOffsetV"` | `double` | — | **conditional** |
| `"TimeOffsetZ"` | `double` | — | **conditional** |
| `"TimeOffsetY"` | `double` | — | **conditional** |
| `"TimeOffsetX"` | `double` | — | **conditional** |
| `"SternheimerA"` | `double` | — | yes |
| `"SternheimerK"` | `double` | — | yes |
| `"SternheimerX0"` | `double` | — | yes |
| `"SternheimerX1"` | `double` | — | yes |
| `"SternheimerCbar"` | `double` | — | yes |
| `"DriftVelFudgeFactor"` | `double` | — | yes |
| `"UseIcarusMicrobooneDriftModel"` | `bool` | `false` | no |
| `"IncludeInterPlanePitchInXTickOffsets"` | `bool` | `true` | no |
| `"SimpleBoundaryProcess"` | `bool` | — | yes (**member is named `SimpleBoundary`**) |
| `"ModBoxAlpha"` | `double` | `util::kModBoxA` = `0.930` | no |
| `"ModBoxBeta"` | `double` | `util::kModBoxB` = `0.212` | no |

The five `TimeOffset*` are `fhicl::OptionalAtom<double>`, read with the functional form
`config().TimeOffsetU(fTimeOffsetU)` which writes into the member and returns presence.
Which of them are required is decided *at runtime from the geometry* by the anonymous-namespace
helper `CheckTimeOffsets(std::set<geo::View_t> const&, geo::WireReadoutGeom const&)` — a
parameter is required exactly when the detector has that view. See §6.4.

#### 1.3.3 `LArPropertiesStandard` — idiom B with a two-schema twist

`lardataalg/DetectorInfo/LArPropertiesStandard.{h,cxx}`

- Default ctor (`fIsConfigured(false)`, no pset) **plus**
  `explicit LArPropertiesStandard(fhicl::ParameterSet const&, std::set<std::string> ignore_params = {})`
  **plus** `bool Configure(fhicl::ParameterSet const&, std::set<std::string> ignore_params = {})`.
  Two-phase construction.
- Protected `struct Configuration_t` with 30 required parameters, including two
  **nested** `fhicl::Sequence<fhicl::Sequence<double>>`
  (`"ReflectiveSurfaceReflectances"`, `"ReflectiveSurfaceDiffuseFractions"`).
- Derived `struct ConfigWithScintByType_t : Configuration_t` adding the 12 per-particle
  scintillation yields.
- Public `using ConfigurationParameters_t = ConfigWithScintByType_t;` — explicitly
  commented "expose the configuration object for framework service". This is the public
  contract the art service wrapper validates against.
- **Schema selection at runtime:** `Configure` first does
  `pset.get<bool>("ScintByParticleType", false)`, and when false inserts the 12 per-particle
  keys into the *ignorable* set before constructing
  `fhicl::Table<ConfigWithScintByType_t> config_table{pset, ignorable_keys}`. It obtains those
  key names from a default-constructed `ConfigWithScintByType_t config;` purely "to get the keys".
- Two member names differ from their keys: `MeanExcitationEnergy` ↔ `"ExcitationEnergy"`,
  `ExtraMatProperties` ↔ `"LoadExtraMatProperties"`.
- `LArPropertiesStandard.cxx:32-90` is a complete legacy raw-`pset.get<>` `Configure`
  inside `#if 0`. Dead; do not port.
- An `#if DETECTORINFO_LARPROPERTIESSTANDARD_HASOPTIONALATOM` block (flag is `0`) holds an
  alternative `OptionalAtom` schema, including a `fhicl::detail::fillMissingKeysMsg` /
  `fhicl::detail::validationException` branch. Dead; do not port.

#### 1.3.4 Producer headers

`lardataalg/Utilities/quantities_fhicl.h` and `intervals_fhicl.h` define `encode`/`decode`
customization points in `namespace util::quantities::concepts`:

```cpp
template <typename... Args> void decode(std::any const& src, Quantity<Args...>& q);
template <typename... Args> ::fhicl::detail::ps_atom_t encode(Quantity<Args...> const& q);
```

implemented over `::fhicl::detail::decode` / `::fhicl::detail::encode` plus
`util::makeQuantity` / `util::to_string`. `intervals_fhicl.h` adds the same for `Interval`
and `Point` and chains to the `Quantity` versions. These make
`fhicl::Atom<util::quantities::microsecond>` work, i.e. they let a `.fcl` file say
`end: 16ms`. **The round trip is string-based**: `encode` produces a string, `decode`
parses one. No consumer configuration lives here.

#### 1.3.5 Test helpers

`DetectorClocksStandardTestHelpers.h`, `DetectorPropertiesStandardTestHelpers.h`,
`LArPropertiesStandardTestHelpers.h` each specialize
`testing::ProviderSetupClass<Provider>::setup(fhicl::ParameterSet const& pset, ...)`, read
`"service_provider"` via `get_if_present`, and forward the pset to the provider constructor.
`DetectorPropertiesStandardTestHelpers.h` additionally injects
`std::set<std::string> ignore_keys({"InheritNumberTimeSamples"})`. Each also specializes
`SimpleEnvironmentSetupClass<Provider, TestEnv>` which obtains its pset from
`env.ServiceParameters("<ServiceName>")` — i.e. from the runtime dotted-path machinery in
`unit_test_base.h`.

### 1.4 `lardataobj` — nothing

No `#include "fhiclcpp/..."`, no `fhicl::` symbol, no `fhiclcpp` reference in any
`CMakeLists.txt`. Confirmed by exhaustive grep. **Do not create `lardataobj-interface`.**

---

## 2. Role summary table

| role | count | where |
|---|---|---|
| `CTOR_ARG` | 10 classes | `GeometryCore`, `AuxDetGeometryCore`, `WireReadoutStandardGeom`, `WireReadoutGeomBuilderStandard`, `GeoObjectSorterStandard`*, `AuxDetGeoObjectSorterStandard`*, `WireReadoutSorterStandard`*, `GeometryTestAlg`, `DetectorClocksStandard`, `DetectorPropertiesStandard`, `LArPropertiesStandard` (* = degenerate) |
| `FUNCTION_ARG` | 7 | `maybe_default_detector_name`, `GeometryFor`, `AuxDetGeometryFor`, `SetupMessageFacility` ×2, `LArPropertiesStandard::Configure`, `DetectorPropertiesStandard::ValidateAndConfigure`, `DetectorClocksStandard::IsRightConfig` |
| `MEMBER` | 2 | `AuxDetGeometryCore::fBuilderParameters`, `BasicTesterEnvironment::params` |
| `INTERNAL` | ~12 | `ParameterSet::make` sites, `fhicl::Table` locals, `parse_document` |
| `TEMPLATE_PARAM` | 6 | `make_unique_maybe_default`, `SetupGeometry`, `SetupAuxDetGeometry`, `SetupReadout`, `createSorter`, `CreateNewGeometry` |
| `FHICL_TYPES_CONFIG` | 8 structs | `GeometryExtractor::Config`, `GeometryBuilderStandard::Config`, `WireReadoutGeomBuilderStandard::Config`, `OptionsFromConfig_t`, `DetectorPropertiesStandard::Configuration_t`, `LArPropertiesStandard::Configuration_t`, `ConfigWithScintByType_t`, `geo::fhicl::IDConfig<>` family |
| `ENCODE_DECODE` | 2 headers + 1 alias header | `quantities_fhicl.h`, `intervals_fhicl.h`; `geo_vectors_fhicl.h` via `TupleAs` |
| `TEST_ONLY` | ~20 files | `TestUtils/*`, `test/*`, `*TestHelpers.h` |
| `CMAKE_DEP` | 11 files | see §3 |

---

## 3. Build-system dependency map

| file | lines | nature |
|---|---|---|
| `larcorealg/CMakeLists.txt` | 29 `find_package(fhiclcpp REQUIRED EXPORT)` | transitive export to all consumers |
| `larcorealg/larcorealg/Geometry/CMakeLists.txt` | 5 (`AuxDetGeoObjectSorter`), 77 (`StandaloneBasicSetup`), 94–99 (`geo_vectors_fhicl`), 104 (`geoVectorUtils`), 155–156 (main `Geometry`, **PUBLIC**), 176 `install_fhicl` | line 5 is a **false dependency** — `AuxDetGeoObjectSorter.h` has no fhicl content |
| `larcorealg/larcorealg/TestUtils/CMakeLists.txt` | 18–19 | `unit_test_base` needs both `fhiclcpp::types` and `fhiclcpp::fhiclcpp` (Table validation *and* the parser) |
| `larcorealg/test/CMakeLists.txt` | 5 | redundant `find_package` |
| `larcorealg/test/Geometry/CMakeLists.txt` | 96, 191 | only `geometry_loader_test` links fhiclcpp directly |
| `larcoreobj/CMakeLists.txt` | 27 | — |
| `larcoreobj/.../SimpleTypesAndConstants/CMakeLists.txt` | 9–13 (`geo_types_fhicl`), 16–20 (`readout_types_fhicl`) | both `INTERFACE`, both link only `fhiclcpp::types` |
| `larcoreobj/test/SimpleTypesAndConstants/CMakeLists.txt` | 18–28 | tests need `fhiclcpp::fhiclcpp` too, for `ParameterSet` |
| `lardataalg/CMakeLists.txt` | 28 | — |
| `lardataalg/lardataalg/DetectorInfo/CMakeLists.txt` | 15–16 **PUBLIC**, 34 (`DetectorInfo_TestHelpers`), 38 `install_fhicl` | — |
| `lardataalg/lardataalg/Utilities/CMakeLists.txt` | 4, 8, 15 | `intervals_fhicl.h`, `quantities_fhicl.h` as sources |

The critical observation: **`larcorealg::Geometry` and `lardataalg::DetectorInfo` both export
`fhiclcpp` PUBLIC.** Removing fhicl from these targets is an API-visible change for every
downstream LArSoft package, not an internal refactor. That is precisely the dependency the
exercise intends to break, but it means the interface repositories must re-supply it.

---

## 4. What is already plain

Worth stating explicitly, because it changes the effort estimate: the four
`FHICL_TYPES_CONFIG` structs in the "hard" classes are already single-level aggregates of
scalars, strings and vectors. Converting e.g.

```cpp
fhicl::Atom<double> Temperature{Name("Temperature"), Comment("argon temperature [K]")};
```

to

```cpp
double Temperature;
```

is a purely local, provably correct edit. The `Name`/`Comment`/default metadata that is
lost does not disappear — it moves into the interface layer's extractor, which is the only
place that still needs to know about FHiCL key spelling and documentation strings.

Of the 23 `DetectorPropertiesStandard` parameters, 22 are plain scalars or one
`std::vector<double>`. Of the 42 `LArPropertiesStandard` parameters, 40 are plain; two are
`std::vector<std::vector<double>>`.

---

## 5. Dead and removable code found during the analysis

Not required by the refactor, but it shrinks the surface and should be decided before
automation runs, since a tool will otherwise faithfully convert dead code.

| item | file | status |
|---|---|---|
| `#if 0` legacy `Configure` | `LArPropertiesStandard.cxx:32–90` | dead, ~40 raw `get<>` calls |
| `#if DETECTORINFO_..._HASOPTIONALATOM` branch | `LArPropertiesStandard.{h,cxx}` | flag is `0`; includes the only `fhicl::detail::fillMissingKeysMsg` / `validationException` use |
| `SetupMessageFacility(pset, ...)` | `StandaloneBasicSetup.h:108` | body is `(void)pset;` — signature kept only "for callers during the migration" |
| `SetupMessageFacility` pset block | `unit_test_base.h:1089–1115` | reads `services.message`, prints it, then `(void)logging_pset;` |
| unused `#include "fhiclcpp/ParameterSet.h"` | 6 test files in `larcorealg/test/Geometry` | no fhicl symbol in the TU |
| unused `#include "fhiclcpp/types/Table.h"` | `GeometryCore.cxx:25` | `fhicl::Table` never appears |
| unused `#include "fhiclcpp/types/Atom.h"` | `WireReadoutGeomBuilderStandard.h:12` | no `fhicl::Atom` in the header |
| unused `#include "fhiclcpp/types/OptionalAtom.h"` | `geo_types_fhicl.h:18` | `OptionalAtom` never used |
| `fhiclcpp::fhiclcpp` link | `Geometry/CMakeLists.txt:5` | `AuxDetGeoObjectSorter.h` has no fhicl content |
| documented-but-unread keys | `"ROOT"`, `"DisableWiresInG4"` (`StandaloneGeometrySetup.h` docs); `"CheckForOverlaps"`, `"PrintWires"` (`GeometryTestAlg.h` docs); `"InheritClockConfig"` (`DetectorClocksStandard.h` docs) | documented, never read in this tree |
| key-name bug | `geometry_loader_test.cxx:83` reads `"services.WireGeom"` while the `.fcl` and `geometry_test.cxx` use `"services.WireReadout"` | always falls through to `{}` |

---

## 6. Edge cases requiring design decisions

### 6.1 Degenerate pset constructors are load-bearing

`GeoObjectSorterStandard`, `AuxDetGeoObjectSorterStandard` and `WireReadoutSorterStandard`
each have `explicit X(fhicl::ParameterSet const&) {}` — empty body, unnamed parameter, zero
keys. They look deletable. They are not: two generic dispatchers select on them.

```cpp
// StandaloneGeometrySetup.h
template <typename T>
auto make_unique_maybe_default(fhicl::ParameterSet const& pset) {
  if (pset.is_empty()) {
    if constexpr (std::is_constructible_v<T>) { return std::make_unique<T>(); }
  }
  return std::make_unique<T>(pset);          // requires the pset ctor to exist
}

// geometry_unit_test_base.h
template <typename ObjectSorter>
auto createSorter(fhicl::ParameterSet const& pset [[maybe_unused]]) {
  if constexpr (std::is_constructible_v<ObjectSorter>) { ... }
  else if constexpr (std::is_constructible_v<ObjectSorter, fhicl::ParameterSet>) { ... }
  // no else branch
}
```

Note the two have **inverted priority**: `make_unique_maybe_default` prefers the pset ctor
unless the pset is empty at *runtime*; `createSorter` prefers the default ctor at *compile
time*. After the refactor, `std::is_constructible_v<T, fhicl::ParameterSet>` can never be
true in `srcs`, so both dispatchers silently change behaviour — `createSorter` would fall
off the end and return `void`. This must be redesigned, not translated.

### 6.2 Nested parameter sets form a tree

```
Geometry pset
├── RelativePath, GDML, SurfaceY, PositionEpsilon, Name   → GeometryCore
├── Builder: { maxDepth, opDetGeoName }                   → GeometryBuilderStandard
└── SortingParameters: { ... }                            → GeoObjectSorterStandard
```

`"Builder"` is read in three independent places (`AuxDetGeometryCore` ctor,
`WireReadoutStandardGeom` ctor, `GeometryFor`), `"SortingParameters"` in four. The plain
structs must nest identically, and the interface layer's extractor for the parent must call
the child's extractor. This is what makes the interface layer compositional.

### 6.3 A stored ParameterSet validated much later

`AuxDetGeometryCore` keeps `fhicl::ParameterSet fBuilderParameters` from construction and
only validates it in `LoadGeometryFile()`:

```cpp
GeometryBuilderStandard builder(
  fhicl::Table<GeometryBuilderStandard::Config>(fBuilderParameters, {"tool_type"}));
```

Two separate problems. First, the deferral itself: with a plain struct the extraction must
happen at the interface boundary, so configuration errors that previously surfaced during
`LoadGeometryFile()` now surface earlier. That is an improvement but it is a behaviour
change. Second, the hand-rolled ignorable-key set `{"tool_type"}` — note that
`WireReadoutGeomBuilderStandard`'s pset constructor does **not** pass it, and
`GeometryFor` does not either, so the same nested pset is validated with three different
tolerance policies depending on the path taken. `lar::IgnorableProviderConfigKeys()` is
documented in `ProviderUtil.h` but never actually called in `larcorealg`.

### 6.4 Conditionally required parameters

Three distinct mechanisms, none of which survives a naive translation:

- **Geometry-conditional** — `DetectorPropertiesStandard`'s five `TimeOffset*`: required iff
  the detector has the corresponding `geo::View_t`. Decided by `CheckTimeOffsets` *after*
  validation, throwing `cet::exception` on mismatch.
- **Sibling-conditional** — `LArPropertiesStandard`'s 12 per-particle yields: required iff
  `ScintByParticleType` is true. Implemented by pre-reading that one key, then mutating the
  ignorable set.
- **Self-conditional** — `geo::fhicl::IDConfig<>`'s index atoms: required iff `isValid` is
  true, via the fhicl `std::function<bool()>` "use-if" constructor.

In a plain struct, "optional" is naturally `std::optional<T>`, and the conditional logic has
to live somewhere explicit. §4 of RECOMMENDATIONS.md proposes putting the *presence* in the
struct and the *policy* in the interface layer.

### 6.5 Validation-shaped APIs with no plain analogue

`DetectorClocksStandard::IsRightConfig(fhicl::ParameterSet const&)` answers "does this pset
have the right shape?" using `has_key`. Once the target takes a fully-populated plain
struct, the question is vacuous — a struct always has all its members. This function must
either move to the interface layer (where a pset still exists) or be deleted.

Similarly `fhicl::Table::print_allowed_configuration()`, used by the test harnesses to dump
the expected schema, has no plain-struct equivalent unless the interface layer provides one.

### 6.6 Runtime-computed key paths

`unit_test_base.h` builds keys at runtime: `"services." + service_name`,
`"physics.analyzers." + test_name`, both overridable through a `std::map`. Nothing can be
statically generated for these. The whole fixture is a *generic* pset navigator, not a
configured target, so it belongs on the interface side of the boundary.

### 6.7 Namespaces literally named `fhicl`

`lar::fhicl::geo` (in `geo_vectors_fhicl.h`) and `geo::fhicl` / `readout::fhicl` (in the
`larcoreobj` headers). Inside them, unqualified `fhicl::` resolves to the *inner* namespace,
so every reference to real fhiclcpp is written `::fhicl::`. Any mechanical rewrite that
manipulates `fhicl::` tokens will corrupt these files unless it is namespace-aware. This is
the single most likely place for an automated tool to do silent damage.

### 6.8 Member name ≠ key name

Four known cases: `SimpleBoundary` ↔ `"SimpleBoundaryProcess"`, `MeanExcitationEnergy` ↔
`"ExcitationEnergy"`, `ExtraMatProperties` ↔ `"LoadExtraMatProperties"`, and in a test,
member `TPC` ↔ key `"TPCset"`. A generator must take the key from `fhicl::Name(...)`, never
from the member identifier.

### 6.9 String-based encode/decode round trip

`quantities_fhicl.h` / `intervals_fhicl.h` convert through `std::string`:
`decode` does `::fhicl::detail::decode(src, s)` then `util::makeQuantity<T>(s)`. Since the
plain struct will hold a real `util::quantities::microsecond`, the interface layer needs the
same string parse, but it can call `util::makeQuantity` directly and never touch
`fhicl::detail`. The dependency is removable rather than relocatable, which is a better
outcome than for `geo_types_fhicl.h`.

### 6.10 Two-phase construction

`LArPropertiesStandard` has a default constructor plus a separate public
`bool Configure(pset, ignore_params)` that can be called later, with `fIsConfigured`
tracking state. The plain-struct target needs a decision: keep `Configure(Config const&)`,
or collapse to constructor-only. Keeping it is lower-risk, since external callers may rely
on the two-phase form.

### 6.11 Unconstrained perfect forwarding

`testing::setupProvider<Prov>(Args&&...)` and `ProviderList::setup<T>(Args&&...)` have **no
fhicl include at all** — the coupling exists only in documentation and in what callers
happen to pass. A grep-based tool will not find these. They will break at instantiation
time, in the test build, with template error messages far from the cause.

---

## 7. Proposed repository split

Derived from the analysis above; the rationale is in RECOMMENDATIONS.md §2.

| srcs repo | interface repo | needed? | contents |
|---|---|---|---|
| `larcorealg` | `larcorealg-interface` | **yes** | extractors for `GeometryCore`, `AuxDetGeometryCore`, `WireReadoutStandardGeom`, the three sorters, the two builders, `GeometryTestAlg`; relocated `geo_vectors_fhicl.h`; the `lar::standalone` pset entry points |
| `larcoreobj` | `larcoreobj-interface` | **yes** | relocated `geo_types_fhicl.h` and `readout_types_fhicl.h` in their entirety, plus their two tests |
| `lardataalg` | `lardataalg-interface` | **yes** | extractors for `DetectorClocksStandard`, `DetectorPropertiesStandard`, `LArPropertiesStandard`; relocated `quantities_fhicl.h` and `intervals_fhicl.h`; the three `*TestHelpers.h` |
| `lardataobj` | — | **no** | no fhicl dependency exists |

---

## 8. Effort ranking

| tier | items | why |
|---|---|---|
| 1 — mechanical | `GeometryExtractor`, `GeometryBuilderStandard`, `WireReadoutGeomBuilderStandard`, `DetectorPropertiesStandard`, `LArPropertiesStandard` | `fhicl::Table<Config>` already isolates the schema; strip wrappers, move metadata |
| 2 — mechanical with care | `DetectorClocksStandard`, `GeometryCore`, `GeometryTestAlg`, `maybe_default_detector_name` | raw `get<>` in member-init lists; order of evaluation and defaults must be preserved exactly |
| 3 — structural | `AuxDetGeometryCore` (stored pset), `WireReadoutStandardGeom` + `GeometryFor` (nested `"Builder"`), the three degenerate sorters | nesting, deferral and SFINAE |
| 4 — relocate wholesale | `geo_types_fhicl.h`, `readout_types_fhicl.h`, `quantities_fhicl.h`, `intervals_fhicl.h`, `geo_vectors_fhicl.h` | move, do not convert |
| 5 — redesign | `unit_test_base.h`, `geometry_unit_test_base.h`, `ProviderTestHelpers.h`, `ProviderList.h`, the three `*TestHelpers.h` | runtime key paths, pset-as-trait, invisible coupling |

Tiers 1–2 are roughly 60% of the occurrence count and close to 0% of the risk. Tier 5 is a
handful of files and most of the risk.
