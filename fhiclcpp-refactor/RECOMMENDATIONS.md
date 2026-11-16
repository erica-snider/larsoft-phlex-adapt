# Refactoring recommendations

Companion to `ANALYSIS.md`. This document recommends how to carry out the refactor:
struct design conventions, interface layer structure, naming conventions, and the patterns
and edge cases that need special handling.

Nothing here has been applied to any code.

---

## 1. Principles

**P1 — The plain struct is the contract; the interface layer is replaceable.**
The struct in `srcs` is what the target class promises to need. The extractor in the
interface repo is one way to satisfy that promise from FHiCL. A Phlex-native configuration
source should be able to populate the same struct without touching `srcs`. If a design
choice makes the struct depend on how FHiCL happens to work, it is the wrong choice.

**P2 — Push knowledge of FHiCL *up*, never down.**
After the refactor, `srcs` must not know key spellings, defaults, validation policy,
ignorable-key sets, or documentation strings. All of that is FHiCL's business and belongs
in the interface repo. This has a consequence worth stating plainly: default values move
out of `srcs`. §3.4 addresses the objection.

**P3 — Preserve observable behaviour exactly, including failure behaviour.**
A missing required key must still throw, with a message a user can act on. A default must
still produce the same value. Evaluation order in member-init lists must not change in a
way that alters results. The refactor is not an opportunity to fix the key-name bug in
`geometry_loader_test.cxx` or the inconsistent ignorable-key policies — note them, fix them
separately.

**P4 — Prefer deletion to translation.**
A meaningful fraction of the fhicl surface is dead (`ANALYSIS.md` §5). Translating dead code
produces dead code in two repositories instead of one. Decide what to delete *before*
automating, not after.

**P5 — Move, do not convert, the producer headers.**
`geo_types_fhicl.h`, `readout_types_fhicl.h`, `quantities_fhicl.h`, `intervals_fhicl.h`,
`geo_vectors_fhicl.h` have no configuration to extract. They are FHiCL vocabulary. They
relocate to the interface repos essentially unchanged.

---

## 2. Interface layer structure

### 2.1 Repository naming and layout

Per the stated requirement, interface repositories are named by appending `-interface`, and
mirror the directory structure of the repository they interface with.

```
srcs/larcorealg/larcorealg/Geometry/GeometryCore.h
srcs/larcorealg-interface/larcorealg-interface/Geometry/GeometryCoreInterface.h
```

Full proposed layout for `larcorealg-interface`:

```
larcorealg-interface/
├── CMakeLists.txt
├── CMakePresets.json
├── ups/product_deps
├── larcorealg-interface/
│   ├── CMakeLists.txt
│   ├── Geometry/
│   │   ├── CMakeLists.txt
│   │   ├── GeometryCoreInterface.h
│   │   ├── GeometryCoreInterface.cxx
│   │   ├── AuxDetGeometryCoreInterface.{h,cxx}
│   │   ├── GeometryBuilderStandardInterface.{h,cxx}
│   │   ├── WireReadoutGeomBuilderStandardInterface.{h,cxx}
│   │   ├── WireReadoutStandardGeomInterface.{h,cxx}
│   │   ├── GeoObjectSorterStandardInterface.{h,cxx}
│   │   ├── AuxDetGeoObjectSorterStandardInterface.{h,cxx}
│   │   ├── WireReadoutSorterStandardInterface.{h,cxx}
│   │   ├── StandaloneGeometrySetupInterface.{h,cxx}
│   │   ├── geo_vectors_fhicl.h            # relocated unchanged
│   │   └── details/
│   │       └── maybe_default_detector_nameInterface.{h,cxx}
│   ├── TestUtils/
│   │   └── ...                            # see §6
│   └── Support/
│       ├── FhiclExtract.h                 # shared helpers, §2.4
│       └── ExtractionError.h
└── test/
    └── Geometry/
        └── ...                            # round-trip tests, §7
```

`larcoreobj-interface` and `lardataalg-interface` follow the same shape.
**No `lardataobj-interface`** — `lardataobj` has no fhicl dependency.

### 2.2 Dependency direction

