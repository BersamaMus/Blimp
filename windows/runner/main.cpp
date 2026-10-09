#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

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
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    // Win32Window's class (kWindowClassName in win32_window.cpp).
    if (HWND running =
            ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Blimp")) {
      DWORD process = 0;
      ::GetWindowThreadProcessId(running, &process);
      // This process was just started, so it may hand over the foreground.
      ::AllowSetForegroundWindow(process);
      ::PostMessage(running, Background::kShowMessage, 0, 0);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
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

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
