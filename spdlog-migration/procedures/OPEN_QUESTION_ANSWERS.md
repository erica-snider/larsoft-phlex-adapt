These are answers and decisions with rationale needed for the following:

#1
| Open question | Answer  | Notes |
|---|---|---|
| Output pattern | bare `%v`, no timestamp | Want to simplify output to ease comparisons. Time context is available elsewhere |
| Header home | larcoreobj/larcoreobj/LoggingUtil/Logging.h | larcoreobj is at the bottom of the dependency tree. This is not a perfect location, since that repository is intended for data-like objects. A new sub-directory helps identify the expanded scope. |
| Hot-path guard style | Answered in PATTERN_CATALOG §4.1 | |
| File destinations from old config | keep as a second sink | Want to retain possibly useful functionality from the old version | 
| Deprecation window for renamed public init functions | break immediately | Best to just work through the pain now |

#2
Overrides on the hot-path guard style for specific files in the current migration only, and for other general decisions: 
- lardataobj/lardataobj/RecoBase/Event.cxx :  leave this as is, since this class is legacy code and not actively used. If it becomes a problem, then we will address it then.
- lardataobj/lardataobj/RawData/raw.cxx :  function local one-count guard, so once per vector input / waveform / wire
- larcorealg/larcorealg/TestUtils/unit_test_base.h  :  leave this as is, since we're not concerned about a unit test case.
- GeometryBadIntPoint  called in `GeometryCore.cxx`` :   leave as is. Should occur infrequently
- No end-of-job spdlog statistics need to be accumulated
