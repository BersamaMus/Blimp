#include "media_controls.h"

#include <flutter/standard_method_codec.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <chrono>
#include <string>

#include "utils.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Foundation::AsyncStatus;
using winrt::Windows::Foundation::IAsyncOperation;
using winrt::Windows::Foundation::TimeSpan;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::PlaybackPositionChangeRequestedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;
using winrt::Windows::Media::SystemMediaTransportControlsButtonPressedEventArgs;
using winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties;
using winrt::Windows::Storage::StorageFile;
using winrt::Windows::Storage::Streams::RandomAccessStreamReference;

namespace {

// Posted in place of a button for a seek from the flyout; the position, in
// milliseconds, comes as the message's LPARAM.
constexpr WPARAM kSeek = 0x100;

// The taskbar preview's buttons, as their WM_COMMAND ids.
enum ThumbButton : UINT {
  kThumbPrevious = 0x4201,
  kThumbPlayPause,
  kThumbNext,
};

// Glyphs of Segoe MDL2 Assets (also in Windows 11), indexed as icons_.
constexpr wchar_t kGlyphs[4] = {0xE892, 0xE768, 0xE769, 0xE893};
enum Icon { kIconPrevious, kIconPlay, kIconPause, kIconNext };

// A white icon of [glyph], [size] pixels square, drawn from Windows' own
// icon font so it matches the rest of the taskbar.
HICON GlyphIcon(wchar_t glyph, int size) {
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = size;
  info.bmiHeader.biHeight = -size;  // Top-down.
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  ReleaseDC(nullptr, screen);
  HBITMAP color = CreateDIBSection(dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (!color) {
    DeleteDC(dc);
    return nullptr;
  }
  HGDIOBJ old_bitmap = SelectObject(dc, color);
  // Grey levels, not ClearType's coloured edges: they become the alpha.
  HFONT font = CreateFontW(-size * 3 / 4, 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                           FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                           DEFAULT_PITCH, L"Segoe MDL2 Assets");
  HGDIOBJ old_font = SelectObject(dc, font);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  RECT area{0, 0, size, size};
  DrawTextW(dc, &glyph, 1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  GdiFlush();
  auto* pixels = static_cast<BYTE*>(bits);
  for (int i = 0; i < size * size; i++) {
    BYTE level = pixels[i * 4 + 2];
    pixels[i * 4] = pixels[i * 4 + 1] = pixels[i * 4 + 2] = 255;
    pixels[i * 4 + 3] = level;
  }
  SelectObject(dc, old_font);
  DeleteObject(font);
  SelectObject(dc, old_bitmap);
  DeleteDC(dc);

  HBITMAP mask = CreateBitmap(size, size, 1, 1, nullptr);
  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmMask = mask;
  icon_info.hbmColor = color;
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(mask);
  DeleteObject(color);
  return icon;
}

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

std::wstring WideString(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? Utf16FromUtf8(*text) : std::wstring();
}

bool Bool(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

int64_t Long(const EncodableMap& map, const char* key) {
  const EncodableValue* value = Find(map, key);
  return value && !value->IsNull() ? value->LongValue() : 0;
}

TimeSpan Milliseconds(int64_t ms) {
  return std::chrono::duration_cast<TimeSpan>(std::chrono::milliseconds(ms));
}

}  // namespace

MediaControls::MediaControls(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  taskbar_button_created_ = RegisterWindowMessageW(L"TaskbarButtonCreated");
  // Without this an app run as administrator never hears it.
  ChangeWindowMessageFilterEx(window, taskbar_button_created_, MSGFLT_ALLOW,
                              nullptr);
  UINT dpi = GetDpiForWindow(window);
  int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
  for (int i = 0; i < 4; i++) icons_[i] = GlyphIcon(kGlyphs[i], size);

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "blimp/media_controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleCall(call, std::move(result));
  });

  // A desktop app's controls belong to its window.
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(controls_)));
  } catch (const winrt::hresult_error&) {
    // No media controls on this Windows; calls from Dart do nothing.
    controls_ = nullptr;
    return;
  }
  controls_.IsPlayEnabled(true);
  controls_.IsPauseEnabled(true);
  controls_.IsStopEnabled(true);
  controls_.IsNextEnabled(true);
  controls_.IsPreviousEnabled(true);
  // Hidden until there's a song to show.
  controls_.IsEnabled(false);

  button_token_ = controls_.ButtonPressed(
      [window](const SystemMediaTransportControls&,
               const SystemMediaTransportControlsButtonPressedEventArgs& args) {
        PostMessage(window, kPressMessage, static_cast<WPARAM>(args.Button()),
                    0);
      });
  seek_token_ = controls_.PlaybackPositionChangeRequested(
      [window](const SystemMediaTransportControls&,
               const PlaybackPositionChangeRequestedEventArgs& args) {
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      args.RequestedPlaybackPosition())
                      .count();
        PostMessage(window, kPressMessage, kSeek, static_cast<LPARAM>(ms));
      });
}

