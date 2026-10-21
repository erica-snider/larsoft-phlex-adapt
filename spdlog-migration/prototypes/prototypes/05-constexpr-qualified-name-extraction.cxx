#include <cstdio>
#include <string_view>
#include <array>

namespace lar::log::detail {
  // Extract "ns::Class::method" from __PRETTY_FUNCTION__ at compile time.
  constexpr std::string_view qualifiedName(std::string_view pretty)
  {
    // strip template argument suffix " [with ...]"
    if (auto b = pretty.find(" [with "); b != std::string_view::npos) pretty.remove_suffix(pretty.size() - b);
    // find the '(' that opens the parameter list, skipping any earlier '(' (e.g. in return type)
    std::size_t depth = 0, paren = std::string_view::npos;
    for (std::size_t i = pretty.size(); i-- > 0;) {
      char c = pretty[i];
      if (c == ')') ++depth;
      else if (c == '(') { if (--depth == 0) { paren = i; break; } }
    }
    if (paren == std::string_view::npos) return pretty;
    std::string_view head = pretty.substr(0, paren);
    // walk back from '(' to the start of the qualified name: stop at a space that is
    // not inside <> brackets
    int angle = 0;
    for (std::size_t i = head.size(); i-- > 0;) {
      char c = head[i];
      if (c == '>') ++angle;
      else if (c == '<') --angle;
      else if (c == ' ' && angle == 0) return head.substr(i + 1);
    }
    return head;
  }
}
#define LAR_FUNC (::lar::log::detail::qualifiedName(__PRETTY_FUNCTION__))

namespace geo {
  struct WireReadoutGeom {
    void ChannelsIntersect(int) const { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); }
    std::string_view name() const { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); return {}; }
    template <typename T> void tmpl(T) const { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); }
    WireReadoutGeom() { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); }
  };
  void freeFunc() { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); }
  const std::pair<int,int>* weird(int) { printf("[%.*s]\n", (int)LAR_FUNC.size(), LAR_FUNC.data()); return nullptr; }
}
int main() {
  geo::WireReadoutGeom g;
  g.ChannelsIntersect(1); g.name(); g.tmpl(3.5); geo::freeFunc(); geo::weird(0);
  static_assert(lar::log::detail::qualifiedName("void geo::A::f(int) const") == "geo::A::f");
}
