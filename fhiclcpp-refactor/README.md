# fhiclcpp::ParameterSet refactor

Analysis, recommendations, and workflow design for removing the `fhicl-cpp` dependency
from the LArSoft packages under
`/exp/dune/app/users/esnider/code-spack/larsoft3/mpdtest/mpddev/srcs`
by introducing a thin interface layer that extracts configuration from
`fhicl::ParameterSet` and forwards it to targets as plain configuration structs.

**No code in `srcs` has been modified. These documents are analysis and design only.**

## Documents

| document | contents |
|---|---|
| [`ANALYSIS.md`](ANALYSIS.md) | Complete inventory of fhicl/fhiclcpp use across all four repos: repository, file, class or function, role, keys with types and defaults, forwarding, build-system dependencies, dead code, and the edge cases that need design decisions |
| [`RECOMMENDATIONS.md`](RECOMMENDATIONS.md) | Recommended approach: config struct conventions, interface layer structure and naming, handling for each problematic pattern, what is lost and how to compensate, verification strategy, work ordering, and the open decisions |
| [`WORKFLOW.md`](WORKFLOW.md) | Design for an automated pipeline: six stages from AST scan to verification, a pattern catalog, the reviewable per-target spec format, four generators, four verification gates, and a `/fhicl-refactor` command following the existing spdlog-migration precedent |

## Findings in brief

**Scope is smaller than it looks.** 177 `ParameterSet` tokens across 51 files reduce to
three consumption idioms and about 20 target entities:

- raw `pset.get<>` in a constructor body — 4 classes
- `fhicl::Table<Config>` validated config — 4 classes, where the plain struct already
  exists in all but name
- degenerate constructors that take a pset and ignore it — 3 classes

**Five headers are producers, not consumers.** `geo_types_fhicl.h`,
`readout_types_fhicl.h`, `quantities_fhicl.h`, `intervals_fhicl.h` and
`geo_vectors_fhicl.h` define FHiCL vocabulary for other people's config structs. They have
no configuration to extract and relocate to the interface repos essentially unchanged.
This is the single largest simplification available and accounts for a large share of the
raw token count.

**`lardataobj` needs no work.** It has no fhicl include, no fhicl symbol, and no fhicl
CMake reference. No `lardataobj-interface` repository should be created.

**Three structural edge cases drive the real work:** nested parameter sets (`"Builder"`,
`"SortingParameters"`) that make the interface layer a tree of composed extractors; a
stored `ParameterSet` in `AuxDetGeometryCore` validated lazily much later; and a test
harness built on runtime-computed dotted key paths and on
`std::is_constructible_v<T, fhicl::ParameterSet>` as a dispatch trait.

**Two risks sit outside the mechanical work.** `larcorealg::Geometry` and
`lardataalg::DetectorInfo` export `fhiclcpp` **PUBLIC**, so removing it is an API-visible
change for downstream packages not present in this tree — `geo_types_fhicl.h` in particular
has zero in-tree consumers, meaning all its real consumers are external. And three
constructors that appear deletable are load-bearing for SFINAE dispatch; translating them
mechanically would silently break two generic factories, one of which has no `else` branch
and would fall off the end returning `void`.

## Proposed repository split

| srcs repo | interface repo | needed |
|---|---|---|
| `larcorealg` | `larcorealg-interface` | yes |
| `larcoreobj` | `larcoreobj-interface` | yes (relocation only) |
| `lardataalg` | `lardataalg-interface` | yes |
| `lardataobj` | — | no |

## Before starting work

`RECOMMENDATIONS.md` §8 lists twelve decisions that a tool cannot make and that change what
gets generated. They should be answered and recorded in a `DECISIONS.md` first, following
the `OPEN_QUESTION_ANSWERS.md` precedent from the spdlog migration. Decision 12 — surveying
out-of-tree consumers of the PUBLIC fhicl export — is the one with schedule risk and should
be scoped before work starts rather than discovered during it.

## Relationship to the spdlog migration

This tree already contains a completed, documented migration of comparable shape
(`larsoft-phlex-adapt/spdlog-migration/`, driven by `.kilo/command/spdlog-migrate.md`). Its
structure — stop-for-approval phases, a pattern catalog, a decisions file with explicit
precedence, and mechanical guardrail gates — transfers directly, and its guardrail scripts
(`gen-targets.sh`, `outdiff.sh`, `normalize.sed`, `env.sh`) are reusable as-is for
behavioural verification. `WORKFLOW.md` deliberately mirrors that shape rather than
inventing a new one.

One operational detail carries over and is easy to get wrong: output baselines must be
captured **before** any source is edited. That was recorded as finding 6 of the spdlog
guardrails work, and it is irreversible.
