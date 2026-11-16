# Automated refactoring workflow

How to apply the refactor described in `RECOMMENDATIONS.md` to an arbitrary repository or
source file with minimal interaction.

Nothing described here has been built or run. No code has been changed.

---

## 1. Design position

### 1.1 What should and should not be automated

The analysis found 177 `ParameterSet` tokens, but only three consumption idioms and
roughly 20 target entities. That ratio is the key planning fact: **the volume is in
repetition, the risk is in a handful of structural decisions.** A workflow that tries to
automate the decisions will be wrong in the places that matter; a workflow that automates
only the repetition is useful immediately.

| automate fully | automate with review | do not automate |
|---|---|---|
| extracting the key/type/default table from `fhicl::Atom`/`Sequence`/`OptionalAtom` declarations | generating the plain struct | the test harness (`RECOMMENDATIONS.md` §6) |
| generating the extractor body for flat key sets | editing the target's constructor | SFINAE dispatch replacement (§4.4) |
| generating `knownKeys` arrays and schema descriptions | nested-pset composition | the stored-pset deferral in `AuxDetGeometryCore` (§4.5) |
| scaffolding the interface repo and CMake | relocating producer headers | conditional-requirement policy (§4.3) |
| generating round-trip tests | CMake dependency edits | anything in a namespace named `fhicl` (§6.7) |
| the no-fhicl grep gate | | deciding what dead code to delete |

### 1.2 Why a parsed IR, not regex

Four specific hazards in this tree defeat textual rewriting:

- **`fhicl::Atom` initializers span multiple lines** with `Name(...)`, `Comment(...)` and a
  default in any arrangement, and the default may be an arbitrary C++ expression
  (`std::numeric_limits<Path_t::Depth_t>::max()`, `util::kModBoxA`).
- **Member name ≠ key name** in at least four places. The key must come from
  `fhicl::Name(...)`, never from the identifier.
- **Namespaces literally named `fhicl`** (`lar::fhicl::geo`, `geo::fhicl`) make every
  `fhicl::`-token heuristic unsafe.
- **`#if 0` and `#if DETECTORINFO_..._HASOPTIONALATOM` blocks** contain ~55 fhicl
  occurrences that must not be converted. Only a preprocessor-aware parse knows that.

Recommendation: **libclang (`clang.cindex`, Python)** over the real compile commands from
`compile_commands.json`. It gives correct preprocessing, resolved types, and accurate source
ranges for free. Regex is adequate only for the final grep gate, where false positives are
cheap.

### 1.3 Relationship to the spdlog workflow

This tree already contains a working precedent: the messagefacility→spdlog migration, driven
by `.kilo/command/spdlog-migrate.md` with procedure documents and guardrail scripts under
`spdlog-migration/`. That workflow's structure — stop-for-approval phases, a pattern catalog,
a decisions file, mechanical gates — transfers directly, and the guardrail scripts
(`gen-targets.sh`, `outdiff.sh`, `normalize.sed`, `env.sh`) are reusable as-is.

The proposal below deliberately mirrors it rather than inventing a new shape.

---

## 2. Pipeline

```
                 ┌──────────────┐
  srcs repo ───▶ │ 1. SCAN      │ ──▶ inventory.json
                 └──────────────┘
                        │
                 ┌──────────────┐
                 │ 2. CLASSIFY  │ ──▶ plan.json        (+ unresolved[] → human)
                 └──────────────┘
                        │
                 ┌──────────────┐
                 │ 3. SPEC      │ ──▶ specs/*.yaml     ◀── human reviews/edits
                 └──────────────┘
                        │
         ┌──────────────┼──────────────┬───────────────┐
         ▼              ▼              ▼               ▼
  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌────────────┐
  │ 4a. STRUCT │ │ 4b. EXTRACT│ │ 4c. REWRITE│ │ 4d. CMAKE  │
  │   (srcs)   │ │ (interface)│ │   (srcs)   │ │   (both)   │
  └────────────┘ └────────────┘ └────────────┘ └────────────┘
         └──────────────┴──────────────┴───────────────┘
                        │
                 ┌──────────────┐
                 │ 5. VERIFY    │ ──▶ gates: grep / build / round-trip / outdiff
                 └──────────────┘
                        │
                 ┌──────────────┐
                 │ 6. REPORT    │
                 └──────────────┘
```

