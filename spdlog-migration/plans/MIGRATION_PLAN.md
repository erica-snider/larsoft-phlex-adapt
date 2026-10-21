# Migration Plan: messagefacility to spdlog

## Executive Summary

This document outlines the plan for migrating the larcorealg codebase from the messagefacility logging framework to spdlog. The migration affects 25 files with 464 occurrences of messagefacility usage.

---

## 1. Current State Analysis

### 1.1 Files Affected
- **Total files using messagefacility**: 25 files
- **Primary categories**:
  - Source files (`.cxx`): 14 files in `larcorealg/Geometry/` and test files
  - Header files (`.h`): 3 files in `larcorealg/TestUtils/` and `larcorealg/Geometry/`
  - Build files: 3 CMakeLists.txt files

### 1.2 Current messagefacility Usage Patterns

#### Include Pattern
```cpp
#include "messagefacility/MessageLogger/MessageLogger.h"
```

#### Macro-based Logging
```cpp
MF_LOG_INFO("category") << "message";
MF_LOG_ERROR("category") << "message";
MF_LOG_TRACE("category") << "message";
MF_LOG_VERBATIM("category") << "message";
```

#### Object-based Logging
```cpp
mf::LogInfo("category") << "message";
mf::LogError("category") << "message";
mf::LogWarning("category") << "message";
mf::LogDebug("category") << "message";
mf::LogVerbatim("category") << "message";
```

#### Initialization (in test infrastructure)
```cpp
mf::StartMessageFacility(pset.get<fhicl::ParameterSet>("services.message"));
mf::SetApplicationName(applName);
mf::SetContextSinglet("main");
mf::SetContextIteration("");
```

### 1.3 Key Files with Heavy Usage
1. `test/Geometry/GeometryIteratorLoopTestAlg.cxx` - 151 occurrences
2. `test/Geometry/GeometryTestAlg.cxx` - 176 occurrences  
3. `larcorealg/TestUtils/unit_test_base.h` - 21 occurrences
4. `larcorealg/Geometry/GeometryCore.cxx` - 6 occurrences
5. `larcorealg/Geometry/WireReadoutGeom.cxx` - 8 occurrences

---

## 2. Target State with spdlog

### 2.1 spdlog Overview
- **Type**: Modern, fast C++ logging library
- **Key features**:
  - Header-only or compiled library options
  - Fast performance (microseconds per log call)
  - Multiple sink support (console, file, rotating files, etc.)
  - Compile-time and runtime log level filtering
  - Thread-safe
  - Format string support via fmt library

### 2.2 spdlog Equivalent Patterns

#### Include Pattern
```cpp
#include "spdlog/spdlog.h"
// Additional includes as needed:
// #include "spdlog/sinks/stdout_color_sinks.h"
// #include "spdlog/sinks/basic_file_sink.h"
```

#### Direct Logging (Simple Replacement)
```cpp
// messagefacility -> spdlog mapping:
mf::LogInfo("category")     -> spdlog::info()
mf::LogError("category")    -> spdlog::error()
mf::LogWarning("category")  -> spdlog::warn()
mf::LogDebug("category")    -> spdlog::debug()
mf::LogVerbatim("category") -> spdlog::info()
MF_LOG_TRACE("category")    -> spdlog::trace()
```

#### Named Logger Pattern (Recommended)
```cpp
auto logger = spdlog::get("category_name");
if (!logger) {
    logger = spdlog::stdout_color_mt("category_name");
}
logger->info("message");
logger->error("message");
logger->warn("message");
logger->debug("message");
logger->trace("message");
```

---

## 3. Migration Strategy

### 3.1 Phase 1: Infrastructure Setup

#### Step 1.1: Update Build System
**Files to modify**: 3 CMakeLists.txt files
- Remove messagefacility dependencies
- Add spdlog dependencies

**Changes needed**:
```cmake
# Remove:
find_package(messagefacility REQUIRED EXPORT)
target_link_libraries(... messagefacility::MF_MessageLogger)

# Add:
find_package(spdlog REQUIRED)
target_link_libraries(... spdlog::spdlog)
```

