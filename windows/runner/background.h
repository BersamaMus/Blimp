#ifndef RUNNER_BACKGROUND_H_
#define RUNNER_BACKGROUND_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
// After windows.h, which it needs.
#include <shellapi.h>

#include <memory>

// Running in the background: closing the window can hide it, with Blimp's
// icon in the system tray by the clock, instead of quitting. What closing
// does is set from the Dart side on the "blimp/window" channel (see
// lib/services/desktop_window.dart), which also asks the first time.
class Background {
 public:
  // From the tray icon.
  static constexpr UINT kTrayMessage = WM_APP + 3;
  // From a second copy of Blimp started while this one runs: brings this
  // one's window back instead.
  static constexpr UINT kShowMessage = WM_APP + 4;

  Background(flutter::BinaryMessenger* messenger, HWND window);
  ~Background();

  // For WM_CLOSE: true if it's been handled (hidden, or asked about), so the
  // window mustn't be destroyed.
  bool HandleClose();

  // Handles a kTrayMessage.
  void HandleTray(WPARAM wparam, LPARAM lparam);

  // Shows the window again, from the tray or a second copy of Blimp.
  void Restore();

  // Handles Explorer's TaskbarCreated: it restarted, and the icon with it is
  // gone.
  void HandleTaskbarCreated();

  UINT taskbar_created_message() const { return taskbar_created_; }

  // Closes the window for good, even with closing set to hide it.
  void Quit();

 private:
  enum class CloseAction { kQuit, kAsk, kBackground };

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Hides the window to the tray; [notice] says where it went.
  void Hide(bool notice);

  void ShowMenu();
  void AddIcon();
  void RemoveIcon();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HICON icon_ = nullptr;
  NOTIFYICONDATAW icon_data_{};
  UINT taskbar_created_ = 0;

  // Until Dart says otherwise, closing quits, as an app should whose UI
  // hasn't started.
  CloseAction close_action_ = CloseAction::kQuit;
  bool in_tray_ = false;
  bool quitting_ = false;
};

#endif  // RUNNER_BACKGROUND_H_