```
  framework (art / Phlex)
          │  supplies fhicl::ParameterSet
          ▼
  *-interface              ──link──▶  fhiclcpp
          │  supplies T::Config
          ▼
  srcs                     ──────────  no fhiclcpp
```

Strictly one-directional. `srcs` must never link `fhiclcpp` after the refactor; the
interface repo links both `fhiclcpp` and its `srcs` counterpart. Interface repos may depend
on each other (`larcorealg-interface` needs `larcoreobj-interface` for the geometry ID
vocabulary), mirroring the `srcs` dependency graph.

The CMake change in `srcs` is the real proof of completion: when
`find_package(fhiclcpp REQUIRED EXPORT)` is gone from `larcorealg/CMakeLists.txt` and the
package still builds, the dependency is genuinely broken. Anything short of that is
cosmetic. Note from `ANALYSIS.md` §3 that `larcorealg::Geometry` and
`lardataalg::DetectorInfo` currently export fhiclcpp **PUBLIC**, so this is an API-visible
change for downstream packages, which must now link the interface libraries instead.

### 2.3 One extractor per target

Recommended shape, using `GeometryCore` as the worked example.

In `srcs` — `larcorealg/larcorealg/Geometry/GeometryCore.h`:

```cpp
// No fhicl include. No fhicl forward declaration.
#include <string>

namespace geo {
  class GeometryCore {
  public:
    struct Config {
      std::string relativePath{};
      std::string gdmlFile{};
      std::string detectorName{};          // see §3.5
      double      surfaceY{};
      double      positionEpsilon{1.e-4};  // see §3.4
    };

    GeometryCore(Config const& config,
                 std::unique_ptr<GeometryBuilder> builder,
                 std::unique_ptr<GeoObjectSorter> sorter);
    ...
  };
}
```

In `larcorealg-interface` — `Geometry/GeometryCoreInterface.h`:

```cpp
#include "larcorealg/Geometry/GeometryCore.h"
#include "fhiclcpp/fwd.h"

namespace lar::interface {
  /// Extracts geo::GeometryCore::Config from a FHiCL parameter set.
  geo::GeometryCore::Config extractGeometryCoreConfig(fhicl::ParameterSet const& pset);

  /// Convenience: extract and construct.
  std::unique_ptr<geo::GeometryCore> makeGeometryCore(
    fhicl::ParameterSet const& pset,
    std::unique_ptr<geo::GeometryBuilder> builder,
    std::unique_ptr<geo::GeoObjectSorter> sorter);
}
```

and `.cxx`:

```cpp
geo::GeometryCore::Config
lar::interface::extractGeometryCoreConfig(fhicl::ParameterSet const& pset)
{
  geo::GeometryCore::Config cfg;
  cfg.relativePath    = pset.get<std::string>("RelativePath", "");
  cfg.gdmlFile        = pset.get<std::string>("GDML");            // required
  cfg.surfaceY        = pset.get<double>("SurfaceY");             // required
  cfg.positionEpsilon = pset.get<double>("PositionEpsilon", 1.e-4);
  cfg.detectorName    = ...;                                      // §3.5
  return cfg;
}
```

Two functions per target: a pure `extract*Config` and an optional `make*` convenience
wrapper. Keeping them separate matters — callers that need to adjust the config between
extraction and construction (the test helpers do exactly this) can, and `extract*Config` is
trivially unit-testable without constructing the target.

### 2.4 Shared extraction helpers

Put these in `*-interface/Support/FhiclExtract.h` rather than repeating them:

```cpp
namespace lar::interface::detail {

  // Required key, with a message naming the target and key.
  template <typename T>
  T require(fhicl::ParameterSet const& pset, std::string const& key,
            std::string const& targetName);

  // Optional key → std::optional<T>, for genuinely absent-vs-present semantics.
  template <typename T>
  std::optional<T> optional(fhicl::ParameterSet const& pset, std::string const& key);

  // Reject unknown keys, replacing fhicl::Table's validation. See §5.2.
  void rejectUnknownKeys(fhicl::ParameterSet const& pset,
                         std::set<std::string> const& known,
                         std::set<std::string> const& ignorable,
                         std::string const& targetName);
}
```

