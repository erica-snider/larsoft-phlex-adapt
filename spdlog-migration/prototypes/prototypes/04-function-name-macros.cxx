#include <cstdio>
#include <string>
#include <string_view>

namespace geo {
  class WireReadoutGeom {
  public:
    void ChannelsIntersect(int) const {
      printf("__func__            = %s\n", __func__);
      printf("__FUNCTION__        = %s\n", __FUNCTION__);
      printf("__PRETTY_FUNCTION__ = %s\n", __PRETTY_FUNCTION__);
    }
    template <typename T>
    void tmpl(T) const { printf("tmpl __PRETTY_FUNCTION__ = %s\n", __PRETTY_FUNCTION__); }
  };
  void freeFunc() { printf("free __PRETTY_FUNCTION__ = %s\n", __PRETTY_FUNCTION__); }
}
int main() {
  geo::WireReadoutGeom g;
  g.ChannelsIntersect(1);
  g.tmpl(3.5);
  geo::freeFunc();
}