Stages 1–3 are read-only and safe to run repeatedly. Stage 3 produces a human-editable
artifact that is the single point of control. Stages 4a–4d are generators driven entirely by
that artifact.

---

## 3. Stage 1 — SCAN

**Input:** a repo path, plus its `compile_commands.json`.
**Output:** `inventory.json`.
**Interaction:** none.

Walk the AST of every translation unit and record every entity that references a fhicl type.

```json
{
  "repo": "larcorealg",
  "scanned_at": "...",
  "entities": [
    {
      "id": "geo::GeometryCore::GeometryCore",
      "kind": "constructor",
      "file": "larcorealg/Geometry/GeometryCore.cxx",
      "line": 50,
      "decl_file": "larcorealg/Geometry/GeometryCore.h",
      "decl_line": 103,
      "role": "CTOR_ARG",
      "pset_param": {"index": 0, "name": "pset", "type": "fhicl::ParameterSet const&"},
      "reads": [
        {"key": "RelativePath", "type": "std::string", "default": "\"\"",
         "required": false, "form": "get_with_default", "line": 56},
        {"key": "GDML", "type": "std::string", "default": null,
         "required": true, "form": "get", "line": 57},
        {"key": "SurfaceY", "type": "double", "default": null,
         "required": true, "form": "get", "line": 59},
        {"key": "PositionEpsilon", "type": "double", "default": "1.e-4",
         "required": false, "form": "get_with_default", "line": 60}
      ],
      "forwards": [
        {"target": "geo::details::maybe_default_detector_name", "what": "whole_pset"}
      ],
      "nested_psets": [],
      "in_inactive_preprocessor_block": false,
      "in_namespace_named_fhicl": false
    }
  ]
}
```

Detection rules:

| pattern | how |
|---|---|
| `pset.get<T>(key)` | `CXXMemberCallExpr`, callee `fhicl::ParameterSet::get`, 1 arg → required |
| `pset.get<T>(key, dflt)` | same, 2 args → optional; capture the default's **source text**, not a value |
| `pset.get_if_present<T>(key)` | → `std::optional<T>` |
| `pset.get_if_present(key, out)` | 2-arg out-param form → optional, writes to `out` |
| `pset.has_key(key)` | presence-only; flag as `VALIDATION_ONLY` |
| `pset.get<fhicl::ParameterSet>(key, ...)` | → `nested_psets[]`, recurse |
| `fhicl::Atom<T> m{Name("k"), Comment("c"), dflt}` | field decl in a config struct; key from `Name`, **never** from `m` |
| `fhicl::OptionalAtom<T>` | → `std::optional<T>` |
| `fhicl::Sequence<T>` | → `std::vector<T>`; nested `Sequence<Sequence<T>>` → `vector<vector<T>>` |
| `fhicl::TableFragment<C>` | → nested struct, **flat key namespace** (`RECOMMENDATIONS.md` §3.6) |
| `fhicl::Table<C>{pset, ignorable}` | capture the ignorable-key set expression |
| `std::is_constructible_v<T, fhicl::ParameterSet>` | → `SFINAE_TRAIT`, always escalate |
| `encode`/`decode` with `fhicl::detail::ps_atom_t` | → `ENCODE_DECODE`, producer |
| template param of type `fhicl::ParameterSet` | → `TEMPLATE_PARAM`, escalate |
| `fhicl::ParameterSet` data member | → `STORED_PSET`, escalate |

Three flags must be set correctly or the tool will do damage:

- `in_inactive_preprocessor_block` — libclang with the real compile flags reports only
  active code, so this is naturally handled; assert it explicitly anyway, because
  `LArPropertiesStandard.cxx` has ~55 occurrences in a `#if 0`.
- `in_namespace_named_fhicl` — set when any enclosing namespace is spelled `fhicl`. Anything
  with this flag is **excluded from rewriting** and routed to relocate-only.
- `is_producer` — set for entities that *define* fhicl vocabulary rather than consume
  configuration (`encode`/`decode`, `IDConfig<>` specializations, `TupleAs` aliases).

A useful self-check: running SCAN against this tree must reproduce the counts in
`ANALYSIS.md` — 177 `ParameterSet` tokens, 51 files, 11 CMakeLists, zero in `lardataobj`.
Treat that as the scanner's acceptance test.

---

## 4. Stage 2 — CLASSIFY

