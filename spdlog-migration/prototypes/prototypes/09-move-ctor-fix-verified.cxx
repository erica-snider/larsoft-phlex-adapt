#include "spdlog/spdlog.h"
#include <ios>
#include <ostream>
#include <sstream>
#include <string_view>
#include <utility>

namespace lar::log {
  class LogStream {
    std::ostringstream buf_;
    std::string_view where_;
    spdlog::level::level_enum level_;
    bool active_;
  public:
    LogStream(spdlog::level::level_enum level, std::string_view where)
      : where_{where}, level_{level}, active_{spdlog::should_log(level)} {}

    // MOVE CONSTRUCTOR: transfers the buffer and DISARMS the source so the
    // message is emitted exactly once, by the surviving object.
    LogStream(LogStream&& other)
      : buf_{std::move(other.buf_)}, where_{other.where_}
      , level_{other.level_}, active_{other.active_}
    { other.active_ = false; }

    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;
    LogStream& operator=(LogStream&&) = delete;

    ~LogStream() {
      if (!active_) return;
      auto const body = buf_.str();
      if (body.empty()) return;
      if (where_.empty()) spdlog::log(level_, "{}", body);
      else                spdlog::log(level_, "{}: {}", where_, body);
    }
    explicit operator bool() const noexcept { return active_; }
    template <typename T> LogStream& operator<<(T const& v) { if (active_) buf_ << v; return *this; }
    LogStream& operator<<(std::ostream& (*m)(std::ostream&))  { if (active_) buf_ << m; return *this; }
    LogStream& operator<<(std::ios_base& (*m)(std::ios_base&)) { if (active_) buf_ << m; return *this; }
  };
}

struct DumperBase {
  template <typename Stream>
  class Indenter {
    Stream out;
    DumperBase const& dumper;
  public:
    Indenter(Stream out, DumperBase const& d) : out(std::forward<Stream>(out)), dumper(d) {}
    template <typename T> Indenter& operator<<(T&& v) { out << std::forward<T>(v); return *this; }
    Indenter& newline() { out << '\n'; return *this; }
  };
  template <typename Stream>
  decltype(auto) indenter(Stream&& out) const { return Indenter<Stream>(std::forward<Stream>(out), *this); }
  // the Stream& f(Stream&&) protocol from DumperBase.h:109-131
  template <typename Stream> Stream& indented(Stream&& o, bool) const { o << "  "; return o; }
};

#include <iomanip>
int main() {
  spdlog::set_pattern("%^%l%$: %v");
  DumperBase d;

  // CASE 1: Stream deduces BY VALUE (prvalue arg) -> Indenter<LogStream> owns the log
  {
    auto out = d.indenter(lar::log::LogStream(spdlog::level::info, "dump::raw::OpDetWaveformDumper::dump"));
    out << "OpDetWaveform ch=3 with 6 samples";
    out.newline();
    out << " " << std::setw(4) << 1024 << " " << std::setw(4) << 2048;
  }
  // CASE 2: Stream deduces to LogStream& (lvalue arg) -> Indenter holds a reference
  {
    auto log = lar::log::LogStream(spdlog::level::info, "caller::lvalueForm");
    auto out = d.indenter(log);
    out << "lvalue form works too";
  }
  // CASE 3: std::setw named-object case from DetectorPropertiesStandard_test.cc:161
  {
    auto log = lar::log::LogStream(spdlog::level::info, "main");
    log << std::setw(10) << "Drift:" << " | " << std::setw(9) << "time [us]";
    log << "\n" << std::setw(10) << "TPC0" << " | " << std::setw(9) << 1.5;
  }
  // CASE 4: verify move does NOT duplicate the message
  {
    auto a = lar::log::LogStream(spdlog::level::warn, "moveTest");
    a << "emitted exactly once";
    auto b = std::move(a);
  }
  return 0;
}
