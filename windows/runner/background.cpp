#include "background.h"

#include <flutter/standard_method_codec.h>

#include <string>

#include "resource.h"
#include "utils.h"

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// The tray menu's items.
enum MenuItem : UINT {
  kOpen = 1,
  kPlayPause,
  kNext,
  kPrevious,
  kQuit,
};

}  // namespace

Background::Background(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  // How a second copy of Blimp finds this window, now that the title
  // changes with the song.
  SetPropW(window_, kWindowMark, reinterpret_cast<HANDLE>(1));

  // The tray's own small size, so it isn't a big icon scaled down.
  icon_ = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  icon_data_.cbSize = sizeof(icon_data_);
  icon_data_.hWnd = window_;
  icon_data_.uID = 1;
  icon_data_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  icon_data_.uCallbackMessage = kTrayMessage;
  icon_data_.hIcon = icon_;
  wcscpy_s(icon_data_.szTip, L"Blimp");
}

Background::~Background() {
  RemoveIcon();
  RemovePropW(window_, kWindowMark);
  if (icon_) DestroyIcon(icon_);
}

bool Background::HandleClose() {
  // Back to the full window first, so that's the size kept for next time
  // and what comes back from the tray.
  SetCompact(false);
  if (quitting_) return false;
  switch (close_action_) {
    case CloseAction::kQuit:
      return false;
    case CloseAction::kBackground:
      Hide(false);
      return true;
    case CloseAction::kAsk:
      // Closed from the taskbar while minimized: shown, so the question is
      // seen.
      if (IsIconic(window_)) ShowWindow(window_, SW_RESTORE);
      channel_->InvokeMethod("closeRequested", nullptr);
      return true;
  }
  return false;
}

void Background::HandleTray(WPARAM, LPARAM lparam) {
  // NOTIFYICON_VERSION_4: the event is in the low word.
  switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
      Restore();
      break;
    case WM_CONTEXTMENU:
      ShowMenu();
      break;
  }
}

void Background::Restore() {
  RemoveIcon();
  // Comes back as it was, maximized or not.
  if (IsIconic(window_)) {
    ShowWindow(window_, SW_RESTORE);
  } else {
    ShowWindow(window_, SW_SHOW);
  }
  SetForegroundWindow(window_);
}

void Background::HandleTaskbarCreated() {
  if (!in_tray_) return;
  in_tray_ = false;
  AddIcon();
}

void Background::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "setCloseAction") {
    const auto* action = std::get_if<std::string>(call.arguments());
    close_action_ = !action                 ? CloseAction::kQuit
                    : *action == "background" ? CloseAction::kBackground
                    : *action == "ask"        ? CloseAction::kAsk
                                              : CloseAction::kQuit;
    result->Success();
  } else if (method == "hide") {
    const auto* notice = std::get_if<bool>(call.arguments());
    Hide(notice && *notice);
    result->Success();
  } else if (method == "setCompact") {
    const auto* compact = std::get_if<bool>(call.arguments());
    result->Success();
    PostMessage(window_, kCompactMessage, compact && *compact ? 1 : 0, 0);
  } else if (method == "setTitle") {
    const auto* title = std::get_if<std::string>(call.arguments());
    SetWindowTextW(window_, title ? Utf16FromUtf8(*title).c_str() : L"Blimp");
    result->Success();
  } else if (method == "quit") {
    result->Success();
    Quit();
  } else {
    result->NotImplemented();
  }
}

void Background::Hide(bool notice) {
  ShowWindow(window_, SW_HIDE);
  AddIcon();
  if (notice && in_tray_) {
    // Once, the first time: says where Blimp went.
    NOTIFYICONDATAW balloon = icon_data_;
    balloon.uFlags = NIF_INFO;
    balloon.dwInfoFlags = NIIF_USER | NIIF_LARGE_ICON;
    balloon.hBalloonIcon = icon_;
    wcscpy_s(balloon.szInfoTitle, L"Blimp is still playing");
    wcscpy_s(balloon.szInfo,
             L"It's here by the clock. Click to open it, or right-click to "
             L"quit.");
    Shell_NotifyIconW(NIM_MODIFY, &balloon);
  }
}

void Background::SetCompact(bool compact) {
  if (compact == compact_) return;
  if (compact) {
    normal_placement_.length = sizeof(WINDOWPLACEMENT);
    GetWindowPlacement(window_, &normal_placement_);
    if (IsZoomed(window_)) ShowWindow(window_, SW_RESTORE);
    // Before resizing, so the window's smallest size lets it.
    compact_ = true;
    UINT dpi = GetDpiForWindow(window_);
    RECT frame{0, 0, MulDiv(kCompactWidth, dpi, 96),
               MulDiv(kCompactHeight, dpi, 96)};
    AdjustWindowRectExForDpi(
        &frame, static_cast<DWORD>(GetWindowLongPtr(window_, GWL_STYLE)),
        FALSE, static_cast<DWORD>(GetWindowLongPtr(window_, GWL_EXSTYLE)),
        dpi);
    // Where it is, just smaller, and above other windows.
    RECT now;
    GetWindowRect(window_, &now);
    SetWindowPos(window_, HWND_TOPMOST, now.left, now.top,
                 frame.right - frame.left, frame.bottom - frame.top, 0);
  } else {
    compact_ = false;
    SetWindowPos(window_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetWindowPlacement(window_, &normal_placement_);
  }
  // Now the window is its new size.
  channel_->InvokeMethod("compactChanged",
                         std::make_unique<EncodableValue>(compact));
}

void Background::Quit() {
  RemoveIcon();
  // Through WM_CLOSE, as from the X, but this time it closes. Posted, so the
  // window isn't destroyed in the middle of the call that asked for it.
  quitting_ = true;
  PostMessage(window_, WM_CLOSE, 0, 0);
}

void Background::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kOpen, L"Open Blimp");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kPlayPause, L"Play / Pause");
  AppendMenuW(menu, MF_STRING, kNext, L"Next");
  AppendMenuW(menu, MF_STRING, kPrevious, L"Previous");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuit, L"Quit");
  SetMenuDefaultItem(menu, kOpen, FALSE);

  POINT at;
  GetCursorPos(&at);
  // Without this the menu stays open when clicked away from.
  SetForegroundWindow(window_);
  UINT item = TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, at.x, at.y,
      window_, nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);

  switch (item) {
    case kOpen:
      Restore();
      break;
    case kPlayPause:
      channel_->InvokeMethod(
          "tray", std::make_unique<EncodableValue>(std::string("playPause")));
      break;
    case kNext:
      channel_->InvokeMethod(
          "tray", std::make_unique<EncodableValue>(std::string("next")));
      break;
    case kPrevious:
      channel_->InvokeMethod(
          "tray", std::make_unique<EncodableValue>(std::string("previous")));
      break;
    case kQuit:
      Quit();
      break;
  }
}

void Background::AddIcon() {
  if (in_tray_) return;
  if (!Shell_NotifyIconW(NIM_ADD, &icon_data_)) return;
  NOTIFYICONDATAW version = icon_data_;
  version.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &version);
  in_tray_ = true;
}

void Background::RemoveIcon() {
  if (!in_tray_) return;
  Shell_NotifyIconW(NIM_DELETE, &icon_data_);
  in_tray_ = false;
}