**Input:** `inventory.json`.
**Output:** `plan.json` with `automated[]`, `review[]`, `manual[]`, `unresolved[]`.
**Interaction:** only if `unresolved[]` is non-empty.

Assign each entity a **pattern** from a catalog. The catalog is the heart of the workflow;
the spdlog migration's `PATTERN_CATALOG.md` is the model.

| pattern | shape | handling |
|---|---|---|
| `P1-FLAT-CTOR` | ctor reads only scalar/vector keys, no nesting, no forwarding | automated |
| `P2-FLAT-FUNC` | free/member function, same | automated |
| `P3-TABLE-CONFIG` | already `fhicl::Table<Config>`, flat | automated |
| `P4-TABLE-FRAGMENT` | config contains `TableFragment` | automated, flat-key rule |
| `P5-NESTED-PSET` | reads `get<fhicl::ParameterSet>(k)` and forwards | review |
| `P6-DEGENERATE` | pset param, zero reads | **review** — SFINAE check required |
| `P7-STORED-PSET` | pset as a data member | manual |
| `P8-CONDITIONAL` | requiredness depends on another value or external state | manual |
| `P9-SCHEMA-VARIANT` | ignorable set mutated at runtime to switch schema | manual |
| `P10-RUNTIME-KEY` | key computed at runtime | manual |
| `P11-SFINAE` | `is_constructible_v<T, fhicl::ParameterSet>` | manual |
| `P12-PRODUCER` | encode/decode, `IDConfig<>`, `TupleAs` | relocate-only |
| `P13-VALIDATION-ONLY` | `has_key` shape check, no value extraction | review — likely moves or deletes |
| `P14-DEAD-INCLUDE` | fhicl include, no fhicl symbol | automated (delete the include) |
| `P15-UNCONSTRAINED-FORWARD` | `Args&&...` documented as pset, no fhicl include | manual, **not greppable** |

Classification against this tree yields roughly:

| pattern | entities |
|---|---|
| `P1-FLAT-CTOR` | `DetectorClocksStandard`, `GeometryTestAlg` |
| `P2-FLAT-FUNC` | `maybe_default_detector_name` |
| `P3-TABLE-CONFIG` | `GeometryExtractor`, `DetectorPropertiesStandard` |
| `P4-TABLE-FRAGMENT` | `GeometryBuilderStandard`, `WireReadoutGeomBuilderStandard` |
| `P5-NESTED-PSET` | `GeometryCore`, `WireReadoutStandardGeom`, `GeometryFor`, `SetupGeometry`/`SetupAuxDetGeometry`/`SetupReadout` |
| `P6-DEGENERATE` | the three `*SorterStandard` classes |
| `P7-STORED-PSET` | `AuxDetGeometryCore` |
| `P8-CONDITIONAL` | `DetectorPropertiesStandard::TimeOffset*` |
| `P9-SCHEMA-VARIANT` | `LArPropertiesStandard` |
| `P10-RUNTIME-KEY` | `unit_test_base.h`, `geometry_unit_test_base.h` |
| `P11-SFINAE` | `make_unique_maybe_default`, `createSorter` |
| `P12-PRODUCER` | the five producer headers |
| `P13-VALIDATION-ONLY` | `DetectorClocksStandard::IsRightConfig` |
| `P14-DEAD-INCLUDE` | 6 test files + 3 headers |
| `P15-UNCONSTRAINED-FORWARD` | `ProviderTestHelpers.h`, `ProviderList.h` |

**Hard rule: an entity matching no pattern halts the run.** It is reported, never guessed.
This is the rule that made the spdlog migration trustworthy and it should be preserved
verbatim. Extend the catalog, then re-run.

`P15` deserves special handling because grep cannot find it: seed the manual list from a
known-sites file rather than from detection.

---

## 5. Stage 3 — SPEC

**Input:** `plan.json`.
**Output:** one YAML per target under `specs/`.
**Interaction:** **this is the only stage with meaningful human input.**

The spec is the contract between analysis and generation. It is readable, diffable,
reviewable, and version-controlled.

