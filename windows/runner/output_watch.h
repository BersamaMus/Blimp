#ifndef RUNNER_OUTPUT_WATCH_H_
#define RUNNER_OUTPUT_WATCH_H_

#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

// Pauses when the headphones (or speakers) playing are unplugged or
// disconnect, as a phone does, rather than carrying on out loud through
// whatever Windows switches to. Plugging something in doesn't pause.
//
// It tells Dart through MediaControls' channel, which pauses (and, for a
// plug-in that only looked like an unplug, plays again).
class OutputWatch {
 public:
  explicit OutputWatch(HWND window);
  ~OutputWatch();

 private:
  Microsoft::WRL::ComPtr<IMMDeviceEnumerator> devices_;
  Microsoft::WRL::ComPtr<IMMNotificationClient> listener_;
};

#endif  // RUNNER_OUTPUT_WATCH_H_
