#ifndef RUNNER_MEDIA_CONTROLS_H_
#define RUNNER_MEDIA_CONTROLS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <shobjidl.h>
#include <windows.h>
#include <winrt/Windows.Media.h>

#include <atomic>
#include <memory>
#include <string>

// Windows' media controls (System Media Transport Controls): the keyboard's
// media keys, and the flyout by the volume indicator. Shows what the Dart
// side sends on the "blimp/media_controls" channel (see
// lib/services/media_controls.dart) and sends back the buttons pressed.
class MediaControls {
 public:
  // Presses arrive on a Windows thread pool thread; they're posted to the
  // window as this message and handed to Dart on the UI thread.
  static constexpr UINT kPressMessage = WM_APP + 1;

  // Posted as a kPressMessage's WPARAM by OutputWatch: the output playing
  // went (unplugged, disconnected), or an output came on. Dart decides
  // whether to pause, or to play again.
  static constexpr WPARAM kOutputGone = 0x101;
  static constexpr WPARAM kOutputBack = 0x102;

  MediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~MediaControls();

  // Handles a kPressMessage posted to the window.
  void HandlePress(WPARAM wparam, LPARAM lparam);

  // Explorer's "TaskbarButtonCreated": the window's taskbar button exists
  // (again), so its preview's buttons can be added.
  UINT taskbar_button_created_message() const {
    return taskbar_button_created_;
  }
  void HandleTaskbarButtonCreated();

  // A WM_COMMAND: true if it was one of the preview's buttons.
  bool HandleCommand(WPARAM wparam);

 private:
  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Sets the song's cover from a file, which Windows loads asynchronously.
  void SetThumbnail(const std::wstring& path);

  // Shows the preview's buttons as they are now: hidden with no song,
  // play or pause, next greyed out at the end of the queue.
  void UpdateThumbButtons();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  winrt::Windows::Media::SystemMediaTransportControls controls_{nullptr};
  winrt::event_token button_token_{};
  winrt::event_token seek_token_{};

  // Previous, play/pause and next under the window's taskbar preview.
  HWND window_;
  UINT taskbar_button_created_ = 0;
  ITaskbarList3* taskbar_ = nullptr;
  bool thumb_buttons_added_ = false;
  HICON icons_[4] = {};
  bool has_song_ = false;
  bool playing_ = false;
  bool can_next_ = false;

  // The cover file showing (or loading), empty for none.
  std::wstring thumbnail_;

  // Counts covers shown, so a slow cover can't land on the song after its own.
  std::shared_ptr<std::atomic<int>> generation_ =
      std::make_shared<std::atomic<int>>(0);
};

#endif  // RUNNER_MEDIA_CONTROLS_H_
