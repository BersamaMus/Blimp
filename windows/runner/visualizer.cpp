#include "visualizer.h"

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <vector>

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::FtmBase;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace {

// As Android's Visualizer (see VisualizerStreamHandler in AppChannels.kt):
// the samples each frame is worked out from, and its bands and points.
constexpr int kCaptureSize = 1024;
constexpr int kBands = 48;
constexpr int kFineBands = 96;
constexpr int kWavePoints = 96;
constexpr double kMinHz = 50.0;
constexpr double kMaxHz = 16000.0;
constexpr double kFloorDb = 18.0;
constexpr double kCeilingDb = 46.0;
constexpr double kTrebleFloorDropDb = 16.0;

// Android reports silence as this many dB below full scale.
constexpr double kSilenceDb = -96.0;

// About as often as Android captures; the view eases between frames.
constexpr auto kFrameInterval = std::chrono::milliseconds(50);

// Windows sends nothing while nothing plays: after this long without audio,
// frames show silence instead of the last sound held.
constexpr auto kQuietAfter = std::chrono::milliseconds(200);

constexpr double kPi = 3.14159265358979323846;

struct Frame {
  int generation;
  // Neither Blimp's audio nor the PC's could be captured.
  bool failed = false;
  EncodableValue value;
};

// The capture thread's way to the UI thread.
void Post(HWND window, Frame* frame) {
  if (!PostMessage(window, Visualizer::kFrameMessage, 0,
                   reinterpret_cast<LPARAM>(frame))) {
    delete frame;
  }
}

// In-place radix-2 FFT; |a|'s size is a power of two.
void Fft(std::vector<std::complex<double>>& a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; i++) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t length = 2; length <= n; length <<= 1) {
    const double angle = -2 * kPi / static_cast<double>(length);
    const std::complex<double> step(std::cos(angle), std::sin(angle));
    for (size_t i = 0; i < n; i += length) {
      std::complex<double> w(1);
      for (size_t k = 0; k < length / 2; k++) {
        const auto u = a[i + k];
        const auto v = a[i + k + length / 2] * w;
        a[i + k] = u + v;
        a[i + k + length / 2] = u - v;
        w *= step;
      }
    }
  }
}

// One part of a bin as Android's 8-bit FFT gives it: halved until it fits
// a byte, so the loudest bins are squashed rather than cut off.
double AndroidByte(double value) {
  if (!std::isfinite(value)) return 0;
  while (value > 127 || value < -128) value /= 2;
  return value;
}

// Groups FFT magnitudes into |count| log-spaced bands, each a 0..1 level.
// Android's bands(), in AppChannels.kt.
std::vector<double> Bands(const std::vector<double>& magnitude,
                          double sample_rate, int count) {
  const int bins = kCaptureSize / 2;
  const double bin_hz = sample_rate / kCaptureSize;
  std::vector<double> bands(count);
  for (int b = 0; b < count; b++) {
    const double low =
        kMinHz * std::pow(kMaxHz / kMinHz, static_cast<double>(b) / count) /
        bin_hz;
    const double high =
        kMinHz * std::pow(kMaxHz / kMinHz, (b + 1.0) / count) / bin_hz;
    double peak = 0;
    if (high - low < 1) {
      // Bass bands are narrower than a bin: interpolate between the nearest
      // two, so neighbouring bands don't all read the same.
      const double center = std::clamp((low + high) / 2, 1.0, bins - 2.0);
      const int k = static_cast<int>(center);
      const double frac = center - k;
      peak = magnitude[k] * (1 - frac) + magnitude[k + 1] * frac;
    } else {
      const int from = std::clamp(static_cast<int>(low), 1, bins - 1);
      const int to = std::clamp(static_cast<int>(high), 1, bins - 1);
      for (int k = from; k <= to; k++) peak = std::max(peak, magnitude[k]);
    }
    // Higher frequencies carry far less energy; lower the floor towards the
    // treble so that end isn't flat.
    const double x = static_cast<double>(b) / count;
    const double floor = kFloorDb - kTrebleFloorDropDb * x;
    const double db = 20 * std::log10(peak + 1);
    bands[b] = std::clamp((db - floor) / (kCeilingDb - floor), 0.0, 1.0);
  }
  return bands;
}