`rejectUnknownKeys` is the one genuinely new piece of machinery. The classes that currently
use `fhicl::Table<Config>` get typo detection for free; a hand-written extractor using only
`pset.get<>` silently ignores a misspelled key. Dropping that is a real regression, and it
is the kind of regression that shows up as a physics bug months later. §5.2 expands.

### 2.5 Namespace

Use a distinct namespace for interface code — `lar::interface`, or per-package
`geo::interface` / `detinfo::interface`. Do **not** reuse the target's namespace: identical
names in the same namespace across two repositories invite ODR confusion and make it hard to
see, at a call site, which side of the boundary you are on.

Avoid any namespace component literally named `fhicl` in new code. `ANALYSIS.md` §6.7
documents what that already costs in the existing headers.

---

## 3. Config struct design conventions

### 3.1 Placement and naming

- Nested inside the target class: `geo::GeometryCore::Config`.
- For a free function, a struct in the same namespace named after the function:
  `geo::details::MaybeDefaultDetectorNameConfig`.
- Name it `Config` uniformly. `DetectorPropertiesStandard` and `LArPropertiesStandard`
  already use `Configuration_t`; keep those names to avoid churn in external code, and
  add `using Config = Configuration_t;`. Consistency of the *concept* matters more than
  uniformity of the spelling when the spelling is already public API.
- Public. The interface layer must see it, and it is part of the target's contract.

### 3.2 Member naming

Keep the existing C++ member identifier from the `fhicl::Atom` where one exists —
`Temperature`, `Efield`, `SternheimerA`. These are already public API through
`Configuration_t`, and renaming them creates downstream churn for no benefit.

For structs generated from raw `pset.get<>` sites, use lowerCamelCase derived from the key
(`"RelativePath"` → `relativePath`) but **always record the key explicitly** in the
extractor. Never reconstruct a key from a member name: `ANALYSIS.md` §6.8 lists four cases
where they differ.

### 3.3 Types

| FHiCL form | struct member |
|---|---|
| `fhicl::Atom<T>` required | `T` |
| `fhicl::Atom<T>` with default | `T` with a brace-initializer (§3.4) |
| `fhicl::OptionalAtom<T>` | `std::optional<T>` |
| `fhicl::Sequence<T>` | `std::vector<T>` |
| `fhicl::Sequence<fhicl::Sequence<T>>` | `std::vector<std::vector<T>>` |
| `fhicl::Table<SubConfig>` | the nested plain `SubConfig` by value |
| `fhicl::OptionalTable<SubConfig>` | `std::optional<SubConfig>` |
| `fhicl::TableFragment<SubConfig>` | the nested plain `SubConfig` by value (§3.6) |
| `fhicl::Sequence<fhicl::Table<SubConfig>>` | `std::vector<SubConfig>` |
| nested `fhicl::ParameterSet` key | the nested plain `Config` of the class that consumes it |

The struct should be an aggregate: no user-declared constructors, no private members, no
virtuals, no inheritance except where it mirrors existing config inheritance (§3.7). That
keeps designated initializers available, which makes both generated code and hand-written
tests far more readable:

```cpp
geo::GeometryCore::Config cfg{.gdmlFile = "x.gdml", .surfaceY = 200.};
```

### 3.4 Defaults

Recommendation: **put the default in the struct as a brace-initializer, and also pass it at
the extraction site.**

```cpp
// struct
double positionEpsilon{1.e-4};

// extractor
cfg.positionEpsilon = pset.get<double>("PositionEpsilon", 1.e-4);
```

This duplicates the literal, which is a real cost. It buys three things:

1. A default-constructed `Config` is immediately usable, which is what makes the struct
   independent of FHiCL (P1). A non-FHiCL configuration source does not have to know that
   `1.e-4` was the historical default.
2. The physics default lives with the code that embodies the physics, where a reviewer who
   understands the algorithm will see it.
3. Tests can construct a valid config with designated initializers for only the fields they
   care about.

Guard the duplication with a generated round-trip test (§7.2) asserting that extracting from
an empty pset yields a default-constructed struct. That converts "two literals might drift"
from a latent bug into a build failure.

Where the default is a named constant (`util::kModBoxA`), use the constant in both places and
the duplication disappears.

### 3.5 Computed and derived values

