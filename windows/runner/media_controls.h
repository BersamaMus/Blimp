#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <winrt/Windows.Media.h>

#include <atomic>
#include <memory>

// Windows' media controls (System Media Transport Controls): the keyboard's
// media keys, and the flyout by the volume indicator. Shows what the Dart
// side sends on the "blimp/media_controls" channel (see
// lib/services/media_controls.dart) and sends back the buttons pressed.
class MediaControls {
 public:
  // Presses arrive on a Windows thread pool thread; they're posted to the
  // window as this message and handed to Dart on the UI thread.
  static constexpr UINT kPressMessage = WM_APP + 1;

  MediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaControls();

  // Handles a kPressMessage posted to the window.
  void HandlePress(WPARAM wparam, LPARAM lparam);

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Sets the song's cover from a file, which Windows loads asynchronously.
  void SetThumbnail(const std::wstring& path);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token seek_token_{};

  // Counts songs shown, so a slow cover can't land on the song after its own.
  std::shared_ptr<std::atomic<int>> generation_ =
      std::make_shared<std::atomic<int>>(0);
};

#endif  // RUNNER_MEDIA_CONTROLS_H_
