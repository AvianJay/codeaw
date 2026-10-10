#include "desktop.h"
#include <set>
#include <cmath>
static void send(INPUT in) {
  SetLastError(ERROR_SUCCESS);
  if (SendInput(1, &in, sizeof(in)) != 1) throw DesktopWindowsError("send_input", GetLastError());
}
static DWORD buttonFlag(const std::string& button, bool down) {
  if (button == "left") return down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
  if (button == "right") return down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
  if (button == "middle") return down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP;
  throw std::runtime_error("Invalid button");
}
static DWORD extended(int code) {
  return ((code >= VK_PRIOR && code <= VK_DOWN) || code == VK_INSERT || code == VK_DELETE || code == VK_RCONTROL || code == VK_RMENU || code == VK_LWIN || code == VK_RWIN) ? KEYEVENTF_EXTENDEDKEY : 0;
}
void InputController::apply(const Json& input, RECT monitor) {
  enterDesktop(); auto kind = input.at("kind").get<std::string>();
  if (kind == "release") { release(); return; }
  if (kind == "sas") { secureAttention(); return; }
  if (kind == "pointer" || kind == "button" || kind == "wheel") {
    double x = input.at("x"), y = input.at("y"); if (x < 0 || x > 1 || y < 0 || y > 1 || !std::isfinite(x) || !std::isfinite(y)) throw std::runtime_error("Invalid coordinates");
    int left = GetSystemMetrics(SM_XVIRTUALSCREEN), top = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int width = GetSystemMetrics(SM_CXVIRTUALSCREEN), height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    INPUT move{}; move.type = INPUT_MOUSE; move.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    move.mi.dx = LONG((monitor.left + x * (monitor.right - monitor.left - 1) - left) * 65535 / std::max(1, width - 1));
    move.mi.dy = LONG((monitor.top + y * (monitor.bottom - monitor.top - 1) - top) * 65535 / std::max(1, height - 1)); send(move);
    if (kind == "button") {
      auto button = input.at("button").get<std::string>(); bool down = input.at("down");
      INPUT click{}; click.type = INPUT_MOUSE; click.mi.dwFlags = buttonFlag(button, down); send(click);
      buttons.erase(std::remove(buttons.begin(), buttons.end(), button), buttons.end()); if (down) buttons.push_back(button);
    } else if (kind == "wheel") {
      const int vertical = std::clamp(input.at("delta").get<int>(), -1200, 1200);
      const int horizontal = std::clamp(input.value("deltaX", 0), -1200, 1200);
      // Each axis uses mouseData, so diagonal scrolling requires separate events.
      if (vertical) {
        INPUT wheel{}; wheel.type = INPUT_MOUSE; wheel.mi.dwFlags = MOUSEEVENTF_WHEEL;
        wheel.mi.mouseData = static_cast<DWORD>(vertical); send(wheel);
      }
      if (horizontal) {
        INPUT wheel{}; wheel.type = INPUT_MOUSE; wheel.mi.dwFlags = MOUSEEVENTF_HWHEEL;
        wheel.mi.mouseData = static_cast<DWORD>(horizontal); send(wheel);
      }
    }
  } else if (kind == "key") {
    int code = input.at("code"); bool down = input.at("down"); if (code < 1 || code > 254) throw std::runtime_error("Invalid key");
    INPUT key{}; key.type = INPUT_KEYBOARD; key.ki.wVk = static_cast<WORD>(code); key.ki.dwFlags = down ? 0 : KEYEVENTF_KEYUP;
    key.ki.dwFlags |= extended(code);
    send(key); keys.erase(std::remove(keys.begin(), keys.end(), code), keys.end()); if (down) keys.push_back(static_cast<WORD>(code));
  } else if (kind == "text") {
    auto text = wide(input.at("text").get<std::string>()); if (text.size() > 8192) throw std::runtime_error("Text too large");
    for (wchar_t c : text) { INPUT key{}; key.type = INPUT_KEYBOARD; key.ki.wScan = c; key.ki.dwFlags = KEYEVENTF_UNICODE; send(key); key.ki.dwFlags |= KEYEVENTF_KEYUP; send(key); }
    SecureZeroMemory(text.data(), text.size() * sizeof(wchar_t));
  } else throw std::runtime_error("Invalid input");
}
void InputController::release() {
  try { enterDesktop(); } catch (...) { return; }
  for (WORD code : keys) { INPUT key{}; key.type = INPUT_KEYBOARD; key.ki.wVk = code; key.ki.dwFlags = KEYEVENTF_KEYUP | extended(code); SendInput(1, &key, sizeof(key)); }
  for (auto& button : buttons) { INPUT click{}; click.type = INPUT_MOUSE; click.mi.dwFlags = buttonFlag(button, false); SendInput(1, &click, sizeof(click)); }
  keys.clear(); buttons.clear();
}
