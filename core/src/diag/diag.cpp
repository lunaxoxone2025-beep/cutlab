#include "diag.hpp"

#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <mutex>

extern "C" {
#include <libavutil/log.h>
}

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <psapi.h>
#include <csignal>
#else
#include <dlfcn.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>
#include <unwind.h>
#if defined(__linux__)
#include <sys/prctl.h>
#endif
#endif

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace cutlab::diag {
namespace {

constexpr int kSlots = 64;
constexpr int kSlotSize = 240;
char g_ring[kSlots][kSlotSize];
std::atomic<uint32_t> g_next{0};
std::atomic<int> g_hw_open{0};
const auto g_start = std::chrono::steady_clock::now();

char g_report_path[1024];
char g_device[3072];
std::mutex g_init_mu;
bool g_handler_installed = false;

// Activity log on disk: unbuffered appends, restarted when it grows.
std::mutex g_log_mu;
std::FILE* g_log = nullptr;
long g_log_bytes = 0;
constexpr long kMaxLogBytes = 256 * 1024;

void append_log(const char* line) {
  std::lock_guard<std::mutex> lock(g_log_mu);
  if (!g_log) return;
  if (g_log_bytes > kMaxLogBytes) {
    g_log = std::freopen(nullptr, "w", g_log);  // start over (keeps the file small)
    g_log_bytes = 0;
    if (!g_log) return;
  }
  const int n = std::fprintf(g_log, "%s\n", line);
  std::fflush(g_log);  // into the OS at once: survives the app being killed
  if (n > 0) g_log_bytes += n;
}

uint64_t thread_id() {
#ifdef _WIN32
  return GetCurrentThreadId();
#elif defined(__linux__)
  return static_cast<uint64_t>(syscall(SYS_gettid));
#else
  return 0;
#endif
}

void ffmpeg_log(void* avcl, int level, const char* fmt, va_list vl) {
  if (level > AV_LOG_WARNING) return;
#ifndef __ANDROID__
  va_list copy;
  va_copy(copy, vl);
  av_log_default_callback(avcl, level, fmt, copy);
  va_end(copy);
#endif
  char line[400];
  int prefix = 1;
  av_log_format_line2(avcl, level, fmt, vl, line, sizeof line, &prefix);
  size_t n = std::strlen(line);
  while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = '\0';
  if (n > 0) note("ffmpeg %s: %s", level <= AV_LOG_ERROR ? "error" : "warning", line);
}

// ------------------------------------------------- crash report helpers
// Everything below runs inside a signal handler: no allocation, no stdio.

#ifndef _WIN32
void put(int fd, const char* s) {
  if (!s) return;
  size_t n = std::strlen(s);
  while (n > 0) {
    const ssize_t w = ::write(fd, s, n);
    if (w <= 0) return;
    s += w;
    n -= static_cast<size_t>(w);
  }
}

void put_num(int fd, uint64_t v, bool hex = false) {
  char b[24];
  int i = 23;
  b[i] = '\0';
  const unsigned base = hex ? 16 : 10;
  do {
    const unsigned d = static_cast<unsigned>(v % base);
    b[--i] = static_cast<char>(d < 10 ? '0' + d : 'a' + d - 10);
    v /= base;
  } while (v && i > 2);
  if (hex) {
    b[--i] = 'x';
    b[--i] = '0';
  }
  put(fd, b + i);
}

// Copies the lines of a /proc file that start with one of the prefixes.
void put_proc_lines(int fd, const char* path, const char* const* prefixes, int count) {
  const int in = ::open(path, O_RDONLY | O_CLOEXEC);
  if (in < 0) return;
  char buf[4096];
  const ssize_t n = ::read(in, buf, sizeof buf - 1);
  ::close(in);
  if (n <= 0) return;
  buf[n] = '\0';
  char* line = buf;
  while (line && *line) {
    char* end = std::strchr(line, '\n');
    if (end) *end = '\0';
    for (int i = 0; i < count; ++i) {
      if (std::strncmp(line, prefixes[i], std::strlen(prefixes[i])) == 0) {
        put(fd, "  ");
        put(fd, line);
        put(fd, "\n");
      }
    }
    line = end ? end + 1 : nullptr;
  }
}

void put_frame(int fd, int n, uintptr_t pc) {
  put(fd, "  #");
  if (n < 10) put(fd, "0");
  put_num(fd, static_cast<uint64_t>(n));
  put(fd, " pc ");
  put_num(fd, pc, true);
  Dl_info info{};
  if (dladdr(reinterpret_cast<void*>(pc), &info) && info.dli_fname) {
    const char* base = std::strrchr(info.dli_fname, '/');
    put(fd, "  ");
    put(fd, base ? base + 1 : info.dli_fname);
    put(fd, " +");
    put_num(fd, pc - reinterpret_cast<uintptr_t>(info.dli_fbase), true);
    if (info.dli_sname) {
      put(fd, " (");
      put(fd, info.dli_sname);
      put(fd, "+");
      put_num(fd, pc - reinterpret_cast<uintptr_t>(info.dli_saddr), true);
      put(fd, ")");
    }
  }
  put(fd, "\n");
}

struct Unwind {
  int fd;
  int n;
};

_Unwind_Reason_Code unwind_frame(_Unwind_Context* ctx, void* arg) {
  auto* u = static_cast<Unwind*>(arg);
  const uintptr_t pc = _Unwind_GetIP(ctx);
  if (pc == 0) return _URC_END_OF_STACK;
  put_frame(u->fd, u->n++, pc);
  return u->n >= 40 ? _URC_END_OF_STACK : _URC_NO_REASON;
}

const char* signal_name(int sig) {
  switch (sig) {
    case SIGSEGV: return "SIGSEGV (invalid memory access)";
    case SIGBUS: return "SIGBUS (bus error)";
    case SIGFPE: return "SIGFPE (arithmetic error)";
    case SIGILL: return "SIGILL (illegal instruction)";
    case SIGABRT: return "SIGABRT (abort)";
    case SIGTRAP: return "SIGTRAP (trap)";
    default: return "signal";
  }
}

const int kSignals[] = {SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGABRT, SIGTRAP};
struct sigaction g_old[65];
std::atomic<int> g_in_handler{0};

void crash_handler(int sig, siginfo_t* info, void* ucv) {
  if (g_in_handler.exchange(1) == 0 && g_report_path[0]) {
    const int fd = ::open(g_report_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
      put(fd, "CUTLAB native crash report\n");
      put(fd, "time (unix): ");
      put_num(fd, static_cast<uint64_t>(std::time(nullptr)));
      put(fd, "\nsignal: ");
      put(fd, signal_name(sig));
      put(fd, " [");
      put_num(fd, static_cast<uint64_t>(sig));
      put(fd, "] code ");
      if (info && info->si_code < 0) put(fd, "-");
      put_num(fd, info ? static_cast<uint64_t>(info->si_code < 0 ? -info->si_code : info->si_code) : 0);
      put(fd, " fault address ");
      put_num(fd, info ? reinterpret_cast<uintptr_t>(info->si_addr) : 0, true);
      put(fd, "\nthread: ");
      put_num(fd, thread_id());
#if defined(__linux__)
      char name[32] = {0};
      if (prctl(PR_GET_NAME, name, 0, 0, 0) == 0) {
        put(fd, " \"");
        put(fd, name);
        put(fd, "\"");
      }
#endif
      put(fd, "\nhardware decoders open: ");
      put_num(fd, static_cast<uint64_t>(g_hw_open.load()));
      put(fd, "\n\ndevice:\n");
      put(fd, g_device);
      put(fd, "\n\nmemory:\n");
      static const char* const kStatus[] = {"VmRSS:", "VmHWM:", "VmSize:", "Threads:"};
      put_proc_lines(fd, "/proc/self/status", kStatus, 4);
      static const char* const kMem[] = {"MemTotal:", "MemAvailable:"};
      put_proc_lines(fd, "/proc/meminfo", kMem, 2);

      put(fd, "\nregisters:\n");
      if (ucv) {
        const auto* uc = static_cast<const ucontext_t*>(ucv);
#if defined(__aarch64__)
        put(fd, "  pc ");
        put_num(fd, uc->uc_mcontext.pc, true);
        put(fd, "  lr ");
        put_num(fd, uc->uc_mcontext.regs[30], true);
        put(fd, "  sp ");
        put_num(fd, uc->uc_mcontext.sp, true);
        put(fd, "\n");
        put_frame(fd, 0, static_cast<uintptr_t>(uc->uc_mcontext.pc));
        put_frame(fd, 1, static_cast<uintptr_t>(uc->uc_mcontext.regs[30]));
#elif defined(__x86_64__)
        put(fd, "  rip ");
        put_num(fd, static_cast<uint64_t>(uc->uc_mcontext.gregs[REG_RIP]), true);
        put(fd, "  rsp ");
        put_num(fd, static_cast<uint64_t>(uc->uc_mcontext.gregs[REG_RSP]), true);
        put(fd, "\n");
        put_frame(fd, 0, static_cast<uintptr_t>(uc->uc_mcontext.gregs[REG_RIP]));
#endif
      }
      put(fd, "\nbacktrace:\n");
      Unwind u{fd, 0};
      _Unwind_Backtrace(&unwind_frame, &u);

      put(fd, "\nrecent engine activity (oldest first):\n");
      const uint32_t next = g_next.load();
      for (uint32_t i = next > kSlots ? next - kSlots : 0; i < next; ++i) {
        put(fd, "  ");
        put(fd, g_ring[i % kSlots]);
        put(fd, "\n");
      }
      ::close(fd);
    }
  }
  // Hand the signal to whoever had it before (the system's crash reporter),
  // so the normal tombstone / crash dialog still happens.
  sigaction(sig, &g_old[sig], nullptr);
  if (!info || info->si_code <= 0 || sig == SIGABRT) {
#if defined(__linux__)
    syscall(SYS_tgkill, getpid(), static_cast<pid_t>(thread_id()), sig);
#else
    raise(sig);
#endif
  }
  // A hardware fault re-executes the instruction and reaches the old handler.
}

void install_handler() {
  for (const int sig : kSignals) {
    struct sigaction sa {};
    sa.sa_sigaction = &crash_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(sig, &sa, &g_old[sig]);
  }
}
#else  // _WIN32

void put(HANDLE h, const char* s) {
  if (!s) return;
  DWORD w = 0;
  WriteFile(h, s, static_cast<DWORD>(std::strlen(s)), &w, nullptr);
}

void write_windows_report(const char* what, uint64_t code, const void* address) {
  HANDLE h = CreateFileA(g_report_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return;
  char line[600];
  std::snprintf(line, sizeof line, "CUTLAB native crash report\ntime (unix): %lld\nexception: %s code 0x%llx address %p\nthread: %lu\n",
                static_cast<long long>(std::time(nullptr)), what, static_cast<unsigned long long>(code), address,
                static_cast<unsigned long>(GetCurrentThreadId()));
  put(h, line);
  HMODULE mod = nullptr;
  if (address && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                    static_cast<LPCSTR>(address), &mod)) {
    char path[MAX_PATH] = {0};
    GetModuleFileNameA(mod, path, MAX_PATH);
    std::snprintf(line, sizeof line, "module: %s +0x%llx\n", path,
                  static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(address) - reinterpret_cast<uintptr_t>(mod)));
    put(h, line);
  }
  std::snprintf(line, sizeof line, "hardware decoders open: %d\n\ndevice:\n", g_hw_open.load());
  put(h, line);
  put(h, g_device);
  PROCESS_MEMORY_COUNTERS pmc{};
  if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) {
    std::snprintf(line, sizeof line, "\n\nmemory:\n  working set %llu KiB, peak %llu KiB\n",
                  static_cast<unsigned long long>(pmc.WorkingSetSize / 1024), static_cast<unsigned long long>(pmc.PeakWorkingSetSize / 1024));
    put(h, line);
  }
  put(h, "\nrecent engine activity (oldest first):\n");
  const uint32_t next = g_next.load();
  for (uint32_t i = next > kSlots ? next - kSlots : 0; i < next; ++i) {
    put(h, "  ");
    put(h, g_ring[i % kSlots]);
    put(h, "\n");
  }
  CloseHandle(h);
}

