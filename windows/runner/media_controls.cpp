#include "media_controls.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <chrono>
#include <string>

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

namespace {

// Posted in place of a button for a seek from the flyout; the position, in
// milliseconds, comes as the message's LPARAM.
constexpr WPARAM kSeek = 0x100;

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

std::wstring WideString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? Wide(*text) : std::wstring();
}

bool Bool(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

int64_t Long(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  return value && !value->IsNull() ? value->LongValue() : 0;
}

TimeSpan Milliseconds(int64_t ms) {
  return std::chrono::duration_cast<TimeSpan>(std::chrono::milliseconds(ms));
}

}  // namespace

MediaControls::MediaControls(flutter::BinaryMessenger* messenger, HWND window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/media_controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });

  // A desktop app's controls belong to its window.
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls_)));
  } catch (const winrt::hresult_error&) {
    // No media controls on this Windows; calls from Dart do nothing.
    controls_ = nullptr;
    return;
  }
  controls_.IsPlayEnabled(true);
  controls_.IsPauseEnabled(true);
  controls_.IsStopEnabled(true);
  controls_.IsNextEnabled(true);
  controls_.IsPreviousEnabled(true);
  // Hidden until there's a song to show.
  controls_.IsEnabled(false);

  button_token_ = controls_.ButtonPressed(
      [window](const SystemMediaTransportControls&,
               const SystemMediaTransportControlsButtonPressedEventArgs& args) {
        PostMessage(window, kPressMessage, static_cast<WPARAM>(args.Button()),
                    0);
      });
  seek_token_ = controls_.PlaybackPositionChangeRequested(
      [window](const SystemMediaTransportControls&,
               const PlaybackPositionChangeRequestedEventArgs& args) {
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      args.RequestedPlaybackPosition())
                      .count();
        PostMessage(window, kPressMessage, kSeek, static_cast<LPARAM>(ms));
      });
}

MediaControls::~MediaControls() {
  if (!controls_) return;
  controls_.ButtonPressed(button_token_);
  controls_.PlaybackPositionChangeRequested(seek_token_);
  controls_.IsEnabled(false);
}

void MediaControls::HandlePress(WPARAM wparam, LPARAM lparam) {
  if (wparam == kOutputGone || wparam == kOutputBack) {
    channel_->InvokeMethod(
        "output", std::make_unique<EncodableValue>(
                      std::string(wparam == kOutputGone ? "gone" : "back")));
    return;
  }
  if (wparam == kSeek) {
    channel_->InvokeMethod(
        "seek", std::make_unique<EncodableValue>(static_cast<int64_t>(lparam)));
    return;
  }
  const char* name = nullptr;
  switch (static_cast<SystemMediaTransportControlsButton>(wparam)) {
    case SystemMediaTransportControlsButton::Play:
      name = "play";
      break;
    case SystemMediaTransportControlsButton::Pause:
      name = "pause";
      break;
    case SystemMediaTransportControlsButton::Stop:
      name = "stop";
      break;
    case SystemMediaTransportControlsButton::Next:
      name = "next";
      break;
    case SystemMediaTransportControlsButton::Previous:
      name = "previous";
      break;
    default:
      return;
  }
  channel_->InvokeMethod("button",
                         std::make_unique<EncodableValue>(std::string(name)));
}

void MediaControls::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (!controls_) {
    result->Success();
    return;
  }
  try {
    if (call.method_name() == "update" && args) {
      controls_.IsEnabled(true);
      controls_.PlaybackStatus(Bool(*args, "playing")
                                   ? MediaPlaybackStatus::Playing
                                   : MediaPlaybackStatus::Paused);
      controls_.IsPreviousEnabled(Bool(*args, "canPrevious"));
      controls_.IsNextEnabled(Bool(*args, "canNext"));

      auto updater = controls_.DisplayUpdater();
      updater.Type(MediaPlaybackType::Music);
      auto music = updater.MusicProperties();
      music.Title(WideString(*args, "title"));
      music.Artist(WideString(*args, "artist"));
      music.AlbumTitle(WideString(*args, "album"));
      // Cleared until the new song's cover has loaded, if it has one.
      updater.Thumbnail(nullptr);
      updater.Update();
      generation_->fetch_add(1);
      std::wstring art = WideString(*args, "art");
      if (!art.empty()) SetThumbnail(art);
    } else if (call.method_name() == "timeline" && args) {
      int64_t duration = Long(*args, "durationMs");
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(Milliseconds(0));
      timeline.MinSeekTime(Milliseconds(0));
      timeline.Position(Milliseconds(Long(*args, "positionMs")));
      timeline.MaxSeekTime(Milliseconds(duration));
      timeline.EndTime(Milliseconds(duration));
      controls_.UpdateTimelineProperties(timeline);
    } else if (call.method_name() == "clear") {
      controls_.DisplayUpdater().ClearAll();
      controls_.DisplayUpdater().Update();
      controls_.IsEnabled(false);
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  } catch (const winrt::hresult_error& error) {
    result->Error("media_controls", winrt::to_string(error.message()));
  }
}

void MediaControls::SetThumbnail(const std::wstring& path) {
  int generation = generation_->load();
  auto controls = controls_;
  auto current = generation_;
  // StorageFile only takes backslashes.
  std::wstring native = path;
  std::replace(native.begin(), native.end(), L'/', L'\\');
  StorageFile::GetFileFromPathAsync(native).Completed(
      [controls, current, generation](
          const IAsyncOperation<StorageFile>& operation, AsyncStatus status) {
        // The song changed while its cover loaded: leave the new one be.
        if (status != AsyncStatus::Completed || current->load() != generation) {
          return;
        }
        try {
          auto updater = controls.DisplayUpdater();
          updater.Thumbnail(
              RandomAccessStreamReference::CreateFromFile(operation.GetResults()));
          updater.Update();
        } catch (const winrt::hresult_error&) {
          // An unreadable cover: the controls just go without one.
        }
      });
}