`GeometryCore`'s `fDetectorName` is not read directly; it comes from
`maybe_default_detector_name(pset, fGDMLfile)`, which returns `pset.get_if_present<std::string>("Name")`
if present and otherwise the GDML filename stem. Two options:

- **(a) Compute in the interface layer**, put the resolved `std::string detectorName` in the
  struct. The target becomes simpler and has no filesystem dependency.
- **(b) Keep the fallback in `srcs`**, put `std::optional<std::string> detectorName` in the
  struct and let `GeometryCore` apply the stem fallback.

**Prefer (b).** The fallback is a property of what a `GeometryCore` is, not of FHiCL. Under
(a), a Phlex-native caller would have to re-implement the stem logic to get the same
behaviour. The same reasoning applies to the `std::tolower` normalization the constructor
already does — that stays in `srcs`.

The general rule: the interface layer transports values; it does not compute them. The sole
exception is value *decoding* that exists only because FHiCL carries strings (§5.4).

### 3.6 `TableFragment` flattens

`fhicl::TableFragment<GeometryExtractor::Config> extractor;` splices the child's keys into
the *parent's* key namespace — `"maxDepth"` sits at the top level of the Builder pset, not
under `extractor.maxDepth`. The plain struct should still nest:

```cpp
struct Config {
  GeometryExtractor::Config extractor{};
  std::string opDetGeoName{"volOpDetSensitive"};
};
```

and the extractor reads the child's keys from the *same* pset level:

```cpp
cfg.extractor     = extractGeometryExtractorConfig(pset);   // reads "maxDepth" here
cfg.opDetGeoName  = pset.get<std::string>("opDetGeoName", "volOpDetSensitive");
```

This is a place where a generator will get it wrong if it assumes nesting in the struct
implies nesting in the pset. `TableFragment` must be special-cased explicitly.

### 3.7 Config inheritance

`ConfigWithScintByType_t : Configuration_t` and the `geo::fhicl::IDConfig<>` chain both use
inheritance. Where it mirrors a real type hierarchy (the ID configs mirror the ID types),
keep it. Where it encodes a schema *variant* (`ConfigWithScintByType_t`), prefer composition
in the plain struct — see §4.2.

---

## 4. Patterns requiring special handling

### 4.1 Nested parameter sets → nested structs

```cpp
struct GeometryCore::Config { ... };

struct StandaloneGeometryConfig {          // lar::standalone
  geo::GeometryCore::Config            geometry{};
  geo::GeometryBuilderStandard::Config builder{};
  SortingConfig                        sorting{};
};
```

The extractor composes:

```cpp
cfg.geometry = extractGeometryCoreConfig(pset);
cfg.builder  = extractGeometryBuilderStandardConfig(
                 pset.get<fhicl::ParameterSet>("Builder", {}));
cfg.sorting  = extractSortingConfig(
                 pset.get<fhicl::ParameterSet>("SortingParameters", {}));
```

Note `"Builder"` is read at three independent sites and `"SortingParameters"` at four
(`ANALYSIS.md` §6.2). Define each child extractor **once** and call it from all sites. Do not
let a generator emit four copies of the sorting extraction — that is how the three different
ignorable-key policies in §4.5 came about in the first place.

### 4.2 Schema variants → always-present members

`LArPropertiesStandard` currently switches schema at runtime: it pre-reads
`ScintByParticleType`, and if false, adds the 12 per-particle keys to the ignorable set so
validation tolerates their absence.

In the plain struct, make the variant explicit and always present:

```cpp
struct ScintByParticleYields {
  double ProtonScintYield{};
  double ProtonScintYieldRatio{};
  // ... 12 total
};

struct Configuration_t {
  bool ScintByParticleType{false};
  std::optional<ScintByParticleYields> scintByParticle{};   // engaged iff the above
  ...
};
```

The invariant "`scintByParticle` is engaged iff `ScintByParticleType`" is now checkable in
one place, in `srcs`, rather than being an emergent property of an ignorable-key set. The
extractor reads `ScintByParticleType` first and only then populates the optional — the same
order the current code uses.

### 4.3 Conditionally required parameters

Three mechanisms (`ANALYSIS.md` §6.4). Uniform recommendation: **the struct carries presence,
the layer that owns the policy enforces the requirement.**

