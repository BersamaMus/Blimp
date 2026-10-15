#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <ole2.h>
#include <shellapi.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "open_files.h"
#include "utils.h"

namespace {

// The files and folders Blimp was started with, as Explorer passes them for
// "Open with"; anything else on the command line is left out.
std::vector<std::wstring> OpenedPaths() {
  std::vector<std::wstring> paths;
  int count = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &count);
  if (!argv) return paths;
  for (int i = 1; i < count; i++) {
    if (::GetFileAttributesW(argv[i]) == INVALID_FILE_ATTRIBUTES) continue;
    // Full paths: the Blimp they're handed to runs in another folder.
    DWORD length = ::GetFullPathNameW(argv[i], 0, nullptr, nullptr);
    if (length == 0) continue;
    std::wstring full(length, L'\0');
    length = ::GetFullPathNameW(argv[i], length, full.data(), nullptr);
    full.resize(length);
    paths.push_back(full);
  }
  ::LocalFree(argv);
  return paths;
}

// Hands [paths] to the Blimp already running, waiting a little for its window
// if it's only just starting, as when several files are opened at once.
void SendToRunning(const std::vector<std::wstring>& paths) {
  HWND running = nullptr;
  for (int tries = 0; tries < 100 && !running; tries++) {
    // Win32Window's class (kWindowClassName in win32_window.cpp).
    running = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Blimp");
    if (!running) ::Sleep(100);
  }
  if (!running) return;
  DWORD process = 0;
  ::GetWindowThreadProcessId(running, &process);
  // This process was just started, so it may hand over the foreground.
  ::AllowSetForegroundWindow(process);
  if (!paths.empty()) {
    std::wstring joined;
    for (const auto& path : paths) {
      joined += path;
      joined.push_back(L'\0');
    }
    COPYDATASTRUCT data{};
    data.dwData = OpenFiles::kCopyDataId;
    data.cbData = static_cast<DWORD>(joined.size() * sizeof(wchar_t));
    data.lpData = joined.data();
    DWORD_PTR ignored;
    ::SendMessageTimeoutW(running, WM_COPYDATA, 0,
                          reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                          5000, &ignored);
  }
  ::PostMessage(running, Background::kShowMessage, 0, 0);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One Blimp at a time. Opened again (perhaps while it's in the tray),
  // the one already running comes back instead of a second player starting.
  // The handle is let go of as the process ends. A debug build has its own,
  // so it runs beside an installed Blimp rather than handing over to it.
#ifdef _DEBUG
  ::CreateMutexW(nullptr, FALSE, L"Blimp.SingleInstance.Debug");
#else
  ::CreateMutexW(nullptr, FALSE, L"Blimp.SingleInstance");
#endif
  // Read straight away: the calls below change the last error.
  bool already_running = ::GetLastError() == ERROR_ALREADY_EXISTS;
  std::vector<std::wstring> opened = OpenedPaths();
  if (already_running) {
    SendToRunning(opened);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins. Through OLE, which also sets it up for files dragged onto the
  // window.
  ::OleInitialize(nullptr);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  std::vector<std::string> opened_utf8;
  for (const auto& path : opened) opened_utf8.push_back(Utf8FromUtf16(path.c_str()));
  FlutterWindow window(project, std::move(opened_utf8));
  Win32Window::Point origin(10, 10);
  // Wide enough for the desktop layout, with the tabs down the side.
  Win32Window::Size size(1180, 800);
  if (!window.Create(L"Blimp", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::OleUninitialize();
  return EXIT_SUCCESS;
}
