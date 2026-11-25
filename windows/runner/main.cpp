#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <filesystem>
#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {
int RunRdpWorker() {
  std::wstring executable(32768, L'\0');
  const auto length = ::GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) {
    return EXIT_FAILURE;
  }
  executable.resize(length);
  const auto library_path = std::filesystem::path(executable).parent_path() /
                            L"rust_lib_pagashell.dll";
  const auto library = ::LoadLibraryExW(
      library_path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (library == nullptr) {
    return EXIT_FAILURE;
  }
  // The Rust entry point returns INT_PTR using the Windows calling convention.
  const auto run = ::GetProcAddress(library, "pagashell_rdp_worker_main");
  // Keep the library loaded until process exit, including if Rust has
  // abandoned a stalled pipe thread during shutdown.
  return run && run() == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  auto command_line_arguments = GetCommandLineArguments();
  if (command_line_arguments.size() == 1 &&
      command_line_arguments.front() == "--pagashell-rdp-worker") {
    return RunRdpWorker();
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

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"pagashell", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Plugins may own COM objects. Release them before uninitializing the
  // apartment, also when the loop exits through an external WM_QUIT.
  window.Destroy();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
