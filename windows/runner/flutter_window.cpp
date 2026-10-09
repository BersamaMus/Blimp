#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "window_placement.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Before the Flutter view is sized to it.
  show_maximized_ = RestoreWindowPlacement(GetHandle());
  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  media_controls_ = std::make_unique<MediaControls>(
      flutter_controller_->engine()->messenger(), GetHandle());
  background_ = std::make_unique<Background>(
      flutter_controller_->engine()->messenger(), GetHandle());
  output_watch_ = std::make_unique<OutputWatch>(GetHandle());
  share_ = std::make_unique<Share>(
      flutter_controller_->engine()->messenger(), GetHandle());
  visualizer_ = std::make_unique<Visualizer>(
      flutter_controller_->engine()->messenger(), GetHandle());
  waveform_ = std::make_unique<Waveform>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (show_maximized_) {
      ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    } else {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  media_controls_ = nullptr;
  output_watch_ = nullptr;
  share_ = nullptr;
  visualizer_ = nullptr;
  waveform_ = nullptr;
  background_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (background_ && message == background_->taskbar_created_message()) {
    background_->HandleTaskbarCreated();
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      // Saved now: by WM_DESTROY the window's placement is gone. Not while
      // it's hidden in the tray: it was saved as it was hidden.
      if (IsWindowVisible(hwnd)) SaveWindowPlacement(hwnd);
      // Hidden to the tray instead, or asked about.
      if (background_ && background_->HandleClose()) return 0;
      break;
    case WM_ENDSESSION:
      // Signing out, or an update closing Blimp: quits even from the tray,
      // which would otherwise only hide it.
      if (wparam && background_) background_->Quit();
      return 0;
    case Visualizer::kFrameMessage:
      if (visualizer_) {
        visualizer_->HandleFrame(lparam);
      } else {
        Visualizer::Drop(lparam);
      }
      return 0;
    case Background::kTrayMessage:
      if (background_) background_->HandleTray(wparam, lparam);
      return 0;
    case Background::kShowMessage:
      if (background_) background_->Restore();
      return 0;
    case MediaControls::kPressMessage:
      if (media_controls_) media_controls_->HandlePress(wparam, lparam);
      return 0;
    case Waveform::kDoneMessage:
      if (waveform_) {
        Waveform::HandleDone(lparam);
      } else {
        Waveform::Drop(lparam);
      }
      return 0;
    case WM_GETMINMAXINFO: {
      // Any smaller and the phone layout no longer fits.
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      UINT dpi = GetDpiForWindow(hwnd);
      limits->ptMinTrackSize.x = MulDiv(400, dpi, 96);
      limits->ptMinTrackSize.y = MulDiv(640, dpi, 96);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
