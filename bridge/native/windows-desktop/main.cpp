#include "desktop.h"
#include <io.h>
#include <fcntl.h>
#include <iostream>
#include <objbase.h>
static std::mutex outputMutex;
void output(const Json& header, const std::vector<unsigned char>& payload) {
  Json meta = header; meta["payloadBytes"] = payload.size();
  std::string encoded = meta.dump(); uint32_t size = static_cast<uint32_t>(encoded.size());
  std::lock_guard<std::mutex> lock(outputMutex);
  std::cout.write(reinterpret_cast<char*>(&size), 4); std::cout.write(encoded.data(), size);
  if (!payload.empty()) std::cout.write(reinterpret_cast<const char*>(payload.data()), payload.size());
  std::cout.flush();
}
int worker() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  check(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  struct Apartment { ~Apartment() { CoUninitialize(); } } apartment;
  Capture capture; InputController input; Video video; std::string monitor;
  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.size() > 16 * 1024) break;
    int id = 0; std::string command, inputKind;
    try {
      auto msg = Json::parse(line); id = msg.at("id").get<int>(); command = msg.at("command").get<std::string>();
      if (command == "input" && msg.contains("input")) inputKind = msg["input"].value("kind", "");
      Json result = Json::object(); std::vector<unsigned char> payload;
      if (command == "info") {
        auto displays = capture.monitors(); result = {{"monitors", displays}, {"smooth", Video::supported()}, {"hardware", Video::hardware()}, {"state", displays.empty() ? "display_unavailable" : "ready"}};
      } else if (command == "selfTest") result = Video::selfTest();
      else if (command == "configure") {
        video.stop(); input.release(); monitor = msg.at("monitorId").get<std::string>(); capture.configure(monitor);
      } else if (command == "capture") {
        auto data = capture.tiles(std::clamp(msg.value("longEdge", 1600), 320, 1920), std::clamp(msg.value("quality", 70), 20, 85), msg.value("full", false));
        result = std::move(data.first); payload = std::move(data.second);
      } else if (command == "ack") capture.ack();
      else if (command == "input") input.apply(msg.at("input"), capture.bounds());
      else if (command == "release") input.release();
      else if (command == "video") video.start(monitor, msg.value("fps", 30) == 60 ? 60 : 30, std::clamp(msg.value("bitrate", 4000000), 128000, 8000000), std::clamp(msg.value("longEdge", 1920), 320, 1920), msg.value("bindAddress", "127.0.0.1"), msg.value("epoch", 1));
      else if (command == "videoTest") video.start("", msg.value("fps", 30) == 60 ? 60 : 30, 1000000, 640, "127.0.0.1", 1, true);
      else if (command == "videoStop") video.stop();
      else if (command == "answer") video.answer(msg.at("sdp").get<std::string>());
      else if (command == "candidate") video.candidate(msg.at("candidate").get<std::string>(), msg.value("mid", "0"));
      else if (command == "bitrate") video.bitrate(std::clamp(msg.value("bitrate", 4000000), 128000, 8000000));
      else throw std::runtime_error("Unknown desktop command");
      output({{"replyTo", id}, {"result", result}}, payload);
    } catch (...) {
      // Fixed messages only: a parse exception must never reproduce typed passwords.
      input.release(); capture.reset();
      const char* code = inputKind == "sas" ? "sas_disabled" : command == "input" ? "input_blocked" : "capture_unavailable";
      const char* message = inputKind == "sas" ? "Windows 安全政策不允許軟體 Ctrl+Alt+Del，請由電腦管理員調整服務 SAS 政策" : command == "input" ? "此視窗無法接受輸入，可能需要進階權限" : "桌面暫時無法使用；鎖定或 UAC 可能需要進階權限";
      Json error = {{"code", code}, {"message", message}};
      try { throw; } catch (const DesktopWindowsError& detail) { error["operation"] = detail.operation; error["nativeCode"] = detail.code; } catch (...) {}
      output({{"replyTo", id}, {"error", error}});
    }
    SecureZeroMemory(line.data(), line.size()); line.clear();
  }
  video.stop(); input.release(); return 0;
}
int wmain(int argc, wchar_t** argv) {
  _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32 | LOAD_LIBRARY_SEARCH_APPLICATION_DIR);
  try {
    if (argc >= 3 && std::wstring(argv[1]) == L"--service") return serviceMain(argv[2]);
    if (argc >= 2 && std::wstring(argv[1]) == L"--protect-pipe" && argc == 4) { protectPipe(argv[2], argv[3]); return 0; }
    if (argc == 4 && std::wstring(argv[1]) == L"--tunnel") return pipeTunnel(argv[2], argv[3]);
    if (argc >= 2 && std::wstring(argv[1]) == L"--broker") return broker(argc >= 4 ? argv[3] : L"system");
    if (argc >= 2 && std::wstring(argv[1]) == L"--worker") return worker();
  } catch (...) { return 1; }
  return 2;
}
