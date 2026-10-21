#include "spdlog/spdlog.h"
#include <sstream>
#include <string>
#include <utility>

namespace lar::log {

  class LogStream {
    std::ostringstream buf_;
    spdlog::level::level_enum lvl_;
    bool active_;
  public:
    explicit LogStream(spdlog::level::level_enum lvl)
      : lvl_(lvl), active_(spdlog::should_log(lvl)) {}
    LogStream(LogStream&&) = default;
    LogStream(LogStream const&) = delete;
    ~LogStream() {
      if (!active_) return;
      auto s = buf_.str();
      if (!s.empty()) spdlog::log(lvl_, "{}", s);   // note: no format parsing of s
    }
    bool active() const { return active_; }
    template <typename T>
    LogStream& operator<<(T const& v) { if (active_) buf_ << v; return *this; }
    // manipulator support (std::endl etc.)
    LogStream& operator<<(std::ostream& (*m)(std::ostream&)) { if (active_) buf_ << m; return *this; }
  };

  inline LogStream info()  { return LogStream(spdlog::level::info); }
  inline LogStream error() { return LogStream(spdlog::level::err); }
  inline LogStream debug() { return LogStream(spdlog::level::debug); }
}

// mimic lar::dump manipulator
namespace lar::dump {
  struct Vec { double x,y,z; };
  struct VecDumper { Vec v; template <typename Stream> void operator()(Stream&& o) const { o << "{ " << v.x << "; " << v.y << "; " << v.z << " }"; } };
  inline VecDumper vector3D(Vec const& v) { return {v}; }
  template <typename Stream>
  Stream& operator<<(Stream&& out, VecDumper&& m) { m(std::forward<Stream>(out)); return out; }
}

// mimic geo::PlaneGeo::PrintPlaneInfo
template <typename Stream>
void PrintPlaneInfo(Stream&& out, std::string indent, int verb) {
  out << "plane info verb=" << verb;
  out << "\n" << indent << "center at " << lar::dump::vector3D({1,2,3});
}

// mimic GeometryTestAlg::printAuxDetGeo forwarding
template <typename Stream>
void printAuxDetSensitiveGeo(Stream&& out, std::string indent) {
  out << "sensitive vol at " << lar::dump::vector3D({4,5,6}) << indent;
}
template <typename Stream>
void printAuxDetGeo(Stream&& out, std::string indent) {
  out << "auxdet centered at " << lar::dump::vector3D({7,8,9});
  for (int i = 0; i < 2; ++i) {
    out << "\n" << indent << "  [#" << i << "] ";
    printAuxDetSensitiveGeo(std::forward<Stream>(out), indent + "  ");
  }
}

int main() {
  spdlog::set_level(spdlog::level::trace);
  spdlog::set_pattern("%^%l%$: %v");

  // HARD CASE C2: temporary streamed into, then passed to Stream&& printer
  PrintPlaneInfo(lar::log::info() << "  ", "      ", 8);

  // HARD CASE A4/C1: named lvalue forwarded into template, loop accumulation
  {
    auto log = lar::log::info();
    log << "There are 2 auxiliary detectors:";
    for (int i = 0; i < 2; ++i) {
      log << "\n[#" << i << "] ";
      printAuxDetGeo(log, "  ");
    }
  }

  // HARD CASE A10: log alive across a throw
  try {
    auto log = lar::log::error();
    log << "wire IDs:";
    log << "\n  W:0";
    throw std::runtime_error("boom");
  } catch (std::exception const& e) { spdlog::warn("caught {}", e.what()); }

  // std::endl manipulator
  lar::log::info() << "with endl" << std::endl;

  // brace-containing content must NOT be format-parsed
  lar::log::info() << "braces { 0; 0; 0 } and {} literal";

  return 0;
}
