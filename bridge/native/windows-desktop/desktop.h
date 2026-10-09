#pragma once
#include <windows.h>
#include <wrl/client.h>
#include <nlohmann/json.hpp>
#include <vector>
#include <string>
#include <mutex>
#include <memory>
#include <atomic>
#include <thread>
#include <stdexcept>
#include <algorithm>
using Json = nlohmann::json;
template<class T> using Com = Microsoft::WRL::ComPtr<T>;
inline void check(HRESULT hr) { if (FAILED(hr)) throw std::runtime_error("Windows desktop operation failed"); }
inline std::wstring wide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
  if (!n) throw std::runtime_error("Invalid UTF-8");
  std::wstring out(n, L'\0'); MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), n); return out;
}
inline std::string utf8(const std::wstring& s) {
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0'); WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), out.data(), n, nullptr, nullptr); return out;
}
struct Frame { int width = 0, height = 0; std::vector<unsigned char> pixels; Json cursor; };
struct Capture {
  struct Impl; std::unique_ptr<Impl> impl;
  Capture(); ~Capture();
  Json monitors(); void configure(const std::string& monitor);
  Frame grab(int longEdge); std::pair<Json, std::vector<unsigned char>> tiles(int longEdge, int quality, bool full);
  void ack(); RECT bounds(); void reset();
};
struct InputController {
  std::vector<WORD> keys; std::vector<std::string> buttons;
  ~InputController() { release(); }
  void apply(const Json& input, RECT monitor); void release();
};
void output(const Json& header, const std::vector<unsigned char>& payload = {});
struct Video {
  struct Impl; std::unique_ptr<Impl> impl;
  Video(); ~Video();
  static bool supported(); static bool hardware();
  static Json selfTest();
  void start(const std::string& monitor, int fps, int bitrate, int longEdge, const std::string& bindAddress, int epoch, bool synthetic = false);
  void answer(const std::string& sdp); void candidate(const std::string& candidate, const std::string& mid);
  void bitrate(int value); void stop();
};
int worker(); int broker(const std::wstring& privilege);
int serviceMain(const std::wstring& manifest);
void protectPipe(const std::wstring& pipe, const std::wstring& owner);
void enterDesktop();
void secureAttention();
int pipeTunnel(const std::wstring& pipe, const std::wstring& owner);
