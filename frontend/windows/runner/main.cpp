#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\GradeMonitor-7B8A9C0D1E2F3A4B5C6D7E8F9A0B1C2D";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"GradeMonitor";

// Wait briefly for the first instance to create its window, then activate it.
void FocusExistingInstance() {
  HWND window = nullptr;
  for (int attempt = 0; attempt < 30 && window == nullptr; ++attempt) {
    window = ::FindWindowW(kWindowClassName, kWindowTitle);
    if (window == nullptr) {
      window = ::FindWindowW(nullptr, kWindowTitle);
    }
    if (window == nullptr) {
      ::Sleep(100);
    }
  }

  if (window == nullptr) {
    return;
  }

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  if (!::SetForegroundWindow(window)) {
    ::FlashWindow(window, TRUE);
  }
  ::BringWindowToTop(window);
  ::SetFocus(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Block a second instance before Flutter or the Python backend starts.
  ::SetLastError(ERROR_SUCCESS);
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutexName);
  const DWORD mutex_error = ::GetLastError();
  if (mutex_error == ERROR_ALREADY_EXISTS ||
      mutex_error == ERROR_ACCESS_DENIED) {
    FocusExistingInstance();
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
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
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"GradeMonitor", origin, size)) {
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
