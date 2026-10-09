#include "desktop.h"
#include <wtsapi32.h>
#include <userenv.h>
#include <sddl.h>
#include <aclapi.h>
#include <sas.h>
#include <fstream>
#include <filesystem>
#include <iostream>

struct Handle {
  HANDLE value = nullptr; Handle() = default; explicit Handle(HANDLE h) : value(h) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
  Handle(const Handle&) = delete; Handle& operator=(const Handle&) = delete;
  operator HANDLE() const { return value; }
};
static bool systemToken(HANDLE token) {
  BYTE sid[SECURITY_MAX_SID_SIZE]; DWORD size = sizeof(sid); CreateWellKnownSid(WinLocalSystemSid, nullptr, sid, &size);
  DWORD n = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &n); std::vector<BYTE> data(n);
  return GetTokenInformation(token, TokenUser, data.data(), n, &n) && EqualSid(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, sid);
}
static void copy(HANDLE source, HANDLE target) {
  char buffer[16 * 1024]; DWORD n;
  while (ReadFile(source, buffer, sizeof(buffer), &n, nullptr) && n) {
    DWORD offset = 0; while (offset < n) { DWORD sent = 0; if (!WriteFile(target, buffer + offset, n - offset, &sent, nullptr) || !sent) return; offset += sent; }
    SecureZeroMemory(buffer, n);
  }
}
static void tunnelCopy(HANDLE source, HANDLE target, bool asyncRead, bool asyncWrite) {
  Handle event(CreateEventW(nullptr, TRUE, FALSE, nullptr));
  char buffer[16 * 1024];
  for (;;) {
    DWORD n = 0; OVERLAPPED read{}; read.hEvent = event;
    ResetEvent(event);
    BOOL ok = ReadFile(source, buffer, sizeof(buffer), &n, asyncRead ? &read : nullptr);
    if (!ok && asyncRead && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(source, &read, &n, TRUE);
    if (!ok || !n) break;
    DWORD offset = 0;
    while (offset < n) {
      DWORD sent = 0; OVERLAPPED write{}; write.hEvent = event; ResetEvent(event);
      ok = WriteFile(target, buffer + offset, n - offset, &sent, asyncWrite ? &write : nullptr);
      if (!ok && asyncWrite && GetLastError() == ERROR_IO_PENDING) ok = GetOverlappedResult(target, &write, &sent, TRUE);
      if (!ok || !sent) { SecureZeroMemory(buffer, sizeof(buffer)); return; }
      offset += sent;
    }
    SecureZeroMemory(buffer, n);
  }
  SecureZeroMemory(buffer, sizeof(buffer));
}
int pipeTunnel(const std::wstring& pipe, const std::wstring& owner) {
  if (pipe.rfind(L"\\\\.\\pipe\\codeaw-backend-", 0) != 0 || owner.rfind(L"S-1-", 0) != 0) return 1;
  Handle connection(CreateFileW(pipe.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr));
  if (connection.value == INVALID_HANDLE_VALUE) return 1;
  ULONG serverPid = 0; if (!GetNamedPipeServerProcessId(connection, &serverPid)) return 1;
  Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, serverPid)), token;
  if (!process.value || !OpenProcessToken(process, TOKEN_QUERY, &token.value)) return 1;
  DWORD bytes = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &bytes); std::vector<BYTE> user(bytes);
  if (!GetTokenInformation(token, TokenUser, user.data(), bytes, &bytes)) return 1;
  PSID expected = nullptr; if (!ConvertStringSidToSidW(owner.c_str(), &expected)) return 1;
  bool matches = EqualSid(expected, reinterpret_cast<TOKEN_USER*>(user.data())->User.Sid) != FALSE; LocalFree(expected);
  if (!matches) return 1;
  // Identity is checked on this exact pipe handle before any bearer token crosses it.
  std::cerr << "READY\n" << std::flush;
  std::thread sender([&] { tunnelCopy(GetStdHandle(STD_INPUT_HANDLE), connection, false, true); CancelIoEx(connection, nullptr); });
  tunnelCopy(connection, GetStdHandle(STD_OUTPUT_HANDLE), true, false);
  CancelIoEx(connection, nullptr); CancelSynchronousIo(sender.native_handle()); sender.join(); return 0;
}
int broker(const std::wstring& privilege) {
  Handle selfToken; if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY | TOKEN_DUPLICATE | TOKEN_ADJUST_SESSIONID, &selfToken.value) || !systemToken(selfToken)) return 1;
  DWORD session = WTSGetActiveConsoleSessionId(); if (session == 0xFFFFFFFF || session == 0) return 1;
  Handle token;
  if (privilege == L"user") { if (!WTSQueryUserToken(session, &token.value)) return 1; }
  else if (privilege == L"system") {
    if (!DuplicateTokenEx(selfToken, TOKEN_ALL_ACCESS, nullptr, SecurityImpersonation, TokenPrimary, &token.value)
      || !SetTokenInformation(token, TokenSessionId, &session, sizeof(session))) return 1;
  } else return 1;
  SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE}; Handle inputRead, inputWrite, outputRead, outputWrite;
  if (!CreatePipe(&inputRead.value, &inputWrite.value, &sa, 0) || !CreatePipe(&outputRead.value, &outputWrite.value, &sa, 0)) return 1;
  SetHandleInformation(inputWrite, HANDLE_FLAG_INHERIT, 0); SetHandleInformation(outputRead, HANDLE_FLAG_INHERIT, 0);
  Handle null(CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, nullptr));
  STARTUPINFOEXW startup{}; startup.StartupInfo.cb = sizeof(startup); startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = inputRead; startup.StartupInfo.hStdOutput = outputWrite; startup.StartupInfo.hStdError = null;
  startup.StartupInfo.lpDesktop = const_cast<wchar_t*>(L"winsta0\\default");
  SIZE_T attrSize = 0; InitializeProcThreadAttributeList(nullptr, 1, 0, &attrSize); std::vector<BYTE> attrs(attrSize);
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attrs.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attrSize)) return 1;
  HANDLE inherited[] = {inputRead, outputWrite, null};
  if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited), nullptr, nullptr)) return 1;
  wchar_t executable[32768]; GetModuleFileNameW(nullptr, executable, 32768); std::wstring command = L"\"" + std::wstring(executable) + L"\" --worker";
  void* environment = nullptr; if (!CreateEnvironmentBlock(&environment, token, FALSE)) return 1;
  PROCESS_INFORMATION pi{}; BOOL ok = CreateProcessAsUserW(token, executable, command.data(), nullptr, nullptr, TRUE,
    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | CREATE_NO_WINDOW, environment, nullptr, &startup.StartupInfo, &pi);
  DestroyEnvironmentBlock(environment); DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!ok) return 1;
  Handle process(pi.hProcess), thread(pi.hThread); CloseHandle(inputRead.value); inputRead.value = nullptr; CloseHandle(outputWrite.value); outputWrite.value = nullptr;
  std::thread sender([&] { copy(GetStdHandle(STD_INPUT_HANDLE), inputWrite); CloseHandle(inputWrite.value); inputWrite.value = nullptr; });
  copy(outputRead, GetStdHandle(STD_OUTPUT_HANDLE));
  // EOF closes the worker's input; its own release handler runs before exit.
  CancelSynchronousIo(sender.native_handle()); sender.join();
  if (WaitForSingleObject(process, 2000) == WAIT_TIMEOUT) TerminateProcess(process, 1);
  return 0;
}
void protectPipe(const std::wstring& pipe, const std::wstring& owner) {
  if (pipe.rfind(L"\\\\.\\pipe\\codeaw-backend-", 0) != 0 || owner.rfind(L"S-1-", 0) != 0) throw std::runtime_error("Invalid pipe");
  Handle handle(CreateFileW(pipe.c_str(), READ_CONTROL | WRITE_DAC, 0, nullptr, OPEN_EXISTING, 0, nullptr));
  if (handle.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Pipe unavailable");
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + owner + L")";
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) throw std::runtime_error("Invalid security descriptor");
  PACL acl; BOOL present, isDefault; GetSecurityDescriptorDacl(descriptor, &present, &acl, &isDefault);
  DWORD result = SetSecurityInfo(handle, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr, nullptr, acl, nullptr);
  LocalFree(descriptor); if (result != ERROR_SUCCESS) throw std::runtime_error("Pipe protection failed");
}
void secureAttention() {
  Handle pipe(CreateFileW(L"\\\\.\\pipe\\codeaw-desktop-sas", GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr));
  if (pipe.value == INVALID_HANDLE_VALUE) throw std::runtime_error("Secure attention unavailable");
  DWORD pid = GetCurrentProcessId(), n, result = 1;
  if (!WriteFile(pipe, &pid, sizeof(pid), &n, nullptr) || !ReadFile(pipe, &result, sizeof(result), &n, nullptr) || result != 0) throw std::runtime_error("Secure attention disabled by policy");
}

