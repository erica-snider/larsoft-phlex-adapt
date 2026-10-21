#include "spdlog/spdlog.h"
#include <string>
int main() {
  spdlog::set_pattern("%^%l%$: %v");
  std::string s = "{ 1; 2; 3 }";
  // DANGEROUS: runtime string used as format string with args
  try { spdlog::info(s + " and {}", 42); }
  catch (std::exception const& e) { printf("CASE-A THREW: %s\n", e.what()); }
  // SAFE: explicit {} placeholders
  spdlog::info("{} and {}", s, 42);
  return 0;
}
