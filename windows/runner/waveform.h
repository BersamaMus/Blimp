#ifndef RUNNER_WAVEFORM_H_
#define RUNNER_WAVEFORM_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// The waveform seek bar's levels for a song file, on the "blimp/waveform"
// channel (see lib/services/desktop_library.dart): how loud the song is
// across equal slices of it. Worked out with Media Foundation on a thread of
// its own, as Android's getWaveform does with MediaCodec.
class Waveform {
 public:
  // A finished job, posted to the window so it's replied to on the UI thread.
  static constexpr UINT kDoneMessage = WM_APP + 2;

  Waveform(flutter::BinaryMessenger* messenger, HWND window);

  // Replies for a kDoneMessage posted to the window.
  static void HandleDone(LPARAM lparam);

  // Frees a kDoneMessage's job without replying, once Flutter is gone.
  static void Drop(LPARAM lparam);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WAVEFORM_H_