static SERVICE_STATUS_HANDLE statusHandle;
static SERVICE_STATUS status{};
static HANDLE stopEvent;
static std::wstring manifestFile, serviceName;
static void report(DWORD state, DWORD error = NO_ERROR) {
  status.dwServiceType = SERVICE_WIN32_OWN_PROCESS; status.dwCurrentState = state; status.dwWin32ExitCode = error;
  status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
  status.dwWaitHint = state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING ? 15000 : 0;
  SetServiceStatus(statusHandle, &status);
}
static DWORD WINAPI control(DWORD command, DWORD, void*, void*) {
  if (command == SERVICE_CONTROL_STOP || command == SERVICE_CONTROL_SHUTDOWN) { report(SERVICE_STOP_PENDING); SetEvent(stopEvent); } return NO_ERROR;
}
static void sasServer() {
  PSECURITY_DESCRIPTOR sd = nullptr; ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;SY)", SDDL_REVISION_1, &sd, nullptr);
  SECURITY_ATTRIBUTES sa{sizeof(sa), sd, FALSE};
  while (WaitForSingleObject(stopEvent, 0) == WAIT_TIMEOUT) {
    Handle pipe(CreateNamedPipeW(L"\\\\.\\pipe\\codeaw-desktop-sas", PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 128, 128, 1000, &sa));
    if (pipe.value == INVALID_HANDLE_VALUE) break;
    if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
      DWORD pid = 0, n, result = 1; ULONG clientPid = 0;
      if (GetNamedPipeClientProcessId(pipe, &clientPid) && ReadFile(pipe, &pid, sizeof(pid), &n, nullptr) && n == sizeof(pid) && pid == clientPid) {
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)), token;
        DWORD session = 0; ProcessIdToSessionId(pid, &session);
        if (process.value && OpenProcessToken(process, TOKEN_QUERY | TOKEN_DUPLICATE, &token.value) && systemToken(token) && session == WTSGetActiveConsoleSessionId()) {
          DWORD policy = 0, bytes = sizeof(policy);
          if (RegGetValueW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", L"SoftwareSASGeneration", RRF_RT_REG_DWORD, nullptr, &policy, &bytes) == ERROR_SUCCESS && (policy == 1 || policy == 3)) {
            Handle impersonation;
            if (DuplicateTokenEx(token, TOKEN_QUERY | TOKEN_IMPERSONATE, nullptr, SecurityImpersonation, TokenImpersonation, &impersonation.value) && ImpersonateLoggedOnUser(impersonation)) {
              SendSAS(FALSE); RevertToSelf(); result = 0;
            }
          }
        }
      }
      WriteFile(pipe, &result, sizeof(result), &n, nullptr); DisconnectNamedPipe(pipe);
    }
  }
  LocalFree(sd);
}
static void WINAPI runService(DWORD, wchar_t**) {
  statusHandle = RegisterServiceCtrlHandlerExW(serviceName.c_str(), control, nullptr); if (!statusHandle) return;
  stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr); report(SERVICE_START_PENDING);
  try {
    std::ifstream file{std::filesystem::path(manifestFile)}; Json manifest; file >> manifest;
    std::wstring executable = wide(manifest.at("gateway").get<std::string>());
    std::wstring command = L"\"" + executable + L"\" --manifest \"" + manifestFile + L"\"";
    STARTUPINFOW si{}; si.cb = sizeof(si); PROCESS_INFORMATION pi{};
    if (!CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, std::filesystem::path(executable).parent_path().c_str(), &si, &pi)) throw std::runtime_error("Gateway startup failed");
    Handle process(pi.hProcess), thread(pi.hThread);
    std::thread sas(sasServer); report(SERVICE_RUNNING);
    HANDLE wait[] = {stopEvent, process}; DWORD event = WaitForMultipleObjects(2, wait, FALSE, INFINITE);
    SetEvent(stopEvent); CancelSynchronousIo(sas.native_handle()); sas.join();
    if (WaitForSingleObject(process, 0) == WAIT_TIMEOUT) TerminateProcess(process, 0);
    WaitForSingleObject(process, 5000);
    report(SERVICE_STOPPED, event == WAIT_OBJECT_0 ? NO_ERROR : ERROR_PROCESS_ABORTED);
  } catch (...) { report(SERVICE_STOPPED, ERROR_PROCESS_ABORTED); }
  CloseHandle(stopEvent);
}
int serviceMain(const std::wstring& manifest) {
  manifestFile = manifest; std::ifstream file{std::filesystem::path(manifest)}; Json config; file >> config;
  serviceName = wide(config.at("name").get<std::string>());
  SERVICE_TABLE_ENTRYW table[] = {{serviceName.data(), runService}, {nullptr, nullptr}};
  return StartServiceCtrlDispatcherW(table) ? 0 : 1;
}
