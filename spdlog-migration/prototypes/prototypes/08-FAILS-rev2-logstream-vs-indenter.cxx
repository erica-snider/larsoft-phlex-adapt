#include "spdlog/spdlog.h"
#include <sstream>
#include <string_view>
#include <utility>

// ---- The LogStream EXACTLY as written in SPDLOG_MIGRATION_PLAN.md section 3 ----
namespace lar::log {
  class LogStream {
    std::ostringstream buf_;
    std::string_view where_;
    spdlog::level::level_enum level_;
    bool active_;
  public:
    LogStream(spdlog::level::level_enum level, std::string_view where)
      : where_{where}, level_{level}, active_{spdlog::should_log(level)} {}
    LogStream(LogStream const&) = delete;
    LogStream& operator=(LogStream const&) = delete;
    ~LogStream() {
      if (!active_) return;
      auto const body = buf_.str();
      if (body.empty()) return;
      if (where_.empty()) spdlog::log(level_, "{}", body);
      else                spdlog::log(level_, "{}: {}", where_, body);
    }
    explicit operator bool() const noexcept { return active_; }
    template <typename T> LogStream& operator<<(T const& value) { if (active_) buf_ << value; return *this; }
    LogStream& operator<<(std::ostream& (*m)(std::ostream&)) { if (active_) buf_ << m; return *this; }
  };
}

// ---- Minimal reproduction of dump::DumperBase::Indenter ----
struct DumperBase {
  template <typename Stream>
  class Indenter {
    Stream out;                                  // <-- STORED BY VALUE
    DumperBase const& dumper;
  public:
    Indenter(Stream out, DumperBase const& d) : out(std::forward<Stream>(out)), dumper(d) {}
    template <typename T> Indenter& operator<<(T&& v) { out << std::forward<T>(v); return *this; }
    Indenter& newline() { out << '\n'; return *this; }
  };
  template <typename Stream>
  decltype(auto) indenter(Stream&& out) const { return Indenter<Stream>(std::forward<Stream>(out), *this); }
};

int main() {
  spdlog::set_pattern("%^%l%$: %v");
  DumperBase d;
  // This is `dump(mf::LogVerbatim("dumper"), waveform)` -> Stream deduces to LogStream (by value)
  auto out = d.indenter(lar::log::LogStream(spdlog::level::info, "dump::raw::OpDetWaveformDumper::dump"));
  out << "waveform header";
  out.newline();
  out << "  samples...";
  return 0;
}
