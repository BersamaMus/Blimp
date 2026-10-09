#include "share.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl_core.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>

#include <algorithm>
#include <vector>

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::ApplicationModel::DataTransfer::DataRequestedEventArgs;
using winrt::Windows::ApplicationModel::DataTransfer::DataTransferManager;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Storage::IStorageItem;
using winrt::Windows::Storage::StorageFile;

namespace {

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                   static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring wide(length, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      wide.data(), length);
  return wide;
}

std::wstring WideString(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  const auto* text =
      it == map.end() ? nullptr : std::get_if<std::string>(&it->second);
  return text ? Wide(*text) : std::wstring();
}

}  // namespace

Share::Share(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/share", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });

  // A desktop app's share panel belongs to its window.
  try {
    auto interop = winrt::get_activation_factory<DataTransferManager,
                                                 IDataTransferManagerInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<DataTransferManager>(),
        winrt::put_abi(manager_)));
  } catch (const winrt::hresult_error&) {
    // No share panel on this Windows; sharing reports it failed.
    manager_ = nullptr;
    return;
  }
  token_ = manager_.DataRequested(
      [pending = pending_](const DataTransferManager&,
                           const DataRequestedEventArgs& args) {
        auto request = args.Request();
        request.Data().Properties().Title(pending->title);
        // The file loads asynchronously; the panel waits for it.
        auto deferral = request.GetDeferral();
        StorageFile::GetFileFromPathAsync(pending->path)
            .Completed([request, deferral](
                           const IAsyncOperation<StorageFile>& operation,
                           AsyncStatus status) {
              try {
                if (status == AsyncStatus::Completed) {
                  request.Data().SetStorageItems(
                      winrt::single_threaded_vector<IStorageItem>(
                          {operation.GetResults()}));
                } else {
                  request.FailWithDisplayText(
                      L"The song's file couldn't be opened.");
                }
              } catch (const winrt::hresult_error&) {
                request.FailWithDisplayText(
                    L"The song's file couldn't be opened.");
              }
              deferral.Complete();
            });
      });
}

Share::~Share() {
  if (manager_) manager_.DataRequested(token_);
}

void Share::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() != "share") {
    result->NotImplemented();
    return;
  }
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  if (!manager_ || !args) {
    result->Success(EncodableValue(false));
    return;
  }
  // StorageFile only takes backslashes, and the panel a title.
  pending_->path = WideString(*args, "path");
  std::replace(pending_->path.begin(), pending_->path.end(), L'/', L'\\');
  pending_->title = WideString(*args, "title");
  if (pending_->title.empty()) pending_->title = L"Song";
  try {
    auto interop = winrt::get_activation_factory<DataTransferManager,
                                                 IDataTransferManagerInterop>();
    winrt::check_hresult(interop->ShowShareUIForWindow(window_));
    result->Success(EncodableValue(true));
  } catch (const winrt::hresult_error&) {
    result->Success(EncodableValue(false));
  }
}