For `DetectorPropertiesStandard`'s `TimeOffset*`, the policy depends on the *geometry*, which
the interface layer does not have. So:

```cpp
struct Configuration_t {
  std::optional<double> TimeOffsetU{};
  std::optional<double> TimeOffsetV{};
  std::optional<double> TimeOffsetZ{};
  std::optional<double> TimeOffsetY{};
  std::optional<double> TimeOffsetX{};
  ...
};
```

The extractor fills whichever are present. `DetectorPropertiesStandard`'s constructor keeps
`CheckTimeOffsets` exactly as it is and throws the same `cet::exception` — it already has the
`WireReadoutGeom`. Behaviour is preserved and the policy stays where the information is.

For `LArPropertiesStandard`, the policy is sibling-conditional and the interface layer *does*
have the information, so it can enforce it during extraction. Either placement is defensible;
prefer `srcs` for consistency with the rule above.

### 4.4 Degenerate pset constructors and SFINAE dispatch

This is the one case where a mechanical translation is actively wrong.
`GeoObjectSorterStandard`, `AuxDetGeoObjectSorterStandard` and `WireReadoutSorterStandard`
take a pset and ignore it. Translating to `explicit X(Config const&)` with an empty `Config`
keeps them compiling but **silently breaks both dispatchers** that select on
`std::is_constructible_v<T, fhicl::ParameterSet>`, because that trait becomes false
everywhere. `createSorter` in particular has no `else` branch and would fall off the end.

Recommendation: **replace trait-based dispatch with an explicit factory customization point.**

```cpp
// in srcs, next to each sorter
namespace geo {
  template <typename Sorter> struct SorterConfigOf;                  // primary, undefined
  template <> struct SorterConfigOf<GeoObjectSorterStandard> {
    using type = GeoObjectSorterStandard::Config;
  };
}
```

and in the interface layer:

```cpp
template <typename Sorter>
std::unique_ptr<Sorter> makeSorter(fhicl::ParameterSet const& pset)
{
  using Config = typename geo::SorterConfigOf<Sorter>::type;
  return std::make_unique<Sorter>(extractConfig<Config>(pset));
}
```

A sorter that has no configuration gets an empty `Config{}`, which is honest, and the
primary template being undefined turns "unsupported sorter type" into a clear compile error
rather than a silent `void` return. This also removes the inverted-priority discrepancy
between `make_unique_maybe_default` and `createSorter` noted in `ANALYSIS.md` §6.1.

The `pset.is_empty()` runtime check in `make_unique_maybe_default` disappears: with a config
struct, "empty pset" and "all-defaults config" are the same thing, which is what the code
was approximating anyway.

### 4.5 Stored parameter sets and deferred validation

`AuxDetGeometryCore` stores `fhicl::ParameterSet fBuilderParameters` and validates it later
in `LoadGeometryFile()`. Recommendation: **extract eagerly at the boundary, store the plain
struct.**

```cpp
// srcs
class AuxDetGeometryCore {
  struct Config {
    std::string relativePath{};
    std::string gdmlFile{};
    std::optional<std::string> detectorName{};
    GeometryBuilderStandard::Config builder{};   // was a stored ParameterSet
    bool throwIfAbsent{true};
  };
  ...
  GeometryBuilderStandard::Config fBuilderConfig;   // replaces fBuilderParameters
};
```

Two consequences to accept deliberately:

- **Errors move earlier.** A malformed `Builder` block previously surfaced during
  `LoadGeometryFile()`; now it surfaces at extraction. This is better, but it is a
  user-visible change in *when* the failure occurs and should be in the release note.
- **The `{"tool_type"}` ignorable set needs a decision.** `AuxDetGeometryCore` passes it;
  `WireReadoutGeomBuilderStandard`'s pset ctor and `GeometryFor` do not — so today the same
  nested pset is validated under three different tolerance policies depending on the path.
  Unify on one policy in the single shared `Builder` extractor. The permissive choice
  (tolerate `tool_type`) preserves the most existing behaviour; record the decision
  explicitly rather than letting it be implicit in which call path runs.

While unifying, fold in `lar::IgnorableProviderConfigKeys()` (`"service_type"`,
`"service_provider"`), which is documented in `ProviderUtil.h` but never actually called in
`larcorealg`. `ProviderUtil.h` itself has no fhicl include and can stay in `srcs`, though its
only purpose is now served by the interface layer — consider moving it.

