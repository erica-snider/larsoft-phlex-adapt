// Verify the where_ std::string_view lifetime is safe when the LogStream is
// MOVED into an Indenter that outlives the enclosing full-expression.
#include "spdlog/spdlog.h"
#include <ostream>
#include <sstream>
#include <string_view>
#include <utility>

namespace lar::log {
  namespace detail {
    constexpr std::string_view qualifiedName(std::string_view p) {
      if (auto b = p.find(" [with "); b != std::string_view::npos) p.remove_suffix(p.size()-b);
      std::size_t d=0, paren=std::string_view::npos;
      for (std::size_t i=p.size(); i-->0;) { char c=p[i];
        if (c==')') ++d; else if (c=='(' && --d==0) { paren=i; break; } }
      if (paren==std::string_view::npos) return p;
      std::string_view h = p.substr(0,paren); int a=0;
      for (std::size_t i=h.size(); i-->0;) { char c=h[i];
        if (c=='>') ++a; else if (c=='<') --a; else if (c==' ' && a==0) return h.substr(i+1); }
      return h;
    }
  }
  class LogStream {
    std::ostringstream buf_; std::string_view where_;
    spdlog::level::level_enum level_; bool active_;
  public:
    LogStream(spdlog::level::level_enum l, std::string_view w)
      : where_{w}, level_{l}, active_{spdlog::should_log(l)} {}
    LogStream(LogStream&& o) : buf_{std::move(o.buf_)}, where_{o.where_}, level_{o.level_}, active_{o.active_} { o.active_=false; }
    LogStream(LogStream const&) = delete;
    ~LogStream() { if(!active_) return; auto b=buf_.str(); if(b.empty()) return;
      if(where_.empty()) spdlog::log(level_,"{}",b); else spdlog::log(level_,"{}: {}",where_,b); }
    template <typename T> LogStream& operator<<(T const& v){ if(active_) buf_<<v; return *this; }
  };
}
#define LAR_LOG_WHERE_ (::lar::log::detail::qualifiedName(__PRETTY_FUNCTION__))
#define LAR_LOG_INFO ::lar::log::LogStream(::spdlog::level::info, LAR_LOG_WHERE_)

struct DumperBase {
  template <typename Stream> class Indenter {
    Stream out; DumperBase const& d;
  public:
    Indenter(Stream o, DumperBase const& dd) : out(std::forward<Stream>(o)), d(dd) {}
    template <typename T> Indenter& operator<<(T&& v){ out<<std::forward<T>(v); return *this; }
    Indenter& newline(){ out<<'\n'; return *this; }
  };
  template <typename Stream> decltype(auto) indenter(Stream&& o) const { return Indenter<Stream>(std::forward<Stream>(o), *this); }
};

struct OpDetWaveformDumper : DumperBase {
  template <typename Stream> void dump(Stream&& s) {
    auto out = indenter(std::forward<Stream>(s));   // log moved in here
    out << "on channel #3";
    out.newline(); out << "  1024 2048";
    // 'out' (and the moved-in LogStream) destroyed at end of THIS function,
    // long after the caller's full-expression ended.
  }
  template <typename Stream> void operator()(Stream&& s) { dump(s); }
};

int caller() {
  OpDetWaveformDumper d;
  d.dump(LAR_LOG_INFO);        // prvalue -> Stream = LogStream (by value)
  d(LAR_LOG_INFO);             // via operator() -> Stream& (reference)
  return 0;
}
int main() { spdlog::set_pattern("%^%l%$: %v"); return caller(); }