// A frame from the last kCaptureSize samples, oldest first, mixed to mono.
// Scaled to full range as Android's are, so it gives the spectrum's and the
// waveform's shape; "rms" says how loud the music really is.
EncodableValue MakeFrame(const std::vector<float>& samples, double sample_rate,
                         bool whole_pc) {
  const size_t n = samples.size();
  double sum = 0, loudest = 0;
  for (float s : samples) {
    sum += static_cast<double>(s) * s;
    loudest = std::max(loudest, std::abs(static_cast<double>(s)));
  }
  const double rms = std::sqrt(sum / n);
  const double rms_db =
      rms > 0 ? std::max(kSilenceDb, 20 * std::log10(rms)) : kSilenceDb;

  // In Android's 8-bit sample units.
  const double scale = loudest > 1e-5 ? 128.0 / loudest : 0;
  std::vector<std::complex<double>> fft(n);
  for (size_t i = 0; i < n; i++) fft[i] = samples[i] * scale;
  Fft(fft);
  std::vector<double> magnitude(n / 2);
  for (size_t k = 0; k < n / 2; k++) {
    // Android's fixed-point FFT comes out at 16 / n of a plain DFT.
    magnitude[k] = std::hypot(AndroidByte(fft[k].real() * 16 / n),
                              AndroidByte(fft[k].imag() * 16 / n));
  }

  std::vector<double> wave(kWavePoints);
  for (int i = 0; i < kWavePoints; i++) {
    wave[i] = samples[i * n / kWavePoints] * scale / 128;
  }

  return EncodableValue(EncodableMap{
      {EncodableValue("bands"),
       EncodableValue(Bands(magnitude, sample_rate, kBands))},
      {EncodableValue("fineBands"),
       EncodableValue(Bands(magnitude, sample_rate, kFineBands))},
      {EncodableValue("wave"), EncodableValue(wave)},
      {EncodableValue("rms"), EncodableValue(rms_db)},
      {EncodableValue("wholePc"), EncodableValue(whole_pc)},
  });
}

// Waits for Windows to hand over the process loopback's audio client.
class ActivationHandler
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase,
                          IActivateAudioInterfaceCompletionHandler> {
 public:
  ActivationHandler() : done_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~ActivationHandler() override { CloseHandle(done_); }

  STDMETHOD(ActivateCompleted)
  (IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT result = E_FAIL;
    ComPtr<IUnknown> client;
    if (SUCCEEDED(operation->GetActivateResult(&result, &client)) &&
        SUCCEEDED(result)) {
      client.As(&client_);
    }
    SetEvent(done_);
    return S_OK;
  }

  ComPtr<IAudioClient> Wait() {
    return WaitForSingleObject(done_, 2000) == WAIT_OBJECT_0 ? client_
                                                              : nullptr;
  }

 private:
  HANDLE done_;
  ComPtr<IAudioClient> client_;
};

// What Blimp plays, its player included: the process loopback, Windows 10
// build 20348 and later. Null on older Windows.
ComPtr<IAudioClient> BlimpAudio(WAVEFORMATEX& format, HANDLE ready) {
  AUDIOCLIENT_ACTIVATION_PARAMS params{};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  PROPVARIANT activation{};
  activation.vt = VT_BLOB;
  activation.blob.cbSize = sizeof(params);
  activation.blob.pBlobData = reinterpret_cast<BYTE*>(&params);

  auto handler = Make<ActivationHandler>();
  ComPtr<IActivateAudioInterfaceAsyncOperation> operation;
  if (FAILED(ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK,
                                         __uuidof(IAudioClient), &activation,
                                         handler.Get(), &operation))) {
    return nullptr;
  }
  ComPtr<IAudioClient> client = handler->Wait();
  if (!client) return nullptr;

  // It has no mix format of its own to ask for; Windows converts to this.
  format = {};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = 2;
  format.nSamplesPerSec = 44100;
  format.wBitsPerSample = 16;
  format.nBlockAlign = format.nChannels * format.wBitsPerSample / 8;
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  if (FAILED(client->Initialize(
          AUDCLNT_SHAREMODE_SHARED,
          AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
              AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM,
          2000000, 0, &format, nullptr)) ||
      FAILED(client->SetEventHandle(ready))) {
    return nullptr;
  }
  return client;
}

// Everything the PC plays, through the default speakers or headphones.
ComPtr<IAudioClient> PcAudio(WAVEFORMATEX*& format) {
  ComPtr<IMMDeviceEnumerator> devices;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&devices))) ||
      FAILED(devices->GetDefaultAudioEndpoint(eRender, eConsole, &device)) ||
      FAILED(device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                              &client)) ||
      FAILED(client->GetMixFormat(&format))) {
    return nullptr;
  }
  if (FAILED(client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000, 0,
                                format, nullptr))) {
    return nullptr;
  }
  return client;
}

