#include "desktop.h"
// Clipboard text only. Nothing here throws: a busy clipboard must not reset capture.
static const size_t clipboardLimit = 256 * 1024;
struct OpenedClipboard {
  bool open = false;
  OpenedClipboard() {
    // Another program may hold it for a moment while it copies.
    for (int attempt = 0; attempt < 8 && !open; attempt++) { open = OpenClipboard(nullptr) != 0; if (!open) Sleep(15); }
  }
  ~OpenedClipboard() { if (open) CloseClipboard(); }
};
Json clipboardRead(DWORD known, std::vector<unsigned char>& payload) {
  const DWORD seq = GetClipboardSequenceNumber();
  if (seq == known) return {{"seq", seq}, {"changed", false}};
  try {
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return {{"seq", seq}, {"changed", false}};
    OpenedClipboard clipboard;
    // Report the old number so the next poll looks again.
    if (!clipboard.open) return {{"seq", known}, {"changed", false}};
    HANDLE data = GetClipboardData(CF_UNICODETEXT);
    const wchar_t* text = data ? static_cast<const wchar_t*>(GlobalLock(data)) : nullptr;
    if (!text) return {{"seq", seq}, {"changed", false}};
    const size_t available = GlobalSize(data) / sizeof(wchar_t);
    size_t length = 0; while (length < available && text[length]) length++;
    std::string encoded = length <= clipboardLimit ? utf8(std::wstring(text, length)) : std::string();
    GlobalUnlock(data);
    if (encoded.empty() || encoded.size() > clipboardLimit) return {{"seq", seq}, {"changed", false}, {"skipped", length > 0}};
    payload.assign(encoded.begin(), encoded.end());
    SecureZeroMemory(encoded.data(), encoded.size());
    return {{"seq", seq}, {"changed", true}};
  } catch (...) { return {{"seq", seq}, {"changed", false}}; }
}
Json clipboardWrite(const std::string& encoded) {
  try {
    if (encoded.size() > clipboardLimit) return {{"ok", false}};
    std::wstring text = wide(encoded);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (text.size() + 1) * sizeof(wchar_t));
    if (!memory) return {{"ok", false}};
    auto target = static_cast<wchar_t*>(GlobalLock(memory));
    if (!target) { GlobalFree(memory); return {{"ok", false}}; }
    std::copy(text.begin(), text.end(), target); target[text.size()] = L'\0'; GlobalUnlock(memory);
    SecureZeroMemory(text.data(), text.size() * sizeof(wchar_t));
    bool stored = false;
    {
      OpenedClipboard clipboard;
      stored = clipboard.open && EmptyClipboard() && SetClipboardData(CF_UNICODETEXT, memory);
    }
    // The clipboard owns the memory only once it accepted it.
    if (!stored) { GlobalFree(memory); return {{"ok", false}}; }
    return {{"ok", true}, {"seq", GetClipboardSequenceNumber()}};
  } catch (...) { return {{"ok", false}}; }
}