### 4.6 Producer headers: relocate, do not convert

| header | destination | change |
|---|---|---|
| `larcoreobj/.../geo_types_fhicl.h` | `larcoreobj-interface/.../SimpleTypesAndConstants/` | path-only; keep `geo::fhicl` namespace |
| `larcoreobj/.../readout_types_fhicl.h` | same | path-only |
| `lardataalg/Utilities/quantities_fhicl.h` | `lardataalg-interface/.../Utilities/` | path-only |
| `lardataalg/Utilities/intervals_fhicl.h` | same | path-only |
| `larcorealg/Geometry/geo_vectors_fhicl.h` | `larcorealg-interface/.../Geometry/` | path-only |

Move their tests with them. Move the corresponding `cet_make_library(... INTERFACE)` targets
and their `fhiclcpp::types` links. `larcoreobj` then has **zero** fhicl dependency, same as
`lardataobj` — which is the right end state for an `obj` package.

Do **not** attempt to rewrite the `geo::fhicl` namespace during the move
(`ANALYSIS.md` §6.7): inside it, `::fhicl::` qualification is load-bearing. A path change is
safe; a namespace change is not.

### 4.7 Encode/decode: remove rather than relocate

`quantities_fhicl.h` / `intervals_fhicl.h` round-trip through `std::string`:
`::fhicl::detail::decode(src, s)` then `util::makeQuantity<T>(s)`. Since the plain struct
holds a real `util::quantities::microsecond`, an extractor can do:

```cpp
cfg.readoutWindow =
  util::makeQuantity<util::quantities::microsecond>(pset.get<std::string>("ReadoutWindow"));
```

and never touch `fhicl::detail`. Keep the headers in the interface repo for the benefit of
external code that uses `fhicl::Atom<microsecond>` directly, but new interface code should
call `util::makeQuantity` and `util::to_string` directly. `util::` has no fhicl dependency,
so this removes a dependency rather than relocating one — a strictly better outcome than
§4.6 achieves for the geo ID headers.

### 4.8 Validation-shaped APIs

`DetectorClocksStandard::IsRightConfig(fhicl::ParameterSet const&)` asks whether a pset has
the right shape. With a fully-populated plain struct the question is vacuous. Move it to
`lardataalg-interface` as a free function on `fhicl::ParameterSet` — it is pure FHiCL shape
inspection and has no business in `srcs`. Its "`module_label` must be absent" check is
framework-specific, which confirms the placement.

`fhicl::Table::print_allowed_configuration()` is used by the test harnesses to dump the
expected schema. If that output is still wanted, the interface layer must provide it,
because a plain struct has no reflection. Options: keep a parallel `fhicl::Table<Config>`
purely for documentation, or generate a static schema description alongside each extractor.
Prefer the latter — a parallel Table reintroduces exactly the duplication the refactor
removes. This is also what feeds the typo detection in §5.2, so one mechanism serves both.

---

## 5. What is lost, and what to do about it

Being explicit about regressions is more useful than claiming parity.

### 5.1 Documentation strings

`fhicl::Comment("argon temperature [K]")` currently feeds `lar --print-description`. In the
plain struct it has nowhere to live except a code comment. Recommendation: carry the comment
text into the extractor's schema description (§5.2) so `--print-description`-equivalent
output remains possible, and *also* leave it as a doxygen comment on the struct member. The
duplication is acceptable for documentation in a way it would not be for values.

### 5.2 Unknown-key rejection — the one regression that matters

`fhicl::Table<Config>` rejects unknown keys. A misspelled `Temperatur:` is a hard error
today. A hand-written extractor using only `pset.get<>` ignores it silently and the target
runs with a default or throws a confusing "missing required key" for a key the user believes
they set.

This must not be lost. Recommendation: every generated extractor declares its known keys and
calls `rejectUnknownKeys` first.

```cpp
namespace {
  constexpr std::array knownKeys = {
    "RelativePath", "GDML", "SurfaceY", "PositionEpsilon", "Name"
  };
}

geo::GeometryCore::Config extractGeometryCoreConfig(fhicl::ParameterSet const& pset)
{
  detail::rejectUnknownKeys(pset, knownKeys,
                            lar::IgnorableProviderConfigKeys(), "geo::GeometryCore");
  ...
}
```

