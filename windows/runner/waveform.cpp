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

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

struct Job {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  std::optional<std::vector<double>> levels;
};

// How much of each slice is decoded to judge how loud it is, in seconds.
// Decoding all of a song takes many seconds; an eighth of a second from the
// middle of each slice is enough to tell.
constexpr double kBurstSeconds = 0.125;

// Reads that bring no audio (a gap, a format change) before a slice is
// given up on.
constexpr int kMaxEmptyReads = 64;

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

// How loud the file is across |points| equal slices of it, each the root
// mean square of its samples (0..1); nothing if it can't be decoded.
std::optional<std::vector<double>> SampleLevels(const std::wstring& path,
                                                int points) {
  const auto stream = static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM);
  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(path.c_str(), nullptr, &reader))) {
    return std::nullopt;
  }
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  if (FAILED(reader->SetStreamSelection(stream, TRUE))) return std::nullopt;

  // Decoded to 32-bit float samples, whatever the file holds.
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

  // In units of 100 nanoseconds.
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

  const size_t burst = static_cast<size_t>(rate * kBurstSeconds) * channels;
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

}  // namespace

Waveform::Waveform(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/waveform",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() != "levels") {
      result->NotImplemented();
      return;
    }
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const std::string* path = nullptr;
    int points = 0;
    if (args) {
      if (auto it = args->find(EncodableValue("path")); it != args->end()) {
        path = std::get_if<std::string>(&it->second);
      }
      if (auto it = args->find(EncodableValue("points")); it != args->end()) {
        if (const auto* n = std::get_if<int32_t>(&it->second)) points = *n;
      }
    }
    if (!path || points <= 0) {
      result->Error("bad_args", "Needs a path and a number of points.");
      return;
    }
    std::wstring file = Wide(*path);
    std::replace(file.begin(), file.end(), L'/', L'\\');
    auto* job = new Job{std::move(result), std::nullopt};
    std::thread([window, job, file, points]() {
      const bool com = SUCCEEDED(CoInitializeEx(nullptr, COINIT_MULTITHREADED));
      if (SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
        job->levels = SampleLevels(file, points);
        MFShutdown();
      }
      if (com) CoUninitialize();
      if (!PostMessage(window, kDoneMessage, 0, reinterpret_cast<LPARAM>(job))) {
        Drop(reinterpret_cast<LPARAM>(job));
      }
    }).detach();
  });
}

void Waveform::HandleDone(LPARAM lparam) {
  std::unique_ptr<Job> job(reinterpret_cast<Job*>(lparam));
  if (job->levels) {
    job->result->Success(EncodableValue(*job->levels));
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