MediaControls::~MediaControls() {
  if (taskbar_) taskbar_->Release();
  for (HICON icon : icons_) {
    if (icon) DestroyIcon(icon);
  }
  if (!controls_) return;
  controls_.ButtonPressed(button_token_);
  controls_.PlaybackPositionChangeRequested(seek_token_);
  controls_.IsEnabled(false);
}

void MediaControls::HandlePress(WPARAM wparam, LPARAM lparam) {
  if (wparam == kOutputGone || wparam == kOutputBack) {
    channel_->InvokeMethod(
        "output", std::make_unique<EncodableValue>(
                      std::string(wparam == kOutputGone ? "gone" : "back")));
    return;
  }
  if (wparam == kSeek) {
    channel_->InvokeMethod(
        "seek", std::make_unique<EncodableValue>(static_cast<int64_t>(lparam)));
    return;
  }
  const char* name = nullptr;
  switch (static_cast<SystemMediaTransportControlsButton>(wparam)) {
    case SystemMediaTransportControlsButton::Play:
      name = "play";
      break;
    case SystemMediaTransportControlsButton::Pause:
      name = "pause";
      break;
    case SystemMediaTransportControlsButton::Stop:
      name = "stop";
      break;
    case SystemMediaTransportControlsButton::Next:
      name = "next";
      break;
    case SystemMediaTransportControlsButton::Previous:
      name = "previous";
      break;
    default:
      return;
  }
  channel_->InvokeMethod("button",
                         std::make_unique<EncodableValue>(std::string(name)));
}

void MediaControls::HandleTaskbarButtonCreated() {
  if (!taskbar_) {
    if (FAILED(CoCreateInstance(CLSID_TaskbarList, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&taskbar_)))) {
      taskbar_ = nullptr;
      return;
    }
    if (FAILED(taskbar_->HrInit())) {
      taskbar_->Release();
      taskbar_ = nullptr;
      return;
    }
  }
  // Explorer restarted, or the button was made again: the buttons are new.
  thumb_buttons_added_ = false;
  UpdateThumbButtons();
}

bool MediaControls::HandleCommand(WPARAM wparam) {
  if (HIWORD(wparam) != THBN_CLICKED) return false;
  SystemMediaTransportControlsButton button;
  switch (LOWORD(wparam)) {
    case kThumbPrevious:
      button = SystemMediaTransportControlsButton::Previous;
      break;
    case kThumbPlayPause:
      button = playing_ ? SystemMediaTransportControlsButton::Pause
                        : SystemMediaTransportControlsButton::Play;
      break;
    case kThumbNext:
      button = SystemMediaTransportControlsButton::Next;
      break;
    default:
      return false;
  }
  HandlePress(static_cast<WPARAM>(button), 0);
  return true;
}

