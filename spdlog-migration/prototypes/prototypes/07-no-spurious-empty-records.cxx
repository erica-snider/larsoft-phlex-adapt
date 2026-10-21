#include "spdlog/spdlog.h"
#include <sstream>
#include <string>
#include <string_view>
#include <utility>

namespace lar::log {
  class LogStream {
    std::ostringstream buf_;
    std::string_view where_;
    spdlog::level::level_enum lvl_;
    bool active_;
  public:
    LogStream(spdlog::level::level_enum lvl, std::string_view where)
      : where_(where), lvl_(lvl), active_(spdlog::should_log(lvl)) {}
    LogStream(LogStream const&) = delete;
    ~LogStream() {
      if (!active_) return;
      auto body = buf_.str();
      if (body.empty()) return;                    // nothing streamed -> no record
      if (where_.empty()) spdlog::log(lvl_, "{}", body);
      else spdlog::log(lvl_, "{}: {}", where_, body);
    }
    template <typename T> LogStream& operator<<(T const& v) { if (active_) buf_ << v; return *this; }
    LogStream& operator<<(std::ostream& (*m)(std::ostream&)) { if (active_) buf_ << m; return *this; }
  };
  inline bool enabled(spdlog::level::level_enum l) { return spdlog::should_log(l); }
}
#define LAR_LOG_TRACE ::lar::log::LogStream(spdlog::level::trace, "here")
int main() {
  spdlog::set_pattern("%^%l%$: %v");
  spdlog::set_level(spdlog::level::trace);
  if (lar::log::enabled(spdlog::level::trace)) spdlog::info("trace enabled - no spurious record above");
  { LAR_LOG_TRACE; }                       // constructed but never streamed
  LAR_LOG_TRACE << "real content";
  return 0;
}
