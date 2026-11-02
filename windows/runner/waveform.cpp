#include "waveform.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <thread>
#include <vector>

#include "utils.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

// Mono samples from places in a file, one piece after another.
struct Bursts {
  int32_t rate = 0;
  std::vector<float> samples;
  std::vector<int32_t> lengths;
};

struct Job {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  std::optional<std::vector<double>> levels;
  std::optional<Bursts> bursts;
};

// How much of each slice is decoded to judge how loud it is, in seconds.
// Decoding all of a song takes many seconds; an eighth of a second from the
// middle of each slice is enough to tell.
constexpr double kBurstSeconds = 0.125;

// Reads that bring no audio (a gap, a format change) before a slice is
// given up on.
constexpr int kMaxEmptyReads = 64;

const auto kStream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);

struct Audio {
  ComPtr<IMFSourceReader> reader;
  UINT32 rate = 0;
  UINT32 channels = 0;
  // In units of 100 nanoseconds.
  LONGLONG duration = 0;
};

// Opens the file to decode to 32-bit float samples, whatever it holds;
// nothing if it can't be.
std::optional<Audio> OpenAudio(const std::wstring& path) {
  const auto stream = kStream;
  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    return std::nullopt;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  if (FAILED(reader->SetStreamSelection(stream, TRUE))) return std::nullopt;

  ComPtr<IMFMediaType> wanted;
  if (FAILED(MFCreateMediaType(&wanted))) return std::nullopt;
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  wanted->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
  if (FAILED(reader->SetCurrentMediaType(stream, nullptr, wanted.Get()))) {
    return std::nullopt;
  }
  ComPtr<IMFMediaType> actual;
  if (FAILED(reader->GetCurrentMediaType(stream, &actual))) {
    return std::nullopt;
  }
  UINT32 rate =
      MFGetAttributeUINT32(actual.Get(), MF_MT_AUDIO_SAMPLES_PER_SECOND, 0);
  UINT32 channels =
      MFGetAttributeUINT32(actual.Get(), MF_MT_AUDIO_NUM_CHANNELS, 0);
  if (rate == 0 || channels == 0) return std::nullopt;

  PROPVARIANT value;
  PropVariantInit(&value);
  if (FAILED(reader->GetPresentationAttribute(
          static_cast<DWORD>(MF_SOURCE_READER_MEDIASOURCE), MF_PD_DURATION,
          &value))) {
    return std::nullopt;
  }
  const auto duration = static_cast<LONGLONG>(value.uhVal.QuadPart);
  PropVariantClear(&value);
  if (duration <= 0) return std::nullopt;
  return Audio{reader, rate, channels, duration};
}