**Affected files**:
1. `/larcorealg/CMakeLists.txt`
2. `/larcorealg/Geometry/CMakeLists.txt`
3. `/larcorealg/TestUtils/CMakeLists.txt`
4. `/test/Geometry/CMakeLists.txt`

#### Step 1.2: Create Logging Utility Header
**New file**: `larcorealg/CoreUtils/LoggingUtils.h`

**Purpose**: Provide centralized logging utilities and helper functions to:
- Initialize spdlog with consistent configuration
- Create/retrieve named loggers
- Provide stream-to-string conversion utilities
- Set up default formatters and sinks

**Key functions**:
```cpp
namespace lar::logging {
  // Initialize logging system
  void InitializeLogging(std::string const& appName = "larcorealg",
                        spdlog::level::level_enum level = spdlog::level::info);
  
  // Get or create a logger by category name
  std::shared_ptr<spdlog::logger> GetLogger(std::string const& category);
  
  // Helper for stream-based logging (if needed for minimal code changes)
  class StreamLogger {
    std::ostringstream stream_;
    std::shared_ptr<spdlog::logger> logger_;
    spdlog::level::level_enum level_;
  public:
    StreamLogger(std::string const& category, spdlog::level::level_enum level);
    ~StreamLogger();
    template<typename T>
    StreamLogger& operator<<(T const& value);
  };
  
  // Convenience functions
  StreamLogger LogInfo(std::string const& category);
  StreamLogger LogError(std::string const& category);
  StreamLogger LogWarning(std::string const& category);
  StreamLogger LogDebug(std::string const& category);
  StreamLogger LogTrace(std::string const& category);
}
```

#### Step 1.3: Update StandaloneBasicSetup
**File**: `larcorealg/Geometry/StandaloneBasicSetup.h`

**Changes**:
- Remove `SetupMessageFacility()` function
- Add `SetupLogging()` function using spdlog
- Update documentation

---

### 3.2 Phase 2: Code Migration

#### Migration Approach Options

**Option A: Direct Replacement (Fastest, but loses category context)**
Replace messagefacility calls with spdlog global logger:
```cpp
// Before:
mf::LogInfo("GeometryCore") << "Message: " << value;

// After:
spdlog::info("Message: {}", value);
```

**Pros**: Minimal code changes, fastest migration
**Cons**: Loses category/context information

**Option B: Named Loggers (Recommended)**
Use named loggers to preserve category information:
```cpp
// Before:
mf::LogInfo("GeometryCore") << "Message: " << value;

// After:
auto logger = lar::logging::GetLogger("GeometryCore");
logger->info("Message: {}", value);
```

**Pros**: Preserves category context, allows per-category filtering
**Cons**: More code changes, need to convert stream operations to format strings

**Option C: Stream Wrapper (Minimal Disruption)**
Use stream wrapper for minimal code changes:
```cpp
// Before:
mf::LogInfo("GeometryCore") << "Message: " << value;

// After:
lar::logging::LogInfo("GeometryCore") << "Message: " << value;
```

**Pros**: Minimal code changes, preserves existing syntax
**Cons**: Requires implementing stream wrapper, slightly less performant

**Recommended**: **Option B (Named Loggers)** for new code and heavily-used paths, **Option C (Stream Wrapper)** for quick migration of existing code.

#### Step 2.1: Categorize and Prioritize Files

**Priority 1 - Core Library Files** (8 files):
- `larcorealg/Geometry/GeometryCore.cxx`
- `larcorealg/Geometry/WireReadoutGeom.cxx`
- `larcorealg/Geometry/WireReadoutStandardGeom.cxx`
- `larcorealg/Geometry/AuxDetGeometryCore.cxx`
- `larcorealg/Geometry/AuxDetReadoutGeom.cxx`
- `larcorealg/Geometry/AuxDetSensitiveGeo.cxx`
- `larcorealg/Geometry/AuxDetGeo.cxx`
- `larcorealg/Geometry/CryostatGeo.cxx`

**Priority 2 - Infrastructure/Utilities** (4 files):
- `larcorealg/Geometry/StandaloneBasicSetup.h`
- `larcorealg/TestUtils/unit_test_base.h`
- `larcorealg/TestUtils/geometry_unit_test_base.h`
- `larcorealg/Geometry/WireReadoutDumper.h`

