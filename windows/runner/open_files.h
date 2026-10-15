#ifndef RUNNER_OPEN_FILES_H_
#define RUNNER_OPEN_FILES_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <ole2.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// Files opened with Blimp: from Explorer ("Open with", or double-clicked once
// Blimp is the default), handed on by a second copy of Blimp started for them
// (see main.cpp), or dragged onto the window. Kept until Dart takes them on
// the "blimp/open" channel (see lib/services/open_files.dart), as it may
// still be starting; it's told when more come.
class OpenFiles {
 public:
  // WM_COPYDATA's dwData for a second copy's files: "Blmp".
  static constexpr ULONG_PTR kCopyDataId = 0x426C6D70;

  // [initial] are the files this copy of Blimp was started with.
  OpenFiles(flutter::BinaryMessenger* messenger, HWND window,
            std::vector<std::string> initial);
  ~OpenFiles();

  // Handles a second copy's WM_COPYDATA: its files, one after another, each
  // ending in a null (UTF-16). True if it was one.
  bool HandleCopyData(const COPYDATASTRUCT* data);

  // From the drop target.
  void Add(std::vector<std::string> paths);
  void SetDragging(bool dragging);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  std::vector<std::string> pending_;
  IDropTarget* drop_target_ = nullptr;
};

#endif  // RUNNER_OPEN_FILES_H_
