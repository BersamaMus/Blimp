#ifndef RUNNER_RECYCLE_BIN_H_
#define RUNNER_RECYCLE_BIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Sends songs' files to the Recycle Bin, so a duplicate thrown away can be
// got back. Asked on the "blimp/recycle_bin" channel (see
// lib/services/media_library.dart).
class RecycleBin {
 public:
  RecycleBin(flutter::BinaryMessenger* messenger, HWND window);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_RECYCLE_BIN_H_