**Priority 3 - Test Code** (10 files):
- All files in `test/Geometry/` directory

**Priority 4 - Light Usage Files** (3 files):
- Files with 1-2 logging calls only

#### Step 2.2: Migration Pattern for Each File

**For each source file**:

1. **Update includes**:
   ```cpp
   // Remove:
   #include "messagefacility/MessageLogger/MessageLogger.h"
   
   // Add:
   #include "spdlog/spdlog.h"
   #include "larcorealg/CoreUtils/LoggingUtils.h"  // if using wrapper
   ```

2. **Replace logging calls**:
   
   **Pattern 1: Single-line logs**
   ```cpp
   // Before:
   mf::LogInfo("Category") << "Message with value: " << value;
   
   // After (named logger):
   auto logger = lar::logging::GetLogger("Category");
   logger->info("Message with value: {}", value);
   
   // Or (stream wrapper):
   lar::logging::LogInfo("Category") << "Message with value: " << value;
   ```
   
   **Pattern 2: Multi-line logs**
   ```cpp
   // Before:
   mf::LogVerbatim log("Category");
   log << "Line 1: " << value1;
   log << "Line 2: " << value2;
   
   // After (format string):
   auto logger = lar::logging::GetLogger("Category");
   logger->info("Line 1: {}\nLine 2: {}", value1, value2);
   
   // Or (stream wrapper):
   lar::logging::LogInfo log("Category");
   log << "Line 1: " << value1;
   log << "Line 2: " << value2;
   ```
   
   **Pattern 3: Conditional logging**
   ```cpp
   // Before:
   if (condition) {
       mf::LogError("Category") << "Error: " << error;
   }
   
   // After:
   if (condition) {
       auto logger = lar::logging::GetLogger("Category");
       logger->error("Error: {}", error);
   }
   ```

3. **Update initialization code** (test files only):
   ```cpp
   // Before:
   SetupMessageFacility(pset, "app_name");
   
   // After:
   lar::logging::InitializeLogging("app_name", spdlog::level::info);
   ```

---

### 3.3 Phase 3: Testing & Validation

#### Step 3.1: Unit Testing
- Ensure all existing tests pass after migration
- Verify log output format is acceptable
- Check log levels are correctly applied

#### Step 3.2: Integration Testing
- Run full test suite in `test/Geometry/`
- Verify geometry tests produce expected output
- Check for any runtime errors or missing logs

#### Step 3.3: Performance Validation
- Compare performance before/after (spdlog should be faster)
- Verify no performance regressions

---

## 4. Detailed Migration Mapping

### 4.1 Log Level Mapping

| messagefacility | spdlog | Usage |
|----------------|--------|-------|
| `mf::LogError()` | `spdlog::error()` | Error conditions |
| `mf::LogWarning()` | `spdlog::warn()` | Warning conditions |
| `mf::LogInfo()` | `spdlog::info()` | Informational messages |
| `MF_LOG_INFO()` | `spdlog::info()` | Informational messages (macro) |
| `mf::LogDebug()` | `spdlog::debug()` | Debug messages |
| `MF_LOG_TRACE()` | `spdlog::trace()` | Verbose debug/trace |
| `mf::LogVerbatim()` | `spdlog::info()` | Unformatted output |
| `MF_LOG_VERBATIM()` | `spdlog::info()` | Unformatted output (macro) |

### 4.2 Stream Operator to Format String Conversion

**Common patterns**:

```cpp
// Pattern 1: Simple concatenation
// Before: log << "Value: " << x << " and " << y;
// After:  logger->info("Value: {} and {}", x, y);

// Pattern 2: Formatting
// Before: log << "Float: " << std::setprecision(3) << value;
// After:  logger->info("Float: {:.3f}", value);

// Pattern 3: Conditionals
// Before: log << "Status: " << (flag ? "yes" : "no");
// After:  logger->info("Status: {}", flag ? "yes" : "no");

// Pattern 4: Multiple lines
// Before: 
//   mf::LogInfo log("Cat");
//   log << "Line 1";
//   log << "Line 2";
// After:
//   auto logger = lar::logging::GetLogger("Cat");
//   logger->info("Line 1\nLine 2");
```

---

