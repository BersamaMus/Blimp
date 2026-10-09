#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "background.h"
#include "media_controls.h"
#include "output_watch.h"
#include "share.h"
#include "visualizer.h"
#include "waveform.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The media keys and Windows' media flyout.
  std::unique_ptr<MediaControls> media_controls_;

  // Pauses when the headphones playing are unplugged.
  std::unique_ptr<OutputWatch> output_watch_;

  // Windows' share panel, for a song's file.
  std::unique_ptr<Share> share_;

  // The waveform seek bar's levels, decoded by Windows.
  std::unique_ptr<Waveform> waveform_;

  // Closing to the system tray, to keep playing in the background.
  std::unique_ptr<Background> background_;

  // The visualizer's audio.
  std::unique_ptr<Visualizer> visualizer_;

  // Whether the window was maximized when last closed, so it opens that way.
  bool show_maximized_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