LPTOP_LEVEL_EXCEPTION_FILTER g_prev_filter = nullptr;

LONG WINAPI windows_filter(EXCEPTION_POINTERS* ep) {
  static std::atomic<int> once{0};
  if (once.exchange(1) == 0 && g_report_path[0] && ep && ep->ExceptionRecord) {
    write_windows_report("unhandled exception", ep->ExceptionRecord->ExceptionCode, ep->ExceptionRecord->ExceptionAddress);
  }
  return g_prev_filter ? g_prev_filter(ep) : EXCEPTION_CONTINUE_SEARCH;
}

void windows_abort(int) {
  if (g_report_path[0]) write_windows_report("abort", 0, nullptr);
  std::signal(SIGABRT, SIG_DFL);
  std::abort();
}

void install_handler() {
  g_prev_filter = SetUnhandledExceptionFilter(&windows_filter);
  std::signal(SIGABRT, &windows_abort);
}
#endif

}  // namespace

void note(const char* fmt, ...) {
  char msg[kSlotSize - 32];
  va_list ap;
  va_start(ap, fmt);
  std::vsnprintf(msg, sizeof msg, fmt, ap);
  va_end(ap);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - g_start).count();
  const uint32_t slot = g_next.fetch_add(1) % kSlots;
  std::snprintf(g_ring[slot], kSlotSize, "[%7lld.%03lld t%llu] %s", static_cast<long long>(ms / 1000), static_cast<long long>(ms % 1000),
                static_cast<unsigned long long>(thread_id() % 100000), msg);
  append_log(g_ring[slot]);
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_INFO, "cutlab", "%s", msg);
#endif
}

