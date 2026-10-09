#ifndef RUNNER_VISUALIZER_H_
#define RUNNER_VISUALIZER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <windows.h>

#include <atomic>
#include <memory>
#include <thread>

// The visualizer's audio, on the "blimp/visualizer" event channel (see
// lib/services/visualizer.dart), in the same frames Android's Visualizer
// gives: the spectrum in bands, the waveform, and how loud it is.
//
// It captures what Blimp itself plays (process loopback), which needs
// Windows 10 build 20348 or later. On older Windows it captures everything
// the PC plays instead, and says so, so other apps' sound moves it too.
class Visualizer {
 public:
  // A frame from the capture thread, posted to the window so it's sent from
  // the UI thread.
  static constexpr UINT kFrameMessage = WM_APP + 5;

  Visualizer(flutter::BinaryMessenger* messenger, HWND window);
  ~Visualizer();

  // Sends a kFrameMessage's frame to Dart.
  void HandleFrame(LPARAM lparam);

  // Frees a kFrameMessage's frame that arrived after the visualizer went.
  static void Drop(LPARAM lparam);

 private:
  void Start();
  void Stop();

  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  HWND window_;
  std::thread thread_;
  std::shared_ptr<std::atomic<bool>> running_;

  // Counts captures started, so a frame from a stopped one is dropped.
  int generation_ = 0;
};

#endif  // RUNNER_VISUALIZER_H_