```yaml
target:
  entity:   geo::GeometryCore
  kind:     class
  repo:     larcorealg
  header:   larcorealg/Geometry/GeometryCore.h
  source:   larcorealg/Geometry/GeometryCore.cxx
  pattern:  P5-NESTED-PSET

config_struct:
  name:      Config
  scope:     geo::GeometryCore
  aggregate: true
  members:
    - name: relativePath
      type: std::string
      key: "RelativePath"
      default: '""'
      required: false
    - name: gdmlFile
      type: std::string
      key: "GDML"
      required: true
    - name: detectorName
      type: std::optional<std::string>
      key: "Name"
      required: false
      note: "stem fallback stays in srcs — RECOMMENDATIONS.md §3.5"
    - name: surfaceY
      type: double
      key: "SurfaceY"
      required: true
    - name: positionEpsilon
      type: double
      key: "PositionEpsilon"
      default: "1.e-4"
      required: false

interface:
  repo:      larcorealg-interface
  header:    larcorealg-interface/Geometry/GeometryCoreInterface.h
  source:    larcorealg-interface/Geometry/GeometryCoreInterface.cxx
  namespace: lar::interface
  extractor: extractGeometryCoreConfig
  factory:   makeGeometryCore
  ignorable_keys: lar::IgnorableProviderConfigKeys()
  reject_unknown: warn          # decision 4

rewrite:
  constructor_signature: "GeometryCore(Config const& config, std::unique_ptr<GeometryBuilder>, std::unique_ptr<GeoObjectSorter>)"
  member_init_map:
    fGDMLfile:      "lar::searchPathPlusRelative(config.relativePath, config.gdmlFile)"
    fDetectorName:  "details::maybe_default_detector_name(config.detectorName, fGDMLfile)"
    fSurfaceY:      "config.surfaceY"
    fPositionWiggle: "config.positionEpsilon"
  remove_includes: ['fhiclcpp/fwd.h']

verification:
  roundtrip_test: test/Geometry/GeometryCoreConfig_test.cc
  outdiff_tests:  [geometry_test, geometry_loader_test, geometry_iterator_test]
```

Design notes:

- `member_init_map` is explicit, not inferred. `GeometryCore`'s member-init list wraps two
  keys in `lar::searchPathPlusRelative(...)` and one in a function call. Inferring that is
  possible and fragile; writing it down is cheap and reviewable. This is the field a human
  most often needs to touch.
- `default` holds **source text**, so `std::numeric_limits<Path_t::Depth_t>::max()` and
  `util::kModBoxA` survive unchanged.
- Specs for `P7`–`P11` are generated as skeletons with `TODO` markers and are *not*
  executable until a human completes them.
- Key names are always quoted literals carried from `fhicl::Name`, never derived.

For `P1`–`P4`, the generated spec should be correct as-is and the human step is a quick
read. For `P5`–`P6` it needs a decision. For `P7`+ it is a worksheet.

---

## 6. Stage 4 — GENERATE

Four independent generators, all driven only by the spec. None re-reads the source
except to apply precise AST-ranged edits.

### 6.1 STRUCT (srcs)

Insert the `Config` struct into the target class, public section, before the constructor.
Emit doxygen comments carried from `fhicl::Comment` text (`RECOMMENDATIONS.md` §5.1).

```cpp
struct Config {
  std::string relativePath{};
  std::string gdmlFile{};
  std::optional<std::string> detectorName{};
  double surfaceY{};
  double positionEpsilon{1.e-4};
};
```

Idempotent: if a `Config` with the same members exists, no-op.

### 6.2 EXTRACT (interface)

Generate header + source. Everything comes from the spec.

```cpp
namespace { constexpr std::array knownKeys{
  "RelativePath", "GDML", "Name", "SurfaceY", "PositionEpsilon"}; }

geo::GeometryCore::Config
lar::interface::extractGeometryCoreConfig(fhicl::ParameterSet const& pset)
{
  detail::rejectUnknownKeys(pset, knownKeys,
                            lar::IgnorableProviderConfigKeys(),
                            "geo::GeometryCore", detail::Severity::warn);
  geo::GeometryCore::Config cfg;
  cfg.relativePath    = pset.get<std::string>("RelativePath", "");
  cfg.gdmlFile        = pset.get<std::string>("GDML");
  cfg.detectorName    = detail::optional<std::string>(pset, "Name");
  cfg.surfaceY        = pset.get<double>("SurfaceY");
  cfg.positionEpsilon = pset.get<double>("PositionEpsilon", 1.e-4);
  return cfg;
}
```

For `P5`, emit calls to the child extractors rather than inline reads, and **emit each child
extractor once** even though several parents reference it.