std::string recent() {
  std::string out;
  const uint32_t next = g_next.load();
  for (uint32_t i = next > kSlots ? next - kSlots : 0; i < next; ++i) {
    out += g_ring[i % kSlots];
    out += '\n';
  }
  return out;
}

void memory_kib(int64_t* rss, int64_t* peak) {
  *rss = 0;
  *peak = 0;
#ifdef _WIN32
  PROCESS_MEMORY_COUNTERS pmc{};
  if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc)) {
    *rss = static_cast<int64_t>(pmc.WorkingSetSize / 1024);
    *peak = static_cast<int64_t>(pmc.PeakWorkingSetSize / 1024);
  }
#else
  FILE* f = std::fopen("/proc/self/status", "r");
  if (!f) return;
  char line[256];
  while (std::fgets(line, sizeof line, f)) {
    if (std::strncmp(line, "VmRSS:", 6) == 0) *rss = std::atoll(line + 6);
    if (std::strncmp(line, "VmHWM:", 6) == 0) *peak = std::atoll(line + 6);
  }
  std::fclose(f);
#endif
}

void hardware_decoder_opened() { ++g_hw_open; }
void hardware_decoder_closed() { --g_hw_open; }
int hardware_decoders_open() { return g_hw_open.load(); }

void capture_ffmpeg_log() { av_log_set_callback(&ffmpeg_log); }

void init(const std::string& dir, const std::string& device_info) {
  std::lock_guard<std::mutex> lock(g_init_mu);
  std::string path = dir;
  if (!path.empty() && path.back() != '/' && path.back() != '\\') path += '/';
  path += "native-crash.txt";
  std::snprintf(g_report_path, sizeof g_report_path, "%s", dir.empty() ? "" : path.c_str());
  std::snprintf(g_device, sizeof g_device, "%s", device_info.c_str());
  capture_ffmpeg_log();
  if (!dir.empty()) {
    std::lock_guard<std::mutex> log_lock(g_log_mu);
    if (!g_log) {
      std::string base = dir;
      if (base.back() != '/' && base.back() != '\\') base += '/';
      const std::string current = base + "engine-activity.log";
      const std::string previous = base + "engine-activity-previous.log";
      std::remove(previous.c_str());
      std::rename(current.c_str(), previous.c_str());
      g_log = std::fopen(current.c_str(), "w");
      g_log_bytes = 0;
    }
  }
  if (!g_handler_installed && !dir.empty()) {
    install_handler();
    g_handler_installed = true;
  }
  note("diagnostics ready (crash reports in %s)", dir.c_str());
}

}  // namespace cutlab::diag
