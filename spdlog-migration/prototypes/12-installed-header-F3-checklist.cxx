// Verification of the REAL installed header: larcoreobj/LoggingUtil/Logging.h
// Covers the PROCEDURE.md F3 checklist. Each case prints an expectation marker;
// the driver script compares emitted record counts where that is the point.
//
// NOTE: unlike prototypes 01-11, this one includes the real header and links the
// compiled spdlog library, so it needs the gcc 12.2.0 toolchain that spdlog was
// built with (the system g++ 11.5 lacks GLIBCXX_3.4.30). build-and-run.sh skips
// it; see verify-installed-header.sh in this directory.

#include "larcoreobj/LoggingUtil/Logging.h"

#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// ---------------------------------------------------------------- test types

// (a) ostream-only ADL operator<<, the util::quantities shape: NOT a template,
//     takes std::ostream& specifically.
namespace units {
  struct Quantity {
    double v;
    char const* u;
  };
  std::ostream& operator<<(std::ostream& out, Quantity const q)
  {
    return out << q.v << " " << q.u;
  }
}

// (b) generic dump manipulator, the lar::dump:: shape. Emits literal braces.
namespace lar::dump {
  struct Vector3D {
    double x, y, z;
  };
  template <typename Stream>
  Stream& operator<<(Stream&& out, Vector3D const& v)
  {
    out << "{ " << v.x << "; " << v.y << "; " << v.z << " }";
    return out;
  }
}

// (c) the Stream&& printing protocol, re-forwarded through several levels
template <typename Stream>
void printInner(Stream&& out, int i)
{
  out << " inner" << i;
}
template <typename Stream>
void printMiddle(Stream&& out, int n)
{
  for (int i = 0; i < n; ++i)
    printInner(std::forward<Stream>(out), i);
}
template <typename Stream>
void printOuter(Stream&& out)
{
  out << "outer:";
  printMiddle(std::forward<Stream>(out), 3);
}

// (d) the DumperBase::Indenter shape: stores the stream BY VALUE in a member
struct DumperBase {
  template <typename Stream>
  class Indenter {
    Stream out;
    DumperBase const& dumper;

  public:
    Indenter(Stream out, DumperBase const& d) : out(std::forward<Stream>(out)), dumper(d) {}
    template <typename T>
    Indenter& operator<<(T&& v)
    {
      out << std::forward<T>(v);
      return *this;
    }
    Indenter& newline()
    {
      out << '\n';
      return *this;
    }
  };
  template <typename Stream>
  decltype(auto) indenter(Stream&& out) const
  {
    return Indenter<Stream>(std::forward<Stream>(out), *this);
  }
};

// (e) a class/method to exercise the scoped-name prefix
namespace geo {
  struct WireReadoutGeom {
    void ChannelsIntersect(int c) const { LAR_LOG_INFO << "channel " << c << " maps to no wire"; }
    template <typename T>
    void tmpl(T v) const
    {
      LAR_LOG_INFO << "templated " << v;
    }
    WireReadoutGeom() { LAR_LOG_INFO << "constructed"; }
  };
}

// (f) a type whose operator<< THROWS: proves a suppressed level never formats
namespace probe {
  struct Boom {};
  inline std::ostream& operator<<(std::ostream&, Boom const&)
  {
    throw std::runtime_error("must not be formatted when suppressed");
  }
}

// compile-time check of the extractor
static_assert(lar::log::detail::qualifiedName("void geo::A::f(int) const") == "geo::A::f");
static_assert(lar::log::detail::qualifiedName("void geo::free()") == "geo::free");
static_assert(lar::log::detail::qualifiedName(
                "void geo::A::t(T) const [with T = double]") == "geo::A::t");