## 5. Implementation Considerations

### 5.1 Configuration Options

**Default configuration** for all loggers:
- **Pattern**: `"[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v"`
  - Shows: timestamp, logger name (category), level, message
- **Level**: `info` by default (configurable)
- **Sinks**: Console (stdout) with color support

**Advanced options** (future enhancements):
- File output with rotation
- Per-category log levels
- Runtime configuration via environment variables

### 5.2 Thread Safety
- Use `_mt` (multi-threaded) logger variants by default
- spdlog is thread-safe when using `_mt` loggers
- messagefacility was also thread-safe, so no change in behavior

### 5.3 Performance Considerations
- spdlog is significantly faster than messagefacility
- Compile-time log level filtering available via macros (e.g., `SPDLOG_ACTIVE_LEVEL`)
- Consider async logging for high-throughput scenarios (future optimization)

### 5.4 Backward Compatibility
- Consider keeping a compatibility layer initially
- Could provide macro definitions that map old names to new
- Allows gradual migration if needed

Example compatibility header (`MessageFacilityCompat.h`):
```cpp
#include "larcorealg/CoreUtils/LoggingUtils.h"

namespace mf {
  using LogInfo = lar::logging::LogInfo;
  using LogError = lar::logging::LogError;
  using LogWarning = lar::logging::LogWarning;
  using LogDebug = lar::logging::LogDebug;
  using LogVerbatim = lar::logging::LogInfo;
}

#define MF_LOG_INFO(cat) lar::logging::LogInfo(cat)
#define MF_LOG_ERROR(cat) lar::logging::LogError(cat)
#define MF_LOG_TRACE(cat) lar::logging::LogTrace(cat)
#define MF_LOG_VERBATIM(cat) lar::logging::LogInfo(cat)
```

---

## 6. Risk Assessment & Mitigation

### 6.1 Risks

| Risk | Severity | Likelihood | Impact |
|------|----------|------------|--------|
| Log output format changes break downstream tools | Medium | Low | Medium |
| Missing log messages due to incorrect mapping | High | Low | High |
| Performance regression | Low | Very Low | Low |
| Build system issues | Medium | Medium | Medium |
| Category information lost | Medium | Low | High |

### 6.2 Mitigation Strategies

1. **Log format changes**: 
   - Configure spdlog pattern to closely match messagefacility output
   - Document output format changes
   - Test with downstream consumers

2. **Missing logs**:
   - Systematic review of all migrations
   - Side-by-side comparison testing
   - Grep for remaining messagefacility usage

3. **Build issues**:
   - Test on clean build environment
   - Update all CMake files systematically
   - Document spdlog version requirements

4. **Category preservation**:
   - Use named loggers (Option B) or stream wrapper (Option C)
   - Include category in log pattern

---

## 7. Timeline Estimate

### Estimated Effort

| Phase | Task | Estimated Time |
|-------|------|----------------|
| **Phase 1** | Infrastructure Setup | 2-3 days |
| | - Build system updates | 0.5 day |
| | - LoggingUtils.h implementation | 1 day |
| | - StandaloneBasicSetup updates | 0.5 day |
| | - Testing infrastructure | 1 day |
| **Phase 2** | Code Migration | 5-7 days |
| | - Priority 1 files (core) | 2 days |
| | - Priority 2 files (infrastructure) | 1.5 days |
| | - Priority 3 files (tests) | 2-3 days |
| | - Priority 4 files (light usage) | 0.5 day |
| **Phase 3** | Testing & Validation | 2-3 days |
| | - Unit testing | 1 day |
| | - Integration testing | 1 day |
| | - Documentation | 1 day |
| **Total** | | **9-13 days** |

---

## 8. Success Criteria

1. ✅ All 25 files successfully migrated
2. ✅ No remaining references to messagefacility in code
3. ✅ All existing tests pass
4. ✅ Build system successfully finds and links spdlog
5. ✅ Log output is clear and useful
6. ✅ Performance is equal or better than before
7. ✅ Documentation updated

---

## 9. Rollback Plan

If critical issues arise:

1. **Build failure**: Revert CMake changes, restore messagefacility
2. **Test failures**: Revert code changes file-by-file until issue found
3. **Runtime issues**: Use compatibility layer to restore old behavior
4. **Performance issues**: Investigate spdlog configuration, possibly use async logging