// Whether |format|'s samples are floats; otherwise they're whole numbers.
bool IsFloat(const WAVEFORMATEX& format) {
  if (format.wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (format.wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    // The subformat's first part is the format's own tag.
    const auto& extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE&>(format);
    return extensible.SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
  }
  return false;
}

void Capture(HWND window, int generation,
             std::shared_ptr<std::atomic<bool>> running) {
  const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
  HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);

  WAVEFORMATEX own_format{};
  WAVEFORMATEX* pc_format = nullptr;
  bool whole_pc = false;
  ComPtr<IAudioClient> client = BlimpAudio(own_format, ready);
  const WAVEFORMATEX* format = &own_format;
  if (!client) {
    client = PcAudio(pc_format);
    format = pc_format;
    whole_pc = true;
  }
  ComPtr<IAudioCaptureClient> capture;
  const bool is_float = format && IsFloat(*format);
  const bool readable =
      format && (is_float ? format->wBitsPerSample == 32
                          : format->wBitsPerSample == 16);
  if (!client || !readable ||
      FAILED(client->GetService(IID_PPV_ARGS(&capture))) ||
      FAILED(client->Start())) {
    Post(window, new Frame{generation, true, EncodableValue()});
  } else {
    const int channels = format->nChannels;
    const double sample_rate = format->nSamplesPerSec;
    std::vector<float> ring(kCaptureSize, 0.0f);
    size_t next_write = 0;
    auto now = std::chrono::steady_clock::now();
    auto next_frame = now;
    auto last_audio = now;
    while (*running) {
      // The process loopback says when audio's ready; the PC's is checked.
      if (whole_pc) {
        Sleep(10);
      } else {
        WaitForSingleObject(ready, 20);
      }
      UINT32 packet = 0;
      while (SUCCEEDED(capture->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr,
                                      nullptr))) {
          break;
        }
        const bool silent = flags & AUDCLNT_BUFFERFLAGS_SILENT;
        for (UINT32 f = 0; f < frames; f++) {
          float mono = 0;
          if (!silent) {
            for (int c = 0; c < channels; c++) {
              mono += is_float
                          ? reinterpret_cast<const float*>(data)[f * channels + c]
                          : reinterpret_cast<const int16_t*>(
                                data)[f * channels + c] /
                                32768.0f;
            }
            mono /= channels;
          }
          ring[next_write] = mono;
          next_write = (next_write + 1) % kCaptureSize;
        }
        capture->ReleaseBuffer(frames);
        if (frames > 0) last_audio = std::chrono::steady_clock::now();
      }

      now = std::chrono::steady_clock::now();
      if (now < next_frame) continue;
      next_frame = now + kFrameInterval;
      if (now - last_audio > kQuietAfter) {
        std::fill(ring.begin(), ring.end(), 0.0f);
      }
      std::vector<float> samples(kCaptureSize);
      for (size_t i = 0; i < kCaptureSize; i++) {
        samples[i] = ring[(next_write + i) % kCaptureSize];
      }
      Post(window,
           new Frame{generation, false,
                     MakeFrame(samples, sample_rate, whole_pc)});
    }
    client->Stop();
  }

  capture.Reset();
  client.Reset();
  if (pc_format) CoTaskMemFree(pc_format);
  CloseHandle(ready);
  if (com) CoUninitialize();
}

}  // namespace

Visualizer::Visualizer(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, "blimp/visualizer",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = std::move(events);
            Start();
            return nullptr;
          },
          [this](const EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            Stop();
            sink_ = nullptr;
            return nullptr;
          }));
}

Visualizer::~Visualizer() { Stop(); }

void Visualizer::HandleFrame(LPARAM lparam) {
  std::unique_ptr<Frame> frame(reinterpret_cast<Frame*>(lparam));
  if (!sink_ || frame->generation != generation_) return;
  if (frame->failed) {
    sink_->Error("visualizer_unavailable",
                 "Windows won't share the audio that's playing.");
  } else {
    sink_->Success(frame->value);
  }
}

void Visualizer::Drop(LPARAM lparam) { delete reinterpret_cast<Frame*>(lparam); }

void Visualizer::Start() {
  Stop();
  generation_++;
  running_ = std::make_shared<std::atomic<bool>>(true);
  thread_ = std::thread(Capture, window_, generation_, running_);
}

void Visualizer::Stop() {
  if (running_) *running_ = false;
  if (thread_.joinable()) thread_.join();
}