// How loud the file is across |points| equal slices of it, each the root
// mean square of its samples (0..1); nothing if it can't be decoded.
std::optional<std::vector<double>> SampleLevels(const std::wstring& path,
                                                int points) {
  auto audio = OpenAudio(path);
  if (!audio) return std::nullopt;
  const auto stream = kStream;
  auto& reader = audio->reader;
  const LONGLONG duration = audio->duration;
  const size_t burst =
      static_cast<size_t>(audio->rate * kBurstSeconds) * audio->channels;
  std::vector<double> levels(points, 0.0);
  int unread = 0;
  for (int slice = 0; slice < points; slice++) {
    PROPVARIANT at;
    PropVariantInit(&at);
    at.vt = VT_I8;
    at.hVal.QuadPart =
        static_cast<LONGLONG>((slice + 0.5) * duration / points);
    double sum = 0;
    size_t count = 0;
    int empty = 0;
    bool ok = SUCCEEDED(reader->SetCurrentPosition(GUID_NULL, at));
    while (ok && count < burst && empty < kMaxEmptyReads) {
      DWORD flags = 0;
      ComPtr<IMFSample> sample;
      if (FAILED(reader->ReadSample(stream, 0, nullptr, &flags, nullptr,
                                    &sample)) ||
          (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
        break;
      }
      ComPtr<IMFMediaBuffer> buffer;
      BYTE* data = nullptr;
      DWORD length = 0;
      if (!sample || FAILED(sample->ConvertToContiguousBuffer(&buffer)) ||
          FAILED(buffer->Lock(&data, nullptr, &length))) {
        empty++;
        continue;
      }
      const auto* samples = reinterpret_cast<const float*>(data);
      const size_t n = length / sizeof(float);
      for (size_t i = 0; i < n; i++) {
        sum += static_cast<double>(samples[i]) * samples[i];
      }
      count += n;
      if (n == 0) empty++;
      buffer->Unlock();
    }
    if (count == 0) {
      unread++;
    } else {
      levels[slice] = std::sqrt(sum / count);
    }
  }
  // A slice that couldn't be read at all means the file can't be decoded
  // properly: no waveform with holes in it.
  if (unread > points / 10) return std::nullopt;
  return levels;
}

// |seconds| of the file from each of |starts| (in seconds), mixed to mono
// and keeping every |every|th sample; nothing if it can't be decoded. A piece
// is shorter if the song ends first.
std::optional<Bursts> ReadBursts(const std::wstring& path,
                                 const std::vector<double>& starts,
                                 double seconds, int every) {
  auto audio = OpenAudio(path);
  if (!audio) return std::nullopt;
  const auto stream = kStream;
  auto& reader = audio->reader;
  const size_t channels = audio->channels;
  const auto wanted = static_cast<size_t>(audio->rate * seconds);
  Bursts bursts;
  bursts.rate = static_cast<int32_t>(audio->rate) / every;
  for (const double start : starts) {
    PROPVARIANT at;
    PropVariantInit(&at);
    at.vt = VT_I8;
    at.hVal.QuadPart = static_cast<LONGLONG>(start * 10000000);
    const size_t before = bursts.samples.size();
    size_t frames = 0;
    int empty = 0;
    bool ok = SUCCEEDED(reader->SetCurrentPosition(GUID_NULL, at));
    while (ok && frames < wanted && empty < kMaxEmptyReads) {
      DWORD flags = 0;
      ComPtr<IMFSample> sample;
      if (FAILED(reader->ReadSample(stream, 0, nullptr, &flags, nullptr,
                                    &sample)) ||
          (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
        break;
      }
      ComPtr<IMFMediaBuffer> buffer;
      BYTE* data = nullptr;
      DWORD length = 0;
      if (!sample || FAILED(sample->ConvertToContiguousBuffer(&buffer)) ||
          FAILED(buffer->Lock(&data, nullptr, &length))) {
        empty++;
        continue;
      }
      const auto* samples = reinterpret_cast<const float*>(data);
      const size_t n = length / sizeof(float) / channels;
      for (size_t i = 0; i < n && frames < wanted; i++, frames++) {
        if (frames % every != 0) continue;
        float mixed = 0;
        for (size_t c = 0; c < channels; c++) {
          mixed += samples[i * channels + c];
        }
        bursts.samples.push_back(mixed / channels);
      }
      if (n == 0) empty++;
      buffer->Unlock();
    }
    bursts.lengths.push_back(
        static_cast<int32_t>(bursts.samples.size() - before));
  }
  return bursts;
}

// Runs |work| on a thread of its own, with Media Foundation started, and
// answers |job| on the window's thread.
template <typename Work>
void RunJob(HWND window, Job* job, Work work) {
  std::thread([window, job, work]() {
    const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
    if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
      work(*job);
      MFShutdown();
    }
    if (com) CoUninitialize();
    if (!PostMessage(window, Waveform::kDoneMessage, 0, reinterpret_cast<LPARAM>(job))) {
      Waveform::Drop(reinterpret_cast<LPARAM>(job));
    }
  }).detach();
}

// The value under |key| in |args|, if it's a |T|.
template <typename T>
const T* Arg(const EncodableMap* args, const char* key) {
  if (!args) return nullptr;
  auto it = args->find(EncodableValue(key));
  return it == args->end() ? nullptr : std::get_if<T>(&it->second);
}

}  // namespace

Waveform::Waveform(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/waveform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([window](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const auto* path = Arg<std::string>(args, "path");
    if (call.method_name() == "samples") {
      const auto* starts = Arg<std::vector<double>>(args, "starts");
      const auto* seconds = Arg<double>(args, "seconds");
      const auto* every = Arg<int32_t>(args, "every");
      if (!path || !starts || !seconds || !every || *every <= 0) {
        result->Error("bad_args", "Needs a path, starts, seconds and every.");
        return;
      }
      std::wstring file = Utf16FromUtf8(*path);
      std::replace(file.begin(), file.end(), L'/', L'\\');
      RunJob(window, new Job{std::move(result), std::nullopt, std::nullopt},
             [file, starts = *starts, seconds = *seconds,
              every = *every](Job& job) {
               job.bursts = ReadBursts(file, starts, seconds, every);
             });
      return;
    }
    if (call.method_name() != "levels") {
      result->NotImplemented();
      return;
    }
    const auto* count = Arg<int32_t>(args, "points");
    const int points = count ? *count : 0;
    if (!path || points <= 0) {
      result->Error("bad_args", "Needs a path and a number of points.");
      return;
    }
    std::wstring file = Utf16FromUtf8(*path);
    std::replace(file.begin(), file.end(), L'/', L'\\');
    RunJob(window, new Job{std::move(result), std::nullopt, std::nullopt},
           [file, points](Job& job) { job.levels = SampleLevels(file, points); });
  });
}

void Waveform::HandleDone(LPARAM lparam) {
  std::unique_ptr<Job> job(reinterpret_cast<Job*>(lparam));
  if (job->levels) {
    job->result->Success(EncodableValue(*job->levels));
  } else if (job->bursts) {
    job->result->Success(EncodableValue(EncodableMap{
        {EncodableValue("rate"), EncodableValue(job->bursts->rate)},
        {EncodableValue("samples"), EncodableValue(job->bursts->samples)},
        {EncodableValue("lengths"), EncodableValue(job->bursts->lengths)},
    }));
  } else {
    job->result->Success();
  }
}

void Waveform::Drop(LPARAM lparam) {
  std::unique_ptr<Job> job(reinterpret_cast<Job*>(lparam));
  // Left unanswered and undeleted: its engine is gone, and deleting it would
  // try to reply through it.
  job->result.release();
}