**Version control strategy**:
- Create feature branch for migration
- Commit each phase separately
- Test thoroughly before merging
- Tag stable points for easy rollback

---

## 10. Post-Migration Tasks

### 10.1 Cleanup
- Remove compatibility layer (if used)
- Remove old messagefacility configuration files
- Update developer documentation

### 10.2 Optimization Opportunities
- Implement async logging for high-volume logs
- Add file output sinks where appropriate
- Implement per-category log level configuration
- Add log rotation for long-running processes

### 10.3 Documentation
- Update developer guide with new logging patterns
- Create examples for common logging scenarios
- Document configuration options

---

## 11. References

### messagefacility Documentation
- GitHub: https://github.com/art-framework-suite/messagefacility
- Used primarily in art framework and LArSoft

### spdlog Documentation
- GitHub: https://github.com/gabime/spdlog
- README: https://github.com/gabime/spdlog/blob/v1.x/README.md
- Wiki: https://github.com/gabime/spdlog/wiki

### Key spdlog Features for This Migration
- Named loggers with `spdlog::get()` and logger creation
- Console sinks with color: `spdlog::stdout_color_mt()`
- Log levels: trace, debug, info, warn, error, critical
- Format string syntax (fmt library): `logger->info("value: {}", x)`
- Pattern formatting for output customization
- Thread-safe variants (`_mt` suffix)

---

## 12. File-by-File Migration Checklist

### Core Library Files (Priority 1)
- [ ] `larcorealg/Geometry/GeometryCore.cxx` (6 occurrences)
- [ ] `larcorealg/Geometry/WireReadoutGeom.cxx` (8 occurrences)
- [ ] `larcorealg/Geometry/WireReadoutStandardGeom.cxx` (4 occurrences)
- [ ] `larcorealg/Geometry/AuxDetGeometryCore.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/AuxDetReadoutGeom.cxx` (3 occurrences)
- [ ] `larcorealg/Geometry/AuxDetSensitiveGeo.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/AuxDetGeo.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/CryostatGeo.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/PlaneGeo.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/TPCGeo.cxx` (2 occurrences)
- [ ] `larcorealg/Geometry/WireGeo.cxx` (1 occurrence)
- [ ] `larcorealg/Geometry/Intersections.cxx` (2 occurrences)

### Infrastructure Files (Priority 2)
- [ ] `larcorealg/Geometry/StandaloneBasicSetup.h` (12 occurrences)
- [ ] `larcorealg/TestUtils/unit_test_base.h` (21 occurrences)
- [ ] `larcorealg/TestUtils/geometry_unit_test_base.h` (3 occurrences)
- [ ] `larcorealg/Geometry/WireReadoutDumper.h` (2 occurrences)

### Test Files (Priority 3)
- [ ] `test/Geometry/GeometryIteratorLoopTestAlg.cxx` (151 occurrences)
- [ ] `test/Geometry/GeometryTestAlg.cxx` (176 occurrences)
- [ ] `test/Geometry/geometry_iterator_loop_test.cxx` (2 occurrences)
- [ ] `test/Geometry/geometry_loader_test.cxx` (7 occurrences)
- [ ] `test/Geometry/geometry_test.cxx` (2 occurrences)

### Build Files
- [ ] `larcorealg/CMakeLists.txt` (1 occurrence)
- [ ] `larcorealg/Geometry/CMakeLists.txt` (2 occurrences)
- [ ] `larcorealg/TestUtils/CMakeLists.txt` (2 occurrences)
- [ ] `test/Geometry/CMakeLists.txt` (3 occurrences)

---

## Appendix A: Example Migration - Complete File

**Before** (`GeometryCore.cxx` excerpt):
```cpp
#include "messagefacility/MessageLogger/MessageLogger.h"

namespace geo {
  GeometryCore::GeometryCore(fhicl::ParameterSet const& pset)
  {
    // ... initialization code ...
    mf::LogInfo("GeometryCore") << "New detector geometry loaded from\n\t" << fGDMLfile;
  }
  
  void GeometryCore::CheckGeometry() const
  {
    if (hasError) {
      mf::LogError("GeometryCore") << "Geometry check failed: " << errorMsg;
    }
    else {
      mf::LogDebug("GeometryCore") << "Geometry check passed";
    }
  }
}
```

