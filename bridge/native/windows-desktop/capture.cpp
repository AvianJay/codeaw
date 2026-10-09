#include "desktop.h"
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wincodec.h>
#include <sstream>
#include <wincrypt.h>

void enterDesktop() {
  struct DesktopHandle { HDESK value = nullptr; std::wstring name; ~DesktopHandle() { if (value) CloseDesktop(value); } };
  static thread_local DesktopHandle current;
  // SendInput requires journal-playback access on the desktop attached to this thread.
  HDESK next = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS | DESKTOP_SWITCHDESKTOP | DESKTOP_JOURNALPLAYBACK);
  if (!next) throw DesktopWindowsError("open_input_desktop", GetLastError());
  wchar_t name[256]{}; DWORD size = 0;
  if (!GetUserObjectInformationW(next, UOI_NAME, name, sizeof(name), &size)) { DWORD error = GetLastError(); CloseDesktop(next); throw DesktopWindowsError("inspect_input_desktop", error); }
  if (current.name == name) { CloseDesktop(next); return; }
  if (!SetThreadDesktop(next)) { DWORD error = GetLastError(); CloseDesktop(next); throw DesktopWindowsError("attach_input_desktop", error); }
  if (current.value) CloseDesktop(current.value);
  current.value = next; current.name = name;
}
static BOOL CALLBACK enumMonitor(HMONITOR handle, HDC, LPRECT, LPARAM ptr) {
  MONITORINFOEXW info{}; info.cbSize = sizeof(info); if (!GetMonitorInfoW(handle, &info)) return TRUE;
  auto* list = reinterpret_cast<Json*>(ptr); auto r = info.rcMonitor;
  list->push_back({{"id", utf8(info.szDevice)}, {"name", utf8(info.szDevice)}, {"x", r.left}, {"y", r.top},
    {"width", r.right - r.left}, {"height", r.bottom - r.top}, {"primary", (info.dwFlags & MONITORINFOF_PRIMARY) != 0}}); return TRUE;
}
struct Capture::Impl {
  Com<IWICImagingFactory> wic;
  Com<ID3D11Device> device; Com<ID3D11DeviceContext> context;
  Com<IDXGIOutputDuplication> duplication; Com<ID3D11Texture2D> staging;
  RECT rect{}; std::string monitor; int previousWidth = 0, previousHeight = 0;
  std::vector<uint64_t> baseline, pending;
  HCURSOR previousCursor = nullptr;
  Frame cached;
  Impl() { check(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))); }
  void duplicate() {
    duplication.Reset(); staging.Reset(); context.Reset(); device.Reset();
    Com<IDXGIFactory1> factory; check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)));
    for (UINT ai = 0;; ++ai) {
      Com<IDXGIAdapter1> adapter; if (factory->EnumAdapters1(ai, &adapter) == DXGI_ERROR_NOT_FOUND) break;
      for (UINT oi = 0;; ++oi) {
        Com<IDXGIOutput> output; if (adapter->EnumOutputs(oi, &output) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_OUTPUT_DESC desc{}; check(output->GetDesc(&desc)); if (utf8(desc.DeviceName) != monitor) continue;
        check(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
          D3D11_SDK_VERSION, &device, nullptr, &context));
        Com<IDXGIOutput1> output1; check(output.As(&output1)); check(output1->DuplicateOutput(device.Get(), &duplication)); return;
      }
    }
    throw std::runtime_error("Display unavailable");
  }
  std::vector<unsigned char> encode(const unsigned char* pixels, int width, int height, int stride, int quality, bool png = false) {
    Com<IStream> stream; check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
    Com<IWICBitmapEncoder> encoder; check(wic->CreateEncoder(png ? GUID_ContainerFormatPng : GUID_ContainerFormatJpeg, nullptr, &encoder));
    check(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    Com<IWICBitmapFrameEncode> frame; Com<IPropertyBag2> props; check(encoder->CreateNewFrame(&frame, &props));
    if (!png) { PROPBAG2 p{}; p.pstrName = const_cast<wchar_t*>(L"ImageQuality"); VARIANT v{}; v.vt = VT_R4; v.fltVal = quality / 100.0f; check(props->Write(1, &p, &v)); }
    check(frame->Initialize(props.Get())); check(frame->SetSize(width, height));
    WICPixelFormatGUID format = png ? GUID_WICPixelFormat32bppBGRA : GUID_WICPixelFormat24bppBGR;
    check(frame->SetPixelFormat(&format));
    std::vector<unsigned char> cropped(width * height * 4);
    for (int y = 0; y < height; ++y) memcpy(cropped.data() + y * width * 4, pixels + y * stride, width * 4);
    Com<IWICBitmap> bitmap; check(wic->CreateBitmapFromMemory(width, height, GUID_WICPixelFormat32bppBGRA, width * 4,
      static_cast<UINT>(cropped.size()), cropped.data(), &bitmap));
    Com<IWICFormatConverter> converter; check(wic->CreateFormatConverter(&converter));
    check(converter->Initialize(bitmap.Get(), format, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom));
    check(frame->WriteSource(converter.Get(), nullptr)); check(frame->Commit()); check(encoder->Commit());
    HGLOBAL memory; check(GetHGlobalFromStream(stream.Get(), &memory)); STATSTG stat{}; check(stream->Stat(&stat, STATFLAG_NONAME));
    auto* bytes = static_cast<unsigned char*>(GlobalLock(memory));
    std::vector<unsigned char> data(bytes, bytes + stat.cbSize.QuadPart); GlobalUnlock(memory); return data;
  }
  Json cursorShape(HCURSOR cursor, double scale) {
    ICONINFO info{}; if (!GetIconInfo(cursor, &info)) return Json::object();
    struct Icons { ICONINFO& i; ~Icons() { if (i.hbmColor) DeleteObject(i.hbmColor); if (i.hbmMask) DeleteObject(i.hbmMask); } } icons{info};
    BITMAP size{}; GetObjectW(info.hbmColor ? info.hbmColor : info.hbmMask, sizeof(size), &size);
    int width = size.bmWidth, height = info.hbmColor ? size.bmHeight : size.bmHeight / 2;
    if (width < 1 || height < 1 || width > 128 || height > 128) return Json::object();
    HDC memory = CreateCompatibleDC(nullptr); BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = width; bi.bmiHeader.biHeight = -height; bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32;
    void* pixels = nullptr; HBITMAP bitmap = CreateDIBSection(memory, &bi, DIB_RGB_COLORS, &pixels, nullptr, 0);
    if (!bitmap || !memory) { if (bitmap) DeleteObject(bitmap); if (memory) DeleteDC(memory); return Json::object(); }
    auto old = SelectObject(memory, bitmap); memset(pixels, 0, width * height * 4); DrawIconEx(memory, 0, 0, cursor, width, height, 0, nullptr, DI_NORMAL);
    auto* bytes = static_cast<unsigned char*>(pixels); bool alpha = false;
    for (int i = 3; i < width * height * 4; i += 4) alpha = alpha || bytes[i] != 0;
    if (!alpha && info.hbmMask) {
      HDC mask = CreateCompatibleDC(nullptr); auto previous = SelectObject(mask, info.hbmMask);
      for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        int i = (y * width + x) * 4;
        bytes[i + 3] = GetPixel(mask, x, y) == RGB(255, 255, 255) && !(bytes[i] || bytes[i + 1] || bytes[i + 2]) ? 0 : 255;
      }
      SelectObject(mask, previous); DeleteDC(mask);
    }
    std::vector<unsigned char> copied(bytes, bytes + width * height * 4);
    SelectObject(memory, old); DeleteObject(bitmap); DeleteDC(memory);
    auto png = encode(copied.data(), width, height, width * 4, 100, true); DWORD n = 0;
    if (!CryptBinaryToStringA(png.data(), static_cast<DWORD>(png.size()), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &n)) return Json::object();
    std::string base64(n, '\0'); CryptBinaryToStringA(png.data(), static_cast<DWORD>(png.size()), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, base64.data(), &n); base64.resize(n);
    while (!base64.empty() && !base64.back()) base64.pop_back();
    return {{"png", base64}, {"width", width * scale}, {"height", height * scale}, {"hotX", info.xHotspot * scale}, {"hotY", info.yHotspot * scale}};
  }
  Frame gdi() {
    Frame frame; frame.width = rect.right - rect.left; frame.height = rect.bottom - rect.top;
    if (frame.width < 1 || frame.height < 1 || frame.width > 16384 || frame.height > 16384) throw std::runtime_error("Invalid display dimensions");
    HDC screen = GetDC(nullptr), memory = CreateCompatibleDC(screen);
    BITMAPINFO bi{}; bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth = frame.width;
    bi.bmiHeader.biHeight = -frame.height; bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr; HBITMAP bitmap = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!bitmap || !memory || !screen) { if (bitmap) DeleteObject(bitmap); if (memory) DeleteDC(memory); if (screen) ReleaseDC(nullptr, screen); throw std::runtime_error("Capture unavailable"); }
    auto old = SelectObject(memory, bitmap);
    BOOL ok = BitBlt(memory, 0, 0, frame.width, frame.height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT);
    if (ok) frame.pixels.assign(static_cast<unsigned char*>(bits), static_cast<unsigned char*>(bits) + frame.width * frame.height * 4);
    SelectObject(memory, old); DeleteObject(bitmap); DeleteDC(memory); ReleaseDC(nullptr, screen);
    if (!ok) throw std::runtime_error("Capture unavailable"); return frame;
  }
  Frame dxgi() {
    if (!duplication) duplicate();
    DXGI_OUTDUPL_FRAME_INFO info{}; Com<IDXGIResource> resource;
    HRESULT hr = duplication->AcquireNextFrame(0, &info, &resource);
    if (hr == DXGI_ERROR_WAIT_TIMEOUT) return cached.pixels.empty() ? gdi() : cached;
    check(hr);
    struct Release { IDXGIOutputDuplication* d; ~Release() { d->ReleaseFrame(); } } release{duplication.Get()};
    Com<ID3D11Texture2D> texture; check(resource.As(&texture)); D3D11_TEXTURE2D_DESC desc{}; texture->GetDesc(&desc);
    // DXGI textures are unrotated; the GDI fallback preserves display rotation.
    if (desc.Width != static_cast<UINT>(rect.right - rect.left) || desc.Height != static_cast<UINT>(rect.bottom - rect.top)) return gdi();
    if (!staging) {
      desc.BindFlags = 0; desc.MiscFlags = 0; desc.Usage = D3D11_USAGE_STAGING; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
      check(device->CreateTexture2D(&desc, nullptr, &staging));
    }
    context->CopyResource(staging.Get(), texture.Get()); D3D11_MAPPED_SUBRESOURCE mapped{};
    check(context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped));
    Frame frame; frame.width = desc.Width; frame.height = desc.Height; frame.pixels.resize(frame.width * frame.height * 4);
    for (int y = 0; y < frame.height; ++y) memcpy(frame.pixels.data() + y * frame.width * 4, static_cast<unsigned char*>(mapped.pData) + y * mapped.RowPitch, frame.width * 4);
    context->Unmap(staging.Get(), 0); cached = frame; return frame;
  }
};
Capture::Capture() : impl(std::make_unique<Impl>()) {}
Capture::~Capture() = default;
Json Capture::monitors() {
  Json monitors = Json::array(); EnumDisplayMonitors(nullptr, nullptr, enumMonitor, reinterpret_cast<LPARAM>(&monitors)); return monitors;
}
void Capture::configure(const std::string& monitor) {
  auto all = monitors(); auto found = std::find_if(all.begin(), all.end(), [&](auto& m) { return m["id"] == monitor; });
  if (found == all.end()) throw std::runtime_error("Monitor unavailable");
  impl->monitor = monitor; impl->rect = {(*found)["x"], (*found)["y"], int((*found)["x"]) + int((*found)["width"]), int((*found)["y"]) + int((*found)["height"])}; reset();
}
RECT Capture::bounds() { return impl->rect; }
void Capture::reset() { impl->duplication.Reset(); impl->staging.Reset(); impl->baseline.clear(); impl->pending.clear(); impl->cached = {}; impl->previousCursor = nullptr; }
Frame Capture::grab(int longEdge) {
  enterDesktop();
  if (impl->monitor.empty()) { auto all = monitors(); if (all.empty()) throw std::runtime_error("Monitor unavailable"); configure(all[0]["id"]); }
  auto all = monitors(); auto found = std::find_if(all.begin(), all.end(), [&](auto& m) { return m["id"] == impl->monitor; });
  if (found == all.end()) throw std::runtime_error("Monitor unavailable");
  if (int((*found)["width"]) != impl->rect.right - impl->rect.left || int((*found)["height"]) != impl->rect.bottom - impl->rect.top || int((*found)["x"]) != impl->rect.left || int((*found)["y"]) != impl->rect.top) configure(impl->monitor);
  Frame frame;
  try { frame = impl->dxgi(); } catch (...) { impl->duplication.Reset(); impl->staging.Reset(); frame = impl->gdi(); }
  // GDI and DXGI use different alpha bytes for the same opaque desktop.
  for (size_t i = 3; i < frame.pixels.size(); i += 4) frame.pixels[i] = 255;
  double scale = std::min(1.0, double(longEdge) / std::max(frame.width, frame.height));
  if (scale < 1) {
    int width = std::max(2, int(frame.width * scale) & ~1), height = std::max(2, int(frame.height * scale) & ~1);
    Com<IWICBitmap> bitmap; check(impl->wic->CreateBitmapFromMemory(frame.width, frame.height, GUID_WICPixelFormat32bppBGRA, frame.width * 4, static_cast<UINT>(frame.pixels.size()), frame.pixels.data(), &bitmap));
    Com<IWICBitmapScaler> scaler; check(impl->wic->CreateBitmapScaler(&scaler)); check(scaler->Initialize(bitmap.Get(), width, height, WICBitmapInterpolationModeFant));
    std::vector<unsigned char> pixels(width * height * 4); check(scaler->CopyPixels(nullptr, width * 4, static_cast<UINT>(pixels.size()), pixels.data()));
    frame.width = width; frame.height = height; frame.pixels = std::move(pixels);
  }
  CURSORINFO cursor{}; cursor.cbSize = sizeof(cursor);
  if (GetCursorInfo(&cursor)) frame.cursor = {{"x", double(cursor.ptScreenPos.x - impl->rect.left) / (impl->rect.right - impl->rect.left)},
    {"y", double(cursor.ptScreenPos.y - impl->rect.top) / (impl->rect.bottom - impl->rect.top)}, {"visible", (cursor.flags & CURSOR_SHOWING) != 0}};
  if (cursor.hCursor && cursor.hCursor != impl->previousCursor) {
    try { frame.cursor["shape"] = impl->cursorShape(cursor.hCursor, double(frame.width) / (impl->rect.right - impl->rect.left)); impl->previousCursor = cursor.hCursor; } catch (...) { /* Keep pointer position when a theme cursor cannot be encoded. */ }
  }
  return frame;
}
std::pair<Json, std::vector<unsigned char>> Capture::tiles(int longEdge, int quality, bool full) {
  auto frame = grab(longEdge); Json tiles = Json::array(); std::vector<unsigned char> payload;
  int columns = (frame.width + 127) / 128, rows = (frame.height + 127) / 128;
  full = full || impl->previousWidth != frame.width || impl->previousHeight != frame.height || impl->baseline.size() != static_cast<size_t>(columns * rows);
  impl->previousWidth = frame.width; impl->previousHeight = frame.height; impl->pending.clear();
  for (int y = 0, index = 0; y < frame.height; y += 128) for (int x = 0; x < frame.width; x += 128, ++index) {
    int width = std::min(128, frame.width - x), height = std::min(128, frame.height - y); uint64_t hash = 14695981039346656037ULL;
    for (int ty = 0; ty < height; ++ty) for (int tx = 0; tx < width * 4; ++tx) { hash ^= frame.pixels[((y + ty) * frame.width + x) * 4 + tx]; hash *= 1099511628211ULL; }
    impl->pending.push_back(hash);
    if (!full && impl->baseline[index] == hash) continue;
    auto bytes = impl->encode(frame.pixels.data() + (y * frame.width + x) * 4, width, height, frame.width * 4, quality);
    tiles.push_back({{"x", x}, {"y", y}, {"width", width}, {"height", height}, {"offset", payload.size()}, {"length", bytes.size()}});
    payload.insert(payload.end(), bytes.begin(), bytes.end());
  }
  return {{{"width", frame.width}, {"height", frame.height}, {"sourceWidth", impl->rect.right - impl->rect.left}, {"sourceHeight", impl->rect.bottom - impl->rect.top},
    {"tiles", tiles}, {"full", full}, {"cursor", frame.cursor}}, std::move(payload)};
}
void Capture::ack() { impl->baseline = impl->pending; }