### 6.3 REWRITE (srcs)

The only generator that edits existing code. Four precise edits, each from an AST range:

1. Replace the `fhicl::ParameterSet const&` parameter with `Config const&`.
2. Replace each member-init expression per `member_init_map`.
3. Remove fhicl includes.
4. Add `<optional>` / `<vector>` / `<string>` as needed.

Constraints carried over from the spdlog procedure, which proved their worth:

- **One file is converted completely or not at all.** A half-converted file does not compile,
  so there is no safe intermediate state to pause at.
- **No regex or `sed` bulk rewriting.** AST ranges only.
- **One target per commit**, so a bisect lands on a single decision.
- **Never touch** anything flagged `in_namespace_named_fhicl` or
  `in_inactive_preprocessor_block`.

### 6.4 CMAKE

In `srcs`: drop `fhiclcpp::fhiclcpp` / `fhiclcpp::types` from the target, recording original
visibility; remove the top-level `find_package(fhiclcpp REQUIRED EXPORT)` **last**, after
every target in the package is clean.

In the interface repo: scaffold `CMakeLists.txt`, `ups/product_deps`, `CMakePresets.json`
from the `srcs` originals; add `find_package(fhiclcpp REQUIRED EXPORT)` and
`find_package(<srcs-package> REQUIRED EXPORT)`; create one `cet_make_library` per interface
directory mirroring `srcs` granularity.

Flag, but do not auto-fix, the known defects: the false `fhiclcpp` dependency on
`larcorealg::AuxDetGeoObjectSorter`, and the redundant `find_package` in
`larcorealg/test/CMakeLists.txt`.

---

## 7. Stage 5 — VERIFY

Four gates, ordered cheapest-first. All must pass before a target is reported done.

### G1 — no-fhicl grep gate

```sh
guardrails/fhicl-grep-gate.sh [path ...]
```

Fails if `fhicl`, `fhiclcpp`, `ParameterSet`, or `#include "fhiclcpp/` appears in `srcs`
outside the allowlist. Modeled directly on the spdlog `grep-gate.sh`, including the standing
allowlist mechanism. Allowlist starts as the not-yet-converted set and shrinks to empty.

### G2 — build

Both repos build, and `srcs` links without `libfhiclcpp.so`:

```sh
ldd <srcs lib> | grep -q fhiclcpp && exit 1
```

Stronger than the grep gate and catches transitive leakage through headers.

### G3 — round-trip test

Generated per target (`RECOMMENDATIONS.md` §7.2):

1. full pset → every field correct, one assertion per key
2. empty pset → equals a default-constructed `Config`, **or** throws per required key
3. unknown key → rejected
4. while both exist: old `fhicl::Table<Config>` path and new extractor agree

Check (2) is what prevents the §3.4 default duplication from drifting. Check (4) is the
strongest evidence available and is only possible during the transition — generate and run
it **before** deleting the fhicl version.

### G4 — behavioural equivalence

Reuse the existing spdlog harness unchanged:

```sh
guardrails/gen-targets.sh
guardrails/outdiff.sh baseline <test>     # BEFORE any source edit
guardrails/outdiff.sh check <test>
```

The baseline is irreversible once sources change — the spdlog work recorded this explicitly
as finding 6. Capture baselines during the inventory stage, not at verification time.

---

## 8. Stage 6 — REPORT

Per target: pattern applied, keys converted with types and defaults, files created and
modified, gate results (never "green" on partial evidence), behaviour changes (earlier
validation, newly-rejected unknown keys), capabilities lost
(`print_allowed_configuration`, `Comment` strings), decisions consumed from the decisions
file, and any new catalog gap.

Per package: the `find_package(fhiclcpp)` removal, the PUBLIC-export change and its
downstream impact, remaining allowlist entries.

---

## 9. Driving it: a `/fhicl-refactor` command

Following `.kilo/command/spdlog-migrate.md`, add
`.kilo/command/fhicl-refactor.md` with `{TARGET}` = a package or a file list.

Source documents, always read fresh:

- `fhiclcpp-refactor/ANALYSIS.md`
- `fhiclcpp-refactor/RECOMMENDATIONS.md`
- `fhiclcpp-refactor/WORKFLOW.md`
- `fhiclcpp-refactor/PATTERN_CATALOG.md` (to be written — §4 is its outline)
- `fhiclcpp-refactor/DECISIONS.md` (to be written — `RECOMMENDATIONS.md` §8 is its agenda)

