#include "recycle_bin.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <string>

#include "utils.h"

using flutter::EncodableList;
using flutter::EncodableValue;

RecycleBin::RecycleBin(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/recycle_bin",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* paths = std::get_if<EncodableList>(call.arguments());
    if (call.method_name() != "recycle" || !paths) {
      result->NotImplemented();
      return;
    }
    // SHFileOperation takes the paths one after another, each ending in a
    // null, with another null after the last. Backslashes only.
    std::wstring from;
    for (const auto& value : *paths) {
      const auto* path = std::get_if<std::string>(&value);
      if (!path) continue;
      std::wstring wide = Utf16FromUtf8(*path);
      for (auto& c : wide) {
        if (c == L'/') c = L'\\';
      }
      from += wide;
      from.push_back(L'\0');
    }
    if (from.empty()) {
      result->Success(EncodableValue(true));
      return;
    }
    from.push_back(L'\0');
    SHFILEOPSTRUCTW operation{};
    operation.hwnd = window_;
    operation.wFunc = FO_DELETE;
    operation.pFrom = from.c_str();
    // To the Recycle Bin, without Windows asking again: Blimp already has.
    operation.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT |
                       FOF_NOERRORUI;
    int error = SHFileOperationW(&operation);
    result->Success(
        EncodableValue(error == 0 && !operation.fAnyOperationsAborted));
  });
}