The `knownKeys` array is generated from the same table that generates the reads, so it cannot
drift. It doubles as the schema description for §5.1 and §4.8.

Note this *adds* validation for the four classes that use raw `pset.get<>` today and
therefore have never rejected unknown keys. That is a behaviour change in the strict
direction, and it may surface pre-existing typos in experiment `.fcl` files. Introduce it as
a warning first, promote to an error after a cycle.

### 5.3 Conditional-presence declarations

The `[this](){ return valid(); }` use-if lambdas in `geo::fhicl::IDConfig<>` are a fhicl
feature with no plain-struct analogue. Since those headers relocate wholesale (§4.6), the
feature is retained where it is used. No action.

### 5.4 Type decoding

FHiCL decodes `16ms` → `microsecond` via the encode/decode customization points. A plain
struct holding `microsecond` needs that parse to happen somewhere. §4.7 puts it in the
extractor via `util::makeQuantity`. This is the one place where the interface layer legitimately
*transforms* rather than transports, because the transformation exists solely because FHiCL
carries strings.

---

## 6. The test harness

`TestUtils` is the hardest part of the job and the place where mechanical translation should
not be attempted. The reason is structural, not incidental: `BasicTesterEnvironment` is a
*generic FHiCL document navigator*. It holds a whole-document pset, computes keys at runtime
(`"services." + name`, `"physics.analyzers." + name`), parses FHiCL strings and files through
`fhicl::parse_document`, and dispatches provider construction on
`std::is_constructible_v<T, fhicl::ParameterSet>`. None of that is configuration *of* a
target; all of it is configuration *machinery*.

Recommendation: **move the harness to the interface side of the boundary.**

```
larcorealg-interface/larcorealg-interface/TestUtils/
├── unit_test_base.h             # relocated, keeps fhicl
├── geometry_unit_test_base.h    # relocated, keeps fhicl
├── ProviderTestHelpers.h        # relocated
└── ProviderList.h               # relocated
```

Consequences:

- `larcorealg::unit_test_base` and `larcorealg::TestUtils` CMake targets move, along with
  their `fhiclcpp::types` + `fhiclcpp::fhiclcpp` links. These are the only targets needing
  the fhicl *parser*.
- Tests in `srcs/*/test/` that use the harness now link the interface package. Acceptable:
  tests are not part of the shipped library surface, and the harness's entire purpose is to
  turn a `.fcl` file into configured providers.
- `createSorter` is replaced by the `makeSorter` factory from §4.4.
- The three `lardataalg` `*TestHelpers.h` move to `lardataalg-interface` for the same reason
  — each is a `ProviderSetupClass` specialization taking a pset.
- `ProviderTestHelpers.h` / `ProviderList.h` have **no fhicl include at all**
  (`ANALYSIS.md` §6.11); their coupling is pure perfect-forwarding. Grep will not find them.
  They must be moved by inspection, and their `Args&&...` packs will carry `Config` structs
  instead of psets afterwards.

The alternative — a parallel plain-struct harness in `srcs` — means maintaining two test
environments. Not worth it for a transitional state.

A smaller note: `unit_test_base.h` declares `struct OptionsFromConfig_t` *inside a function
body* (`ParseEnvironmentOptions`). If that is ever hoisted, hoist it into the interface
layer; it configures the test environment, not a `srcs` target.

---

## 7. Verification strategy

The prior spdlog migration in this tree established that mechanical gates beat assertions.
Reuse the pattern.

### 7.1 Gate: no fhicl in srcs

```sh
rg -n 'fhicl|fhiclcpp' srcs/<repo> --glob '!**/spdlog-migration/**'
```

must return nothing outside an explicit allowlist, and
`find_package(fhiclcpp REQUIRED EXPORT)` must be gone from the top-level `CMakeLists.txt`.
This mirrors `grep-gate.sh` from the spdlog work and is the authoritative definition of done
for a package.

### 7.2 Gate: extraction round-trip

For each converted target, generate a test asserting:

