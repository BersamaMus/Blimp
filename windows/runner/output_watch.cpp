#include "output_watch.h"

#include <wrl/implements.h>

#include <chrono>
#include <mutex>
#include <string>

#include "media_controls.h"

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

namespace {

// Windows may move to the next output before saying the old one went: one
// gone this soon after it stopped being the default still counts.
constexpr auto kSwitchWindow = std::chrono::seconds(3);

// Hears from Windows, on its own threads, as outputs come and go, and tells
// Dart (DesktopMediaControls), which knows whether music is playing.
class Listener
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IMMNotificationClient> {
 public:
  Listener(HWND window, ComPtr<IMMDeviceEnumerator> devices,
           std::wstring output)
      : window_(window), devices_(devices), current_(std::move(output)) {}

  STDMETHOD(OnDefaultDeviceChanged)
  (EDataFlow flow, ERole role, LPCWSTR id) override {
    // Where apps play by default; the player follows it.
    if (flow != eRender || role != eConsole) return S_OK;
    std::lock_guard<std::mutex> lock(mutex_);
    previous_ = current_;
    current_ = id ? id : L"";
    changed_ = std::chrono::steady_clock::now();
    return S_OK;
  }

  STDMETHOD(OnDeviceStateChanged)(LPCWSTR id, DWORD state) override {
    if (state & DEVICE_STATE_ACTIVE) {
      CameOn(id);
    } else {
      Gone(id);
    }
    return S_OK;
  }

  STDMETHOD(OnDeviceRemoved)(LPCWSTR id) override {
    Gone(id);
    return S_OK;
  }

  STDMETHOD(OnDeviceAdded)(LPCWSTR) override { return S_OK; }

  STDMETHOD(OnPropertyValueChanged)(LPCWSTR, const PROPERTYKEY) override {
    return S_OK;
  }

 private:
  void Post(WPARAM what) {
    PostMessage(window_, MediaControls::kPressMessage, what, 0);
  }

  // An output went: if it's the one playing, say so.
  void Gone(LPCWSTR id) {
    if (!id) return;
    bool playing_there;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      playing_there =
          current_ == id ||
          (previous_ == id &&
           std::chrono::steady_clock::now() - changed_ < kSwitchWindow);
    }
    if (playing_there) Post(MediaControls::kOutputGone);
  }

  // An output came on. Some laptops turn their speakers off as headphones
  // are plugged in, which looks like the playing output going; this tells
  // Dart it was a plug-in after all.
  void CameOn(LPCWSTR id) {
    ComPtr<IMMDevice> device;
    ComPtr<IMMEndpoint> endpoint;
    EDataFlow flow;
    if (id && SUCCEEDED(devices_->GetDevice(id, &device)) &&
        SUCCEEDED(device.As(&endpoint)) &&
        SUCCEEDED(endpoint->GetDataFlow(&flow)) && flow == eRender) {
      Post(MediaControls::kOutputBack);
    }
  }

  HWND window_;
  ComPtr<IMMDeviceEnumerator> devices_;
  std::mutex mutex_;
  std::wstring current_;
  std::wstring previous_;
  std::chrono::steady_clock::time_point changed_;
};

}  // namespace

OutputWatch::OutputWatch(HWND window) {
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&devices_)))) {
    return;
  }
  std::wstring output;
  ComPtr<IMMDevice> device;
  LPWSTR id = nullptr;
  if (SUCCEEDED(devices_->GetDefaultAudioEndpoint(eRender, eConsole, &device)) &&
      SUCCEEDED(device->GetId(&id))) {
    output = id;
    CoTaskMemFree(id);
  }
  listener_ = Make<Listener>(window, devices_, output);
  if (FAILED(devices_->RegisterEndpointNotificationCallback(listener_.Get()))) {
    listener_.Reset();
  }
}

OutputWatch::~OutputWatch() {
  if (devices_ && listener_) {
    devices_->UnregisterEndpointNotificationCallback(listener_.Get());
  }
}
