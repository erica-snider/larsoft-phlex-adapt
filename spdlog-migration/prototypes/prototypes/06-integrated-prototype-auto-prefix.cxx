#include "spdlog/spdlog.h"
#include <sstream>
#include <string>
#include <string_view>
#include <utility>

namespace lar::log {
namespace detail {
  constexpr std::string_view qualifiedName(std::string_view pretty)
  {
    if (auto b = pretty.find(" [with "); b != std::string_view::npos)
      pretty.remove_suffix(pretty.size() - b);
    std::size_t depth = 0, paren = std::string_view::npos;
    for (std::size_t i = pretty.size(); i-- > 0;) {
      char c = pretty[i];
      if (c == ')') ++depth;
      else if (c == '(') { if (--depth == 0) { paren = i; break; } }
    }
    if (paren == std::string_view::npos) return pretty;
    std::string_view head = pretty.substr(0, paren);
    int angle = 0;
    for (std::size_t i = head.size(); i-- > 0;) {
      char c = head[i];
      if (c == '>') ++angle; else if (c == '<') --angle;
      else if (c == ' ' && angle == 0) return head.substr(i + 1);
    }
    return head;
  }
}

  class LogStream {
    std::ostringstream buf_;
    spdlog::level::level_enum lvl_;
    bool active_;
  public:
    LogStream(spdlog::level::level_enum lvl, std::string_view where)
      : lvl_(lvl), active_(spdlog::should_log(lvl))
    { if (active_ && !where.empty()) buf_ << where << ": "; }
    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;
    ~LogStream() {
      if (!active_) return;
      auto s = buf_.str();
      if (!s.empty()) spdlog::log(lvl_, "{}", s);
    }
    explicit operator bool() const { return active_; }
    template <typename T> LogStream& operator<<(T const& v) { if (active_) buf_ << v; return *this; }
    LogStream& operator<<(std::ostream& (*m)(std::ostream&)) { if (active_) buf_ << m; return *this; }
  };
}

#define LAR_HERE (::lar::log::detail::qualifiedName(__PRETTY_FUNCTION__))
#define LAR_LOG_ERROR ::lar::log::LogStream(spdlog::level::err,      LAR_HERE)
#define LAR_LOG_WARN  ::lar::log::LogStream(spdlog::level::warn,     LAR_HERE)
#define LAR_LOG_INFO  ::lar::log::LogStream(spdlog::level::info,     LAR_HERE)
#define LAR_LOG_DEBUG ::lar::log::LogStream(spdlog::level::debug,    LAR_HERE)
#define LAR_LOG_TRACE ::lar::log::LogStream(spdlog::level::trace,    LAR_HERE)

namespace lar::dump {
  struct Vec { double x,y,z; };
  struct VecDumper { Vec v; template <typename S> void operator()(S&& o) const { o << "{ " << v.x << "; " << v.y << "; " << v.z << " }"; } };
  inline VecDumper vector3D(Vec const& v) { return {v}; }
  template <typename S> S& operator<<(S&& out, VecDumper&& m) { m(std::forward<S>(out)); return out; }
}

namespace geo {
  template <typename Stream>
  void PrintPlaneInfo(Stream&& out, std::string indent, int verb) {
    out << "plane verb=" << verb << "\n" << indent << "center " << lar::dump::vector3D({1,2,3});
  }
  struct GeometryTestAlg {
    template <typename Stream> void printAuxDetSensitiveGeo(Stream&& out, std::string ind) const
    { out << "sens " << lar::dump::vector3D({4,5,6}) << ind; }
    template <typename Stream> void printAuxDetGeo(Stream&& out, std::string ind) const {
      out << "auxdet " << lar::dump::vector3D({7,8,9});
      for (int i=0;i<2;++i) { out << "\n" << ind << " [#" << i << "] ";
        printAuxDetSensitiveGeo(std::forward<Stream>(out), ind+"  "); }
    }
    void printAuxiliaryDetectors() const {
      auto log = LAR_LOG_INFO;
      log << "There are 2 auxiliary detectors:";
      for (int i=0;i<2;++i) { log << "\n[#" << i << "] "; printAuxDetGeo(log, "  "); }
    }
    void printWiresInTPC() const { geo::PrintPlaneInfo(LAR_LOG_INFO << "  ", "      ", 8); }
  };
  struct WireReadoutGeom {
    void ChannelsIntersect(int c1) const { LAR_LOG_ERROR << "1st channel " << c1 << " maps to no wire"; }
  };
}

int main() {
  spdlog::set_pattern("%^%l%$: %v");
  spdlog::set_level(spdlog::level::info);   // debug/trace suppressed
  geo::WireReadoutGeom{}.ChannelsIntersect(7);
  geo::GeometryTestAlg t; t.printWiresInTPC(); t.printAuxiliaryDetectors();
  LAR_LOG_DEBUG << "SUPPRESSED debug " << lar::dump::vector3D({0,0,0});
  spdlog::set_level(spdlog::level::trace);
  LAR_LOG_DEBUG << "now visible debug " << lar::dump::vector3D({0,0,0});
  if (LAR_LOG_TRACE) spdlog::info("trace is enabled (isDebugEnabled equivalent)");
  LAR_LOG_INFO << "endl test" << std::endl;
  LAR_LOG_INFO << "braces { 0; 0; 0 } {} literal";
  return 0;
}
