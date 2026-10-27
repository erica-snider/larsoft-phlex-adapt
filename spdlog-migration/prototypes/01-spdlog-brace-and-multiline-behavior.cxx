#define SPDLOG_HEADER_ONLY 1
#include "spdlog/spdlog.h"
#include "spdlog/sinks/stdout_sinks.h"
#include <string>
#include <sstream>

int main() {
  spdlog::set_pattern("%^%l%$: %v");
  // Case 1: std::string containing braces (like lar::dump output "{ 0; 0; 0 }")
  std::string s = "geo::WireGeo::GetCenter: center is { 1; 2; 3 }";
  try { spdlog::info(s); } catch (std::exception const& e) { printf("CASE1 THREW: %s\n", e.what()); }
  // Case 2: const char* literal with braces
  try { spdlog::info("literal braces { 0; 0; 0 }"); } catch (std::exception const& e) { printf("CASE2 THREW: %s\n", e.what()); }
  // Case 3: explicit "{}" form
  try { spdlog::info("{}", s); } catch (std::exception const& e) { printf("CASE3 THREW: %s\n", e.what()); }
  // Case 4: multi-line message
  spdlog::info("{}", std::string("line1\nline2\nline3"));
  // Case 5: should_log
  printf("should_log(debug)=%d should_log(info)=%d\n", (int)spdlog::should_log(spdlog::level::debug), (int)spdlog::should_log(spdlog::level::info));
  return 0;
}