void MediaControls::UpdateThumbButtons() {
  if (!taskbar_) return;
  THUMBBUTTON buttons[3] = {};
  const UINT ids[3] = {kThumbPrevious, kThumbPlayPause, kThumbNext};
  const Icon icons[3] = {kIconPrevious, playing_ ? kIconPause : kIconPlay,
                         kIconNext};
  const wchar_t* tips[3] = {L"Previous", playing_ ? L"Pause" : L"Play",
                            L"Next"};
  for (int i = 0; i < 3; i++) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = ids[i];
    buttons[i].hIcon = icons_[icons[i]];
    wcscpy_s(buttons[i].szTip, tips[i]);
    buttons[i].dwFlags = !has_song_                  ? THBF_HIDDEN
                         : (i == 2 && !can_next_)   ? THBF_DISABLED
                                                    : THBF_ENABLED;
  }
  if (thumb_buttons_added_) {
    taskbar_->ThumbBarUpdateButtons(window_, 3, buttons);
  } else if (SUCCEEDED(taskbar_->ThumbBarAddButtons(window_, 3, buttons))) {
    thumb_buttons_added_ = true;
  }
}

void MediaControls::HandleCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  // The taskbar preview's buttons follow along, media controls or not.
  if (call.method_name() == "update" && args) {
    has_song_ = true;
    playing_ = Bool(*args, "playing");
    can_next_ = Bool(*args, "canNext");
    UpdateThumbButtons();
  } else if (call.method_name() == "clear") {
    has_song_ = false;
    UpdateThumbButtons();
  }
  if (!controls_) {
    result->Success();
    return;
  }
  try {
    if (call.method_name() == "update" && args) {
      controls_.IsEnabled(true);
      controls_.PlaybackStatus(Bool(*args, "playing")
                                   ? MediaPlaybackStatus::Playing
                                   : MediaPlaybackStatus::Paused);
      controls_.IsPreviousEnabled(Bool(*args, "canPrevious"));
      controls_.IsNextEnabled(Bool(*args, "canNext"));

      auto updater = controls_.DisplayUpdater();
      updater.Type(MediaPlaybackType::Music);
      auto music = updater.MusicProperties();
      music.Title(WideString(*args, "title"));
      music.Artist(WideString(*args, "artist"));
      music.AlbumTitle(WideString(*args, "album"));
      // Only a new cover is touched: setting the same one again makes the
      // flyout redraw it, which flickers. Cleared until the new one loads.
      std::wstring art = WideString(*args, "art");
      bool new_art = art != thumbnail_;
      if (new_art) {
        thumbnail_ = art;
        updater.Thumbnail(nullptr);
        generation_->fetch_add(1);
      }
      updater.Update();
      if (new_art && !art.empty()) SetThumbnail(art);
    } else if (call.method_name() == "timeline" && args) {
      int64_t duration = Long(*args, "durationMs");
      SystemMediaTransportControlsTimelineProperties timeline;
      timeline.StartTime(Milliseconds(0));
      timeline.MinSeekTime(Milliseconds(0));
      timeline.Position(Milliseconds(Long(*args, "positionMs")));
      timeline.MaxSeekTime(Milliseconds(duration));
      timeline.EndTime(Milliseconds(duration));
      controls_.UpdateTimelineProperties(timeline);
    } else if (call.method_name() == "clear") {
      thumbnail_.clear();
      generation_->fetch_add(1);
      controls_.DisplayUpdater().ClearAll();
      controls_.DisplayUpdater().Update();
      controls_.IsEnabled(false);
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  } catch (const winrt::hresult_error& error) {
    result->Error("media_controls", winrt::to_string(error.message()));
  }
}

void MediaControls::SetThumbnail(const std::wstring& path) {
  int generation = generation_->load();
  auto controls = controls_;
  auto current = generation_;
  // StorageFile only takes backslashes.
  std::wstring native = path;
  std::replace(native.begin(), native.end(), L'/', L'\\');
  StorageFile::GetFileFromPathAsync(native).Completed(
      [controls, current, generation](
          const IAsyncOperation<StorageFile>& operation, AsyncStatus status) {
        // The song changed while its cover loaded: leave the new one be.
        if (status != AsyncStatus::Completed || current->load() != generation) {
          return;
        }
        try {
          auto updater = controls.DisplayUpdater();
          updater.Thumbnail(
              RandomAccessStreamReference::CreateFromFile(operation.GetResults()));
          updater.Update();
        } catch (const winrt::hresult_error&) {
          // An unreadable cover: the controls just go without one.
        }
      });
}