Precedence at every decision point, matching the spdlog workflow:

1. file-specific override in `DECISIONS.md` §2
2. general override in `DECISIONS.md` §2
3. default answer in `DECISIONS.md` §1
4. `PATTERN_CATALOG.md` default
5. `WORKFLOW.md` skeleton default

**Phases, each stopping for explicit approval:**

| phase | action |
|---|---|
| F0 | decisions file complete for this target |
| F1 | interface repo exists and builds empty |
| F2 | `Support/FhiclExtract.h` helpers exist and are unit-tested |
| F3 | guardrail scripts runnable; `gen-targets.sh` current |
| F4 | **outdiff baselines captured** — irreversible later |
| P1 | SCAN — inventory, counts, dead-code list |
| P2 | CLASSIFY — pattern per entity; **halt on any unmatched entity** |
| P3 | SPEC — generate specs; human reviews; `P7`+ completed by hand |
| P4 | ORDER — dependency order, leaves first |
| GATE A | smoke test: one target of the hardest pattern present, end to end, in the real build |
| P5 | GENERATE — per target, all four generators, one commit each |
| P6 | CMAKE — per package, `find_package` removal last |
| GATE B | G1–G4, all results presented explicitly |
| P7 | REPORT |

`GATE A` matters: if the hardest pattern present cannot be done end-to-end in the real build,
the problem is the scaffolding, not the call sites, and bulk generation should not start.

---

## 10. Applying it to a new repository

The workflow has no larsoft-specific logic outside the pattern catalog. For a new repo:

```sh
fhicl-refactor scan     --repo <path> --compile-db <path>/build/compile_commands.json
fhicl-refactor classify --inventory inventory.json
fhicl-refactor spec     --plan plan.json --out specs/
# human reviews specs/
fhicl-refactor generate --specs specs/ --interface-repo <path>-interface
fhicl-refactor verify   --repo <path> --interface-repo <path>-interface
```

Three things are repo-specific and belong in a small config file: the interface repo path,
the interface namespace, and the ignorable-key policy. Everything else is derived.

For a single file, pass `--file` to `scan` and the rest follows unchanged — the spec is the
unit of work, not the repository.

Running it against `lardataobj` should produce an empty inventory and exit cleanly without
creating `lardataobj-interface`. That is a good end-to-end smoke test of the whole pipeline.

---

## 11. Build-out order

| step | deliverable | value |
|---|---|---|
| 1 | SCAN + the §7 G1 grep gate | replaces manual inventory; makes progress measurable immediately |
| 2 | CLASSIFY + `PATTERN_CATALOG.md` | turns 177 occurrences into ~20 decisions |
| 3 | SPEC generation | the reviewable artifact; most of the value, none of the risk |
| 4 | EXTRACT + STRUCT generators | the repetitive bulk |
| 5 | round-trip test generator | makes the bulk trustworthy |
| 6 | REWRITE generator | the only risky generator — build it last, after specs are proven |
| 7 | CMAKE generator | small, mechanical |

Steps 1–3 are read-only and deliver value even if 4–7 are never built: a reviewed set of
specs makes the hand refactor straightforward and consistent. If effort is limited, build
1–3 and 5, and do stages 4a/4c by hand against the specs.

---

## 12. Risks

| risk | mitigation |
|---|---|
| Generator corrupts a `fhicl`-named namespace | hard exclusion on `in_namespace_named_fhicl`; those files are relocate-only |
| Dead `#if 0` code converted | libclang with real compile flags; assert the flag; `LArPropertiesStandard.cxx` is the test case |
| `P15` unconstrained forwarding missed entirely | seed from a known-sites list, not detection; `ProviderTestHelpers.h` and `ProviderList.h` are the two known cases |
| Defaults drift between struct and extractor | round-trip check (2) makes it a build failure |
| Unknown-key rejection surfaces pre-existing `.fcl` typos | warn for one cycle before erroring |
| Removing the PUBLIC fhicl export breaks out-of-tree packages | survey downstream before enforcing G1; `RECOMMENDATIONS.md` §8 decision 12 |
| outdiff baselines lost | capture at F4, before any edit |
| Generated extractors diverge for a shared nested pset | emit each child extractor exactly once; the three different `"Builder"` policies today are what this prevents |