1. Extracting from a pset containing every key yields a struct with every field set to the
   expected value — one assertion per key, so a dropped key fails loudly.
2. Extracting from an empty pset yields a struct equal to a default-constructed one
   (**this is the guard against the §3.4 default duplication drifting**), or throws for each
   required key.
3. An unknown key is rejected (§5.2).
4. Where a `fhicl::Table<Config>` exists today, the old and new paths produce identical
   values for the same input, for as long as both exist.

Item 4 is the strongest available evidence and it is only available during the transition —
schedule it first, before the fhicl version is deleted.

### 7.3 Gate: behavioural equivalence

The existing `outdiff.sh` harness from the spdlog migration captures and compares test
output. Baseline **before** converting a package — the spdlog work recorded that this is
irreversible once sources change. Geometry tests are the highest-value target because
`GeometryCore` sits at the base of the dependency graph.

### 7.4 Order of work

Follow the dependency graph, converting leaves first.

1. `larcoreobj` — relocate two headers, drop the fhicl dependency entirely. Smallest, fully
   isolated, and it proves the interface-repo scaffolding end to end.
2. `larcorealg/Geometry` leaves — `GeometryExtractor`, then the two builders, then the three
   sorters (with the §4.4 factory change).
3. `larcorealg` cores — `GeometryCore`, then `AuxDetGeometryCore` (§4.5), then
   `WireReadoutStandardGeom`.
4. `larcorealg` standalone entry points — `StandaloneGeometrySetup`, `StandaloneBasicSetup`.
5. `lardataalg/DetectorInfo` — `DetectorClocksStandard`, `DetectorPropertiesStandard`,
   `LArPropertiesStandard`. Independent of 2–4 and can run in parallel.
6. `lardataalg/Utilities` — relocate the encode/decode headers.
7. Test harnesses (§6) — last, because everything else depends on them and they are the
   least mechanical.
8. CMake cleanup and the §7.1 gate, per package.

`lardataobj` does not appear. It needs nothing.

---

## 8. Decisions needed before automation

These are judgement calls that a tool cannot make, and each one changes what gets generated.
They should be answered and recorded — the spdlog migration used an `OPEN_QUESTION_ANSWERS.md`
for exactly this, and the same mechanism applies here.

| # | question | recommendation |
|---|---|---|
| 1 | Delete the dead code in `ANALYSIS.md` §5 first, or convert it? | Delete first, as a separate reviewable commit |
| 2 | Defaults in the struct, the extractor, or both? | Both, guarded by the §7.2 round-trip test |
| 3 | `std::optional<T>` or sentinel values for optional keys? | `std::optional<T>`; sentinels have caused real bugs in this codebase's history |
| 4 | Unknown-key rejection: error, warning, or omit? | Warning for one cycle, then error |
| 5 | Unify the `"Builder"` ignorable-key policy on `{"tool_type"}` or `{}`? | `{"tool_type"}` — preserves the most existing behaviour |
| 6 | Keep `LArPropertiesStandard`'s two-phase `Configure`? | Keep; external callers may depend on it |
| 7 | Move the test harness to the interface repo, or duplicate it? | Move (§6) |
| 8 | Keep `Configuration_t` naming or rename to `Config`? | Keep, add a `Config` alias |
| 9 | Should `srcs` keep `#include "fhiclcpp/fwd.h"` anywhere? | No — the §7.1 gate must be absolute |
| 10 | One interface library per package, or per directory? | Per directory, mirroring the `srcs` target granularity |
| 11 | Interface repos as separate git repos, or subdirectories? | Separate repos, matching the `-interface` naming requirement and the existing `srcs` layout |
| 12 | Are there downstream packages (`larcore`, `lardata`, `larsim`) outside this tree that consume the PUBLIC fhicl export? | Almost certainly yes — must be surveyed before the §7.1 gate is enforced |

Question 12 is the one with schedule risk. `ANALYSIS.md` §3 shows `larcorealg::Geometry` and
`lardataalg::DetectorInfo` export fhiclcpp PUBLIC, and `geo_types_fhicl.h` has *zero* in-tree
consumers — meaning its real consumers are all external. Removing the PUBLIC export breaks
them until they link the interface libraries. That coordination is outside this tree and
should be scoped before work starts, not discovered during it.
