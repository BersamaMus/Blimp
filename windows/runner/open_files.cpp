#include "open_files.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include "utils.h"

using flutter::EncodableList;
using flutter::EncodableValue;

namespace {

std::string Narrow(const std::wstring& wide) {
  return Utf8FromUtf16(wide.c_str());
}

// The files in a drag: Explorer's list of paths.
std::vector<std::string> DroppedPaths(IDataObject* data) {
  std::vector<std::string> paths;
  FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium;
  if (FAILED(data->GetData(&format, &medium))) return paths;
  auto drop = static_cast<HDROP>(GlobalLock(medium.hGlobal));
  if (drop) {
    UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      UINT length = DragQueryFileW(drop, i, nullptr, 0);
      std::wstring path(length, L'\0');
      DragQueryFileW(drop, i, path.data(), length + 1);
      paths.push_back(Narrow(path));
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return paths;
}

bool HasFiles(IDataObject* data) {
  FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  return data && SUCCEEDED(data->QueryGetData(&format));
}

// Takes files dragged onto the window. Registered on the top-level window:
// OLE looks up from the window under the mouse (Flutter's view) to find it.
class DropTarget : public IDropTarget {
 public:
  explicit DropTarget(OpenFiles* owner) : owner_(owner) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
    if (id == IID_IUnknown || id == IID_IDropTarget) {
      *out = static_cast<IDropTarget*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG left = --references_;
    if (left == 0) delete this;
    return left;
  }

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL,
                                      DWORD* effect) override {
    files_ = HasFiles(data);
    *effect = files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    if (files_) owner_->SetDragging(true);
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL, DWORD* effect) override {
    *effect = files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE DragLeave() override {
    if (files_) owner_->SetDragging(false);
    files_ = false;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL,
                                 DWORD* effect) override {
    owner_->SetDragging(false);
    files_ = false;
    std::vector<std::string> paths = DroppedPaths(data);
    *effect = paths.empty() ? DROPEFFECT_NONE : DROPEFFECT_COPY;
    if (!paths.empty()) owner_->Add(std::move(paths));
    return S_OK;
  }

 private:
  OpenFiles* owner_;
  ULONG references_ = 1;
  bool files_ = false;
};

}  // namespace

OpenFiles::OpenFiles(flutter::BinaryMessenger* messenger, HWND window,
                     std::vector<std::string> initial)
    : window_(window), pending_(std::move(initial)) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/open", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "takeOpened") {
      result->NotImplemented();
      return;
    }
    EncodableList files;
    for (const auto& path : pending_) {
      files.push_back(EncodableValue(flutter::EncodableMap{
          {EncodableValue("path"), EncodableValue(path)}}));
    }
    pending_.clear();
    result->Success(EncodableValue(files));
  });

  auto target = new DropTarget(this);
  if (SUCCEEDED(RegisterDragDrop(window_, target))) {
    drop_target_ = target;
  } else {
    target->Release();
  }
}

OpenFiles::~OpenFiles() {
  if (drop_target_) {
    RevokeDragDrop(window_);
    drop_target_->Release();
  }
}

bool OpenFiles::HandleCopyData(const COPYDATASTRUCT* data) {
  if (!data || data->dwData != kCopyDataId || !data->lpData) return false;
  const auto* text = static_cast<const wchar_t*>(data->lpData);
  size_t length = data->cbData / sizeof(wchar_t);
  std::vector<std::string> paths;
  size_t start = 0;
  for (size_t i = 0; i < length; i++) {
    if (text[i] != L'\0') continue;
    if (i > start) paths.push_back(Narrow(std::wstring(text + start, i - start)));
    start = i + 1;
  }
  Add(std::move(paths));
  return true;
}

void OpenFiles::Add(std::vector<std::string> paths) {
  if (paths.empty()) return;
  pending_.insert(pending_.end(), paths.begin(), paths.end());
  channel_->InvokeMethod("opened", nullptr);
}

void OpenFiles::SetDragging(bool dragging) {
  channel_->InvokeMethod("dragging",
                         std::make_unique<EncodableValue>(dragging));
}
