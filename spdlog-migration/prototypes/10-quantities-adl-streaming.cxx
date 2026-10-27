#include "spdlog/spdlog.h"
#include <ostream>
#include <sstream>
#include <string_view>
#include <utility>
#include <iomanip>

namespace lar::log {
  class LogStream {
    std::ostringstream buf_;
    std::string_view where_;
    spdlog::level::level_enum level_;
    bool active_;
  public:
    LogStream(spdlog::level::level_enum l, std::string_view w)
      : where_{w}, level_{l}, active_{spdlog::should_log(l)} {}
    LogStream(LogStream&& o)
      : buf_{std::move(o.buf_)}, where_{o.where_}, level_{o.level_}, active_{o.active_}
    { o.active_ = false; }
    LogStream(LogStream const&) = delete;
    ~LogStream() {
      if (!active_) return;
      auto const b = buf_.str();
      if (b.empty()) return;
      if (where_.empty()) spdlog::log(level_, "{}", b);
      else spdlog::log(level_, "{}: {}", where_, b);
    }
    template <typename T> LogStream& operator<<(T const& v) { if (active_) buf_ << v; return *this; }
    LogStream& operator<<(std::ostream& (*m)(std::ostream&)) { if (active_) buf_ << m; return *this; }
    LogStream& operator<<(std::ios_base& (*m)(std::ios_base&)) { if (active_) buf_ << m; return *this; }
  };
}

// Mimic lardataalg's quantities: operator<< is std::ostream-ONLY, found by ADL.
namespace util::quantities::concepts {
  template <typename U> struct ScaledUnit { static const char* symbol() { return "us"; } };
  template <typename... Args> struct Quantity {
    double v;
    double value() const { return v; }
    ScaledUnit<int> unit() const { return {}; }
  };
  template <typename U>
  std::ostream& operator<<(std::ostream& out, ScaledUnit<U> const&) { return out << "us"; }
  template <typename... Args>
  std::ostream& operator<<(std::ostream& out, Quantity<Args...> const q) {
    return out << q.value() << " " << q.unit();
  }
  template <typename... Args> struct Point { Quantity<Args...> q; Quantity<Args...> quantity() const { return q; } };
  template <typename... Args>
  std::ostream& operator<<(std::ostream& out, Point<Args...> const p) { return out << p.quantity(); }
}

int main() {
  spdlog::set_pattern("%^%l%$: %v");
  using Q = util::quantities::concepts::Quantity<int>;
  using P = util::quantities::concepts::Point<int>;
  Q time{4.5};
  P trigger{Q{1.25}};
  // This is DetectorTimingsStandard_test.cc:83 shape
  lar::log::LogStream(spdlog::level::info, "testTriggerTime")
    << "DetectorTimings::TriggerTime() => " << time;
  lar::log::LogStream(spdlog::level::err, "testTriggerTime")
    << "Trigger time expected to be " << 4.5 << " us, but got " << trigger << " instead";
  return 0;
}
