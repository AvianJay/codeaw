#include "desktop.h"
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <codecapi.h>
#include <wmcodecdsp.h>
#include <iphlpapi.h>
#ifdef CODEAW_WEBRTC
#include <rtc/rtc.hpp>
#endif
#include <chrono>
#include <cmath>

static bool hasHardwareEncoder() {
  MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_NV12}, out{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activations = nullptr; UINT32 count = 0;
  HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &input, &out, &activations, &count);
  for (UINT32 i = 0; i < count; ++i) activations[i]->Release(); CoTaskMemFree(activations); return SUCCEEDED(hr) && count > 0;
}
struct Encoder {
  Com<IMFTransform> transform; Com<ICodecAPI> codec; Com<IMFMediaEventGenerator> events;
  int width, height, fps; bool asynchronous = false, needInput = true, haveOutput = false;
  LONGLONG time = 0;
  bool accepted = false;
  Encoder(int w, int h, int rate, int bitrate, bool hardware) : width(w), height(h), fps(rate) {
    if (hardware) {
      MFT_REGISTER_TYPE_INFO input{MFMediaType_Video, MFVideoFormat_NV12}, out{MFMediaType_Video, MFVideoFormat_H264};
      IMFActivate** activations = nullptr; UINT32 count = 0;
      check(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, &input, &out, &activations, &count));
      HRESULT hr = E_FAIL;
      for (UINT32 i = 0; i < count; ++i) { if (!transform) hr = activations[i]->ActivateObject(IID_PPV_ARGS(&transform)); activations[i]->Release(); }
      CoTaskMemFree(activations); if (!transform) check(hr);
    } else check(CoCreateInstance(CLSID_CMSH264EncoderMFT, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&transform)));
    Com<IMFAttributes> attrs;
    if (SUCCEEDED(transform->GetAttributes(&attrs))) {
      UINT32 async = 0; attrs->GetUINT32(MF_TRANSFORM_ASYNC, &async); asynchronous = async != 0;
      if (asynchronous) { check(attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE)); check(transform.As(&events)); needInput = false; }
    }
    transform.As(&codec);
    if (codec) {
      VARIANT v{}; v.vt = VT_BOOL; v.boolVal = VARIANT_TRUE; codec->SetValue(&CODECAPI_AVLowLatencyMode, &v);
      v.vt = VT_UI4; v.ulVal = 0; codec->SetValue(&CODECAPI_AVEncMPVDefaultBPictureCount, &v);
      v.ulVal = eAVEncCommonRateControlMode_PeakConstrainedVBR; codec->SetValue(&CODECAPI_AVEncCommonRateControlMode, &v);
      v.ulVal = fps * 2; codec->SetValue(&CODECAPI_AVEncMPVGOPSize, &v);
    }
    Com<IMFMediaType> output; check(MFCreateMediaType(&output)); check(output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    check(output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264)); check(output->SetUINT32(MF_MT_AVG_BITRATE, bitrate));
    check(output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive)); check(output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base));
    check(MFSetAttributeSize(output.Get(), MF_MT_FRAME_SIZE, width, height)); check(MFSetAttributeRatio(output.Get(), MF_MT_FRAME_RATE, fps, 1));
    check(MFSetAttributeRatio(output.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1)); check(transform->SetOutputType(0, output.Get(), 0));
    Com<IMFMediaType> input; check(MFCreateMediaType(&input)); check(input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video));
    check(input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12)); check(input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
    check(MFSetAttributeSize(input.Get(), MF_MT_FRAME_SIZE, width, height)); check(MFSetAttributeRatio(input.Get(), MF_MT_FRAME_RATE, fps, 1));
    check(MFSetAttributeRatio(input.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1)); check(transform->SetInputType(0, input.Get(), 0));
    setBitrate(bitrate); check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)); check(transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0));
  }
  void setBitrate(int bitrate) {
    if (!codec) return; VARIANT value{}; value.vt = VT_UI4; value.ulVal = bitrate; codec->SetValue(&CODECAPI_AVEncCommonMeanBitRate, &value);
    value.ulVal = std::min(8000000, bitrate * 2); codec->SetValue(&CODECAPI_AVEncCommonMaxBitRate, &value);
  }
  void keyframe() { if (codec) { VARIANT v{}; v.vt = VT_UI4; v.ulVal = 1; codec->SetValue(&CODECAPI_AVEncVideoForceKeyFrame, &v); } }
  void pollEvents() {
    if (!events) return;
    for (;;) { Com<IMFMediaEvent> event; if (events->GetEvent(MF_EVENT_FLAG_NO_WAIT, &event) == MF_E_NO_EVENTS_AVAILABLE) break;
      if (!event) break; MediaEventType type; check(event->GetType(&type)); HRESULT hr; check(event->GetStatus(&hr)); check(hr);
      if (type == METransformNeedInput) needInput = true; if (type == METransformHaveOutput) haveOutput = true;
    }
  }
  std::vector<unsigned char> readOutput() {
    if (asynchronous && !haveOutput) return {};
    MFT_OUTPUT_STREAM_INFO info{}; check(transform->GetOutputStreamInfo(0, &info));
    Com<IMFSample> sample; Com<IMFMediaBuffer> buffer;
    if (!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES)) {
      check(MFCreateSample(&sample)); check(MFCreateMemoryBuffer(std::max<DWORD>(info.cbSize, width * height * 2), &buffer)); check(sample->AddBuffer(buffer.Get()));
    }
    MFT_OUTPUT_DATA_BUFFER output{}; output.dwStreamID = 0; output.pSample = sample.Get(); DWORD flags;
    HRESULT hr = transform->ProcessOutput(0, 1, &output, &flags); if (output.pEvents) output.pEvents->Release();
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) { haveOutput = false; return {}; }
    check(hr);
    if (!sample && output.pSample) sample.Attach(output.pSample);
    check(sample->ConvertToContiguousBuffer(&buffer)); BYTE* data; DWORD size;
    check(buffer->Lock(&data, nullptr, &size)); std::vector<unsigned char> bytes(data, data + size); check(buffer->Unlock()); haveOutput = false; return bytes;
  }
  std::vector<unsigned char> encode(const Frame& frame, bool submit = true) {
    accepted = false;
    pollEvents();
    auto encoded = readOutput(); pollEvents();
    // Drain output before submitting: some hardware MFTs signal NeedInput only
    // after their previous output is consumed. Otherwise throughput halves.
    if (asynchronous && submit && !needInput) {
      auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(8);
      while (!needInput && std::chrono::steady_clock::now() < until) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); pollEvents(); }
    }
    if (needInput && submit) {
      std::vector<unsigned char> nv12(width * height * 3 / 2);
      auto clamp = [](int x) { return static_cast<unsigned char>(std::clamp(x, 0, 255)); };
      for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        auto* pixel = frame.pixels.data() + (y * frame.width + x) * 4;
        nv12[y * width + x] = clamp(((66 * pixel[2] + 129 * pixel[1] + 25 * pixel[0] + 128) >> 8) + 16);
        if (!(x & 1) && !(y & 1)) {
          int r = 0, g = 0, b = 0;
          for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) { auto* p = pixel + (dy * frame.width + dx) * 4; b += p[0]; g += p[1]; r += p[2]; }
          r /= 4; g /= 4; b /= 4; int offset = width * height + (y / 2) * width + x;
          nv12[offset] = clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
          nv12[offset + 1] = clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
        }
      }
      Com<IMFMediaBuffer> memory; check(MFCreateMemoryBuffer(static_cast<DWORD>(nv12.size()), &memory));
      BYTE* data; check(memory->Lock(&data, nullptr, nullptr)); memcpy(data, nv12.data(), nv12.size()); check(memory->Unlock()); check(memory->SetCurrentLength(static_cast<DWORD>(nv12.size())));
      Com<IMFSample> sample; check(MFCreateSample(&sample)); check(sample->AddBuffer(memory.Get())); check(sample->SetSampleTime(time));
      check(sample->SetSampleDuration(10000000 / fps)); time += 10000000 / fps;
      HRESULT hr = transform->ProcessInput(0, sample.Get(), 0);
      if (hr != MF_E_NOTACCEPTING) check(hr); accepted = SUCCEEDED(hr); if (accepted && asynchronous) needInput = false;
    }
    pollEvents();
    if (encoded.empty() && accepted && asynchronous) {
      auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(8);
      while (!haveOutput && std::chrono::steady_clock::now() < until) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); pollEvents(); }
    }
    return encoded.empty() ? readOutput() : encoded;
  }
};

