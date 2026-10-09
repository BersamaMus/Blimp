#ifndef RUNNER_SHARE_H_
#define RUNNER_SHARE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>

#include <memory>
#include <string>

// Windows' share panel, sending a song's file to another app (Mail, Nearby
// Share, Phone Link...), as Android's share sheet does. Asked for on the
// "blimp/share" channel (see MediaLibrary.shareSong).
class Share {
 public:
  Share(flutter::BinaryMessenger* messenger, HWND window);
  ~Share();

 private:
  // What the panel offers when it asks.
  struct Pending {
    std::wstring path;
    std::wstring title;
  };

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  winrt::Windows::ApplicationModel::DataTransfer::DataTransferManager manager_{
      nullptr};
  winrt::event_token token_{};
  std::shared_ptr<Pending> pending_ = std::make_shared<Pending>();
};

#endif  // RUNNER_SHARE_H_
