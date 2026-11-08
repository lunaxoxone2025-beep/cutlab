// Checks the native crash handler: a child process installs it, records
// some engine activity and crashes (invalid memory access, then abort);
// the parent checks the report it left behind and that the process still
// ended with the original signal (so Android's own crash handling runs).
// POSIX only (Linux, Android).
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "cutlab/cutlab_core.h"

namespace {

int g_failures = 0;

void check(bool ok, const std::string& what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
  if (!ok) ++g_failures;
}

std::string read_file(const std::string& path) {
  std::ifstream f(path);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

[[gnu::noinline]] void crash_null_write() {
  volatile int* p = nullptr;
  *p = 42;  // NOLINT: deliberate crash
}

void run(const std::string& dir, int expected_signal, void (*crash)()) {
  const std::string report = dir + "/native-crash.txt";
  std::remove(report.c_str());
  const pid_t pid = fork();
  if (pid == 0) {
    if (cutlab_diag_init(dir.c_str(), "test device: CI runner") != CUTLAB_OK) _exit(3);
    cutlab_diag_note("decoder h264_mediacodec h264 1920x1080 8-bit threads=1 hw=1 (test)");
    cutlab_diag_note("player open fd:42 (test)");
    crash();
    _exit(0);  // not reached
  }
  int status = 0;
  waitpid(pid, &status, 0);
  check(WIFSIGNALED(status) && WTERMSIG(status) == expected_signal,
        "child ended with signal " + std::to_string(expected_signal) + " (status " + std::to_string(status) + ")");
  const std::string text = read_file(report);
  check(!text.empty(), "report written");
  check(text.find("CUTLAB native crash report") != std::string::npos, "report header");
  check(text.find(expected_signal == SIGSEGV ? "SIGSEGV" : "SIGABRT") != std::string::npos, "signal named");
  check(text.find("test device: CI runner") != std::string::npos, "device info included");
  check(text.find("VmRSS") != std::string::npos, "memory figures included");
  check(text.find("backtrace:") != std::string::npos && text.find("#00") != std::string::npos, "backtrace included");
  check(text.find("player open fd:42 (test)") != std::string::npos, "recent engine activity included");
  check(text.find("hardware decoders open: 0") != std::string::npos, "hardware decoder count included");
  // The activity log on disk survives the crash (and a kill, which has no report).
  const std::string log = read_file(dir + "/engine-activity.log");
  check(log.find("player open fd:42 (test)") != std::string::npos, "activity log on disk survives the crash");
  if (g_failures) std::printf("--- report ---\n%s\n", text.c_str());
}

}  // namespace

int main(int argc, char** argv) {
  std::string dir = argc > 1 ? argv[1] : "crash-report-test";
  mkdir(dir.c_str(), 0755);
  run(dir, SIGSEGV, &crash_null_write);
  run(dir, SIGABRT, [] { std::abort(); });
  std::printf("%d failures\n", g_failures);
  return g_failures ? 1 : 0;
}