struct Video::Impl {
  std::atomic<bool> stop{true}; std::thread thread; std::mutex encoderMutex;
  std::unique_ptr<Encoder> encoder; std::shared_ptr<std::atomic<bool>> forceKeyframe = std::make_shared<std::atomic<bool>>(false);
#ifdef CODEAW_WEBRTC
  std::shared_ptr<rtc::PeerConnection> peer; std::shared_ptr<rtc::Track> track;
  std::shared_ptr<rtc::RtpPacketizationConfig> rtp; std::shared_ptr<rtc::RtcpSrReporter> reporter;
#endif
};
Video::Video() : impl(std::make_unique<Impl>()) { MFStartup(MF_VERSION, MFSTARTUP_LITE); }
Video::~Video() { stop(); MFShutdown(); }
bool Video::supported() {
#ifdef CODEAW_WEBRTC
  return true;
#else
  return false;
#endif
}
bool Video::hardware() { return supported() && hasHardwareEncoder(); }
Json Video::selfTest() {
  Encoder encoder(640, 360, 30, 1000000, false);
  Frame frame; frame.width = 640; frame.height = 360; frame.pixels.resize(640 * 360 * 4, 255);
  size_t bytes = 0; bool annexB = false;
  for (int i = 0; i < 10; ++i) {
    frame.pixels[i * 4] = 0;
    auto encoded = encoder.encode(frame); bytes += encoded.size();
    annexB = annexB || (encoded.size() > 4 && encoded[0] == 0 && encoded[1] == 0 && (encoded[2] == 1 || (encoded[2] == 0 && encoded[3] == 1)));
  }
  if (!bytes || !annexB) throw std::runtime_error("H264 self-test failed");
  return {{"encodedBytes", bytes}, {"annexB", annexB}, {"width", 640}, {"height", 360}};
}
static Frame syntheticFrame(int index) {
  Frame frame; frame.width = 640; frame.height = 360; frame.pixels.resize(640 * 360 * 4, 255);
  for (int y = 40; y < 200; ++y) for (int x = index % 400; x < index % 400 + 120; ++x) {
    int i = (y * 640 + x) * 4; frame.pixels[i] = 80; frame.pixels[i + 1] = 120; frame.pixels[i + 2] = 0;
  }
  frame.cursor = {{"x", .5}, {"y", .5}, {"visible", false}}; return frame;
}
void Video::start(const std::string& monitor, int fps, int bitrate, int longEdge, const std::string& bindAddress, int epoch, bool synthetic) {
  stop();
#ifdef CODEAW_WEBRTC
  Capture probe;
  if (!synthetic) {
    probe.configure(monitor); auto bounds = probe.bounds();
    double w = bounds.right - bounds.left, h = bounds.bottom - bounds.top;
    longEdge = std::min(longEdge, int(std::max(w, h) * std::min(1.0, std::sqrt(1920.0 * 1080.0 / (w * h)))));
  }
  auto first = synthetic ? syntheticFrame(0) : probe.grab(longEdge); int width = first.width & ~1, height = first.height & ~1;
  bool accelerated = false;
  try { impl->encoder = std::make_unique<Encoder>(width, height, fps, bitrate, true); accelerated = true; }
  catch (...) { fps = 30; impl->encoder = std::make_unique<Encoder>(width, height, fps, bitrate, false); }
  rtc::Configuration config; config.disableAutoNegotiation = true;
  config.bindAddress = bindAddress;
  // No public STUN/TURN: media remains within the existing tailnet.
  impl->peer = std::make_shared<rtc::PeerConnection>(config);
  impl->peer->onLocalDescription([epoch](rtc::Description description) { output({{"event", {{"type", "offer"}, {"sdp", std::string(description)}, {"epoch", epoch}}}}); });
  impl->peer->onLocalCandidate([epoch](rtc::Candidate candidate) { output({{"event", {{"type", "candidate"}, {"candidate", std::string(candidate)}, {"mid", candidate.mid()}, {"epoch", epoch}}}}); });
  impl->peer->onStateChange([epoch](rtc::PeerConnection::State state) { if (state == rtc::PeerConnection::State::Failed) output({{"event", {{"type", "video-error"}, {"epoch", epoch}}}}); });
  rtc::Description::Video media("video", rtc::Description::Direction::SendOnly);
  media.addH264Codec(96, "profile-level-id=42e02a;packetization-mode=1;level-asymmetry-allowed=1"); media.addSSRC(42, "codeaw", "desktop", "video");
  impl->track = impl->peer->addTrack(media);
  impl->rtp = std::make_shared<rtc::RtpPacketizationConfig>(42, "codeaw", 96, rtc::H264RtpPacketizer::ClockRate);
  auto packetizer = std::make_shared<rtc::H264RtpPacketizer>(rtc::NalUnit::Separator::StartSequence, impl->rtp);
  impl->reporter = std::make_shared<rtc::RtcpSrReporter>(impl->rtp); packetizer->addToChain(impl->reporter);
  packetizer->addToChain(std::make_shared<rtc::RtcpNackResponder>());
  auto force = impl->forceKeyframe;
  packetizer->addToChain(std::make_shared<rtc::PliHandler>([force] { *force = true; }));
  impl->track->setMediaHandler(packetizer);
  impl->peer->setLocalDescription(); impl->stop = false;
  output({{"event", {{"type", "video-format"}, {"width", width}, {"height", height}, {"fps", fps}, {"hardware", accelerated}, {"epoch", epoch}}}});
  impl->thread = std::thread([this, monitor, longEdge, fps, width, height, epoch, synthetic, accelerated, bitrate]() mutable {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    try {
      Capture capture; if (!synthetic) capture.configure(monitor); bool first = true; std::vector<unsigned char> previous; std::string lastCursor; int index = 0;
      auto start = std::chrono::steady_clock::now(); auto next = start; double lastReport = -1;
      while (!impl->stop) {
        next += std::chrono::microseconds(1000000 / fps);
        if (impl->track && impl->track->isOpen()) {
          auto frame = synthetic ? syntheticFrame(index++) : capture.grab(longEdge);
          if ((frame.width & ~1) != width || (frame.height & ~1) != height) throw std::runtime_error("Display changed");
          auto pointer = frame.cursor; pointer["type"] = "cursor"; pointer["epoch"] = epoch;
          if (pointer.dump() != lastCursor) { lastCursor = pointer.dump(); output({{"event", pointer}}); }
          const bool requested = impl->forceKeyframe->exchange(false);
          {
            const bool changed = previous != frame.pixels || requested;
            std::vector<unsigned char> bytes;
            {
              std::lock_guard<std::mutex> lock(impl->encoderMutex);
              try {
                if (previous.empty() || requested) impl->encoder->keyframe();
                bytes = impl->encoder->encode(frame, changed);
                if (impl->encoder->accepted) previous = frame.pixels;
              }
              catch (...) {
                if (!accelerated) throw;
                fps = 30; accelerated = false; impl->encoder = std::make_unique<Encoder>(width, height, fps, bitrate, false); first = true;
                output({{"event", {{"type", "video-format"}, {"width", width}, {"height", height}, {"fps", fps}, {"hardware", false}, {"epoch", epoch}}}});
              }
            }
            if (!bytes.empty()) {
              auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
              impl->rtp->timestamp = impl->rtp->startTimestamp + impl->rtp->secondsToTimestamp(elapsed);
              if (elapsed - lastReport >= 1) { impl->reporter->setNeedsToReport(); lastReport = elapsed; }
              impl->track->send(reinterpret_cast<const std::byte*>(bytes.data()), bytes.size());
              if (first) { output({{"event", {{"type", "video-frame"}, {"width", width}, {"height", height}, {"epoch", epoch}}}}); first = false; }
            }
          }
        }
        std::this_thread::sleep_until(next); if (next < std::chrono::steady_clock::now() - std::chrono::milliseconds(100)) next = std::chrono::steady_clock::now();
      }
    } catch (...) { if (!impl->stop) output({{"event", {{"type", "video-error"}, {"epoch", epoch}}}}); }
    CoUninitialize();
  });
#else
  (void)monitor; (void)fps; (void)bitrate; (void)longEdge; (void)bindAddress; (void)epoch; (void)synthetic; throw std::runtime_error("WebRTC not built");
#endif
}
void Video::answer(const std::string& sdp) {
#ifdef CODEAW_WEBRTC
  if (impl->peer) { impl->peer->setRemoteDescription(rtc::Description(sdp, "answer")); *impl->forceKeyframe = true; }
#else
  (void)sdp;
#endif
}
void Video::candidate(const std::string& candidate, const std::string& mid) {
#ifdef CODEAW_WEBRTC
  if (impl->peer) impl->peer->addRemoteCandidate(rtc::Candidate(candidate, mid));
#else
  (void)candidate; (void)mid;
#endif
}
void Video::bitrate(int value) { std::lock_guard<std::mutex> lock(impl->encoderMutex); if (impl->encoder) impl->encoder->setBitrate(value); }
void Video::stop() {
  impl->stop = true; if (impl->thread.joinable()) impl->thread.join();
#ifdef CODEAW_WEBRTC
  if (impl->peer) impl->peer->close(); impl->track.reset(); impl->peer.reset(); impl->rtp.reset(); impl->reporter.reset();
#endif
  impl->encoder.reset();
}