**After** (Option B - Named Loggers):
```cpp
#include "spdlog/spdlog.h"
#include "larcorealg/CoreUtils/LoggingUtils.h"

namespace geo {
  GeometryCore::GeometryCore(fhicl::ParameterSet const& pset)
  {
    // ... initialization code ...
    auto logger = lar::logging::GetLogger("GeometryCore");
    logger->info("New detector geometry loaded from\n\t{}", fGDMLfile);
  }
  
  void GeometryCore::CheckGeometry() const
  {
    auto logger = lar::logging::GetLogger("GeometryCore");
    if (hasError) {
      logger->error("Geometry check failed: {}", errorMsg);
    }
    else {
      logger->debug("Geometry check passed");
    }
  }
}
```

**After** (Option C - Stream Wrapper):
```cpp
#include "spdlog/spdlog.h"
#include "larcorealg/CoreUtils/LoggingUtils.h"

namespace geo {
  GeometryCore::GeometryCore(fhicl::ParameterSet const& pset)
  {
    // ... initialization code ...
    lar::logging::LogInfo("GeometryCore") << "New detector geometry loaded from\n\t" << fGDMLfile;
  }
  
  void GeometryCore::CheckGeometry() const
  {
    if (hasError) {
      lar::logging::LogError("GeometryCore") << "Geometry check failed: " << errorMsg;
    }
    else {
      lar::logging::LogDebug("GeometryCore") << "Geometry check passed";
    }
  }
}
```

---

## Appendix B: LoggingUtils.h Implementation Sketch

```cpp
#ifndef LARCOREALG_COREUTILS_LOGGINGUTILS_H
#define LARCOREALG_COREUTILS_LOGGINGUTILS_H

#include "spdlog/spdlog.h"
#include "spdlog/sinks/stdout_color_sinks.h"
#include <sstream>
#include <memory>
#include <string>

namespace lar::logging {

  // Initialize the logging system
  inline void InitializeLogging(std::string const& appName = "larcorealg",
                                spdlog::level::level_enum level = spdlog::level::info)
  {
    spdlog::set_level(level);
    spdlog::set_pattern("[%Y-%m-%d %H:%M:%S.%e] [%n] [%^%l%$] %v");
    auto console = spdlog::stdout_color_mt(appName);
    spdlog::set_default_logger(console);
  }

  // Get or create a named logger
  inline std::shared_ptr<spdlog::logger> GetLogger(std::string const& category)
  {
    auto logger = spdlog::get(category);
    if (!logger) {
      logger = spdlog::stdout_color_mt(category);
    }
    return logger;
  }

  // Stream-based logger wrapper (for backward compatibility)
  class StreamLogger {
  private:
    std::ostringstream stream_;
    std::shared_ptr<spdlog::logger> logger_;
    spdlog::level::level_enum level_;

  public:
    StreamLogger(std::string const& category, spdlog::level::level_enum level)
      : logger_(GetLogger(category)), level_(level)
    {}

    ~StreamLogger() {
      if (!stream_.str().empty()) {
        logger_->log(level_, stream_.str());
      }
    }

    template<typename T>
    StreamLogger& operator<<(T const& value) {
      stream_ << value;
      return *this;
    }
  };

  // Convenience functions
  inline StreamLogger LogInfo(std::string const& category) {
    return StreamLogger(category, spdlog::level::info);
  }

  inline StreamLogger LogError(std::string const& category) {
    return StreamLogger(category, spdlog::level::err);
  }

  inline StreamLogger LogWarning(std::string const& category) {
    return StreamLogger(category, spdlog::level::warn);
  }

  inline StreamLogger LogDebug(std::string const& category) {
    return StreamLogger(category, spdlog::level::debug);
  }

  inline StreamLogger LogTrace(std::string const& category) {
    return StreamLogger(category, spdlog::level::trace);
  }

} // namespace lar::logging

#endif // LARCOREALG_COREUTILS_LOGGINGUTILS_H
```

---

**End of Migration Plan**
