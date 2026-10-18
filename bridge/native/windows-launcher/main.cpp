// Launch codeaw's background processes directly, without a system-process broker.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>

namespace {
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE handle) : value(handle) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};

void write(HANDLE handle, const std::string& text) {
  DWORD written;
  if (handle && handle != INVALID_HANDLE_VALUE) WriteFile(handle, text.data(), static_cast<DWORD>(text.size()), &written, nullptr);
}

// Quote for the Windows argv parser. No arguments are interpreted by a shell.
std::wstring quote(const std::wstring& value) {
  std::wstring out = L"\"";
  size_t slashes = 0;
  for (wchar_t character : value) {
    if (character == L'\\') { ++slashes; continue; }
    out.append(slashes * (character == L'\"' ? 2 : 1), L'\\');
    slashes = 0;
    if (character == L'\"') out += L'\\';
    out += character;
  }
  out.append(slashes * 2, L'\\');
  return out + L'\"';
}

int fail(const char* stage, DWORD code, HANDLE log = INVALID_HANDLE_VALUE) {
  // Fixed operation names and numeric codes only; never reproduce arguments or env.
  write(log, "[launcher] " + std::string(stage) + " failed (Windows error " + std::to_string(code) + ").\r\n");
  write(GetStdHandle(STD_OUTPUT_HANDLE), "{\"error\":\"" + std::string(stage) + "\",\"code\":" + std::to_string(code) + "}\n");
  return 1;
}

int launch(int argc, wchar_t** argv) {
  // --launch <working directory> <log file> <absolute executable> [arguments...]
  if (argc < 5 || std::wstring(argv[1]) != L"--launch") return fail("arguments", ERROR_INVALID_PARAMETER);
  const std::wstring executable = argv[4];
  if (!(executable.size() > 2 && executable[1] == L':' && (executable[2] == L'\\' || executable[2] == L'/')) &&
      executable.rfind(L"\\\\", 0) != 0) return fail("executable_path", ERROR_BAD_PATHNAME);

  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  Handle log(CreateFileW(argv[3], FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    &security, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
  if (log.value == INVALID_HANDLE_VALUE) return fail("open_log", GetLastError());
  Handle input(CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_EXISTING, 0, nullptr));
  if (input.value == INVALID_HANDLE_VALUE) return fail("open_stdin", GetLastError(), log.value);

  SIZE_T size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<unsigned char> storage(size);
  auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  if (!InitializeProcThreadAttributeList(attributes, 1, 0, &size)) return fail("initialize_handles", GetLastError(), log.value);
  struct Attributes { LPPROC_THREAD_ATTRIBUTE_LIST value; ~Attributes() { DeleteProcThreadAttributeList(value); } } cleanup{attributes};
  HANDLE handles[] = {input.value, log.value};
  if (!UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, sizeof(handles), nullptr, nullptr)) {
    return fail("inherit_handles", GetLastError(), log.value);
  }

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  startup.StartupInfo.wShowWindow = SW_HIDE;
  startup.StartupInfo.hStdInput = input.value;
  startup.StartupInfo.hStdOutput = startup.StartupInfo.hStdError = log.value;
  startup.lpAttributeList = attributes;
  std::wstring command;
  for (int i = 4; i < argc; ++i) { if (i != 4) command += L' '; command += quote(argv[i]); }
  PROCESS_INFORMATION child{};
  // Request independent lifetime using the documented job flags. If Windows
  // refuses, report the error instead of falling back to a system-process broker.
  if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB,
      nullptr, argv[2], &startup.StartupInfo, &child)) return fail("create_process", GetLastError(), log.value);
  Handle process(child.hProcess), thread(child.hThread);
  write(GetStdHandle(STD_OUTPUT_HANDLE), "{\"pid\":" + std::to_string(child.dwProcessId) + "}\n");
  return 0;
}
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
  int argc = 0;
  auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return fail("arguments", GetLastError());
  int result;
  try { result = launch(argc, argv); }
  catch (...) { result = fail("launcher", ERROR_UNHANDLED_EXCEPTION); }
  LocalFree(argv);
  return result;
}