int main(int argc, char** argv)
{
  // optional argv[1]: path for the CASE 19 file sink (default: cwd)
  std::string const sinkPath = (argc > 1) ? argv[1] : "logging_verify_sink.log";

  // bare pattern, as decided: no timestamp, no level, no logger name
  spdlog::set_pattern("%v");
  spdlog::set_level(spdlog::level::trace);

  std::cout << "--- CASE 1: scoped-name prefix ---\n";
  geo::WireReadoutGeom g;
  g.ChannelsIntersect(7);
  g.tmpl(3.5);

  std::cout << "--- CASE 2: named accumulating object, control flow ---\n";
  {
    auto log = LAR_LOG_INFO;
    log << "tests completed:";
    std::vector<std::string> const tests{"alpha", "beta"};
    if (tests.empty()) { log << "\n  none"; }
    else {
      log << "\n  " << tests.size() << " run:";
      for (auto const& t : tests)
        log << " " << t;
    }
  } // ONE record expected here

  std::cout << "--- CASE 3: Stream&& forwarding, lvalue ---\n";
  {
    auto log = LAR_LOG_INFO;
    printOuter(log);
  }

  std::cout << "--- CASE 4: Stream&& forwarding, temporary already streamed to ---\n";
  printOuter(LAR_LOG_INFO << "prefix ");

  std::cout << "--- CASE 5: generic dump manipulator with literal braces ---\n";
  LAR_LOG_INFO << "point " << lar::dump::Vector3D{0, 0, 0};

  std::cout << "--- CASE 6: body containing braces and a {} pair ---\n";
  LAR_LOG_INFO << "literal { and } and {} and {0} must survive verbatim";

  std::cout << "--- CASE 7: ostream-only ADL type ---\n";
  LAR_LOG_INFO << "trigger => " << units::Quantity{4.5, "us"};

  std::cout << "--- CASE 8: std::setw / std::fixed / std::setprecision ---\n";
  {
    auto log = LAR_LOG_INFO;
    log << std::setw(10) << "Drift:" << " | " << std::setw(9) << "time [us]";
    log << "\n" << std::setw(10) << "TPC0" << " | " << std::fixed << std::setprecision(2)
        << std::setw(9) << 1.5;
  }

  std::cout << "--- CASE 9: std::endl / std::flush ---\n";
  LAR_LOG_INFO << "before" << std::endl << "after" << std::flush;

  std::cout << "--- CASE 10: Indenter stores BY VALUE (prvalue arg) ---\n";
  {
    DumperBase d;
    auto out = d.indenter(LAR_LOG_INFO);
    out << "OpDetWaveform ch=3";
    out.newline();
    out << " " << std::setw(4) << 1024 << " " << std::setw(4) << 2048;
  }

  std::cout << "--- CASE 11: Indenter holds a REFERENCE (lvalue arg) ---\n";
  {
    DumperBase d;
    auto log = LAR_LOG_INFO;
    auto out = d.indenter(log);
    out << "lvalue form";
  }

  std::cout << "--- CASE 12: move emits EXACTLY ONCE (expect 1 record) ---\n";
  {
    auto a = LAR_LOG_WARNING;
    a << "emitted exactly once";
    auto b = std::move(a);
  }

  std::cout << "--- CASE 13: constructed but never streamed (expect NO record) ---\n";
  {
    auto log = LAR_LOG_ERROR;
    (void)log;
  }

  std::cout << "--- CASE 14: suppressed level formats nothing (expect NO record) ---\n";
  {
    spdlog::set_level(spdlog::level::warn);
    LAR_LOG_DEBUG << probe::Boom{};
    spdlog::set_level(spdlog::level::trace);
  }

  std::cout << "--- CASE 15: log alive across a throw (emitted while unwinding) ---\n";
  try {
    auto log = LAR_LOG_ERROR;
    log << "3 wire IDs for channel #12:";
    log << "\n  W:0" << "\n  W:1";
    throw std::runtime_error("bad channel lookup");
  }
  catch (std::exception const& e) {
    std::cout << "(caught: " << e.what() << ")\n";
  }

  std::cout << "--- CASE 16: multi-line body is ONE record ---\n";
  LAR_LOG_INFO << "line1\nline2\nline3";

  std::cout << "--- CASE 17: debugEnabled() ---\n";
  spdlog::set_level(spdlog::level::info);
  std::cout << "(at info, debugEnabled=" << (lar::log::debugEnabled() ? "true" : "false") << ")\n";
  spdlog::set_level(spdlog::level::debug);
  std::cout << "(at debug, debugEnabled=" << (lar::log::debugEnabled() ? "true" : "false") << ")\n";
  spdlog::set_level(spdlog::level::trace);

  std::cout << "--- CASE 18: all five level macros ---\n";
  LAR_LOG_TRACE << "trace level";
  LAR_LOG_DEBUG << "debug level";
  LAR_LOG_INFO << "info level";
  LAR_LOG_WARNING << "warn level";
  LAR_LOG_ERROR << "err level";

  std::cout << "--- CASE 19: setup() with explicit level + file sink ---\n";
  lar::log::setup("verify", spdlog::level::trace, sinkPath);
  LAR_LOG_TRACE << "trace survives an explicit trace threshold";
  LAR_LOG_INFO << "info via configured logger";

  return 0;
}
