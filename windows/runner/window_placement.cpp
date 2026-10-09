#include "window_placement.h"

namespace {

constexpr wchar_t kKey[] = L"Software\\Blimp\\Blimp";
constexpr wchar_t kValue[] = L"WindowPlacement";

}  // namespace

void SaveWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{sizeof(placement)};
  if (!GetWindowPlacement(window, &placement)) return;
  RegSetKeyValueW(HKEY_CURRENT_USER, kKey, kValue, REG_BINARY, &placement,
                  sizeof(placement));
}

bool RestoreWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  DWORD size = sizeof(placement);
  if (RegGetValueW(HKEY_CURRENT_USER, kKey, kValue, RRF_RT_REG_BINARY, nullptr,
                   &placement, &size) != ERROR_SUCCESS ||
      size != sizeof(placement) || placement.length != sizeof(placement)) {
    return false;
  }
  // Closed minimized: comes back as it was before minimizing.
  bool maximized =
      placement.showCmd == SW_SHOWMAXIMIZED ||
      (placement.showCmd == SW_SHOWMINIMIZED &&
       (placement.flags & WPF_RESTORETOMAXIMIZED));
  // Only sizes and places it; it's shown once Flutter has drawn a frame.
  // Windows moves it back on screen if that monitor is gone.
  placement.showCmd = SW_HIDE;
  placement.flags = 0;
  SetWindowPlacement(window, &placement);
  return maximized;
}
