#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

#include "flutter_window.h"
#include "utils.h"
#include "win32_window.h"

namespace {

constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\SyncHub_Next_SingleInstance";

std::vector<uint8_t> SerializeCliArgs(const std::vector<std::string>& args) {
  const uint32_t count = static_cast<uint32_t>(args.size());
  size_t total_bytes = sizeof(uint32_t);
  for (const auto& arg : args) {
    total_bytes += sizeof(uint32_t) + arg.size();
  }

  std::vector<uint8_t> buffer(total_bytes, 0);
  size_t offset = 0;
  std::memcpy(buffer.data() + offset, &count, sizeof(uint32_t));
  offset += sizeof(uint32_t);

  for (const auto& arg : args) {
    const uint32_t len = static_cast<uint32_t>(arg.size());
    std::memcpy(buffer.data() + offset, &len, sizeof(uint32_t));
    offset += sizeof(uint32_t);
    if (len > 0) {
      std::memcpy(buffer.data() + offset, arg.data(), arg.size());
      offset += arg.size();
    }
  }
  return buffer;
}

bool ForwardToRunningInstance(const std::vector<std::string>& args) {
  HWND target_hwnd = nullptr;
  for (int attempt = 0; attempt < 60; ++attempt) {
    target_hwnd = ::FindWindowW(kSyncHubWindowClassName, nullptr);
    if (target_hwnd != nullptr) {
      break;
    }
    ::Sleep(50);
  }

  if (target_hwnd == nullptr) {
    return false;
  }

  DWORD target_pid = 0;
  ::GetWindowThreadProcessId(target_hwnd, &target_pid);
  if (target_pid != 0) {
    ::AllowSetForegroundWindow(target_pid);
  }

  std::vector<uint8_t> payload = SerializeCliArgs(args);
  COPYDATASTRUCT cds{};
  cds.dwData = kSyncHubCopyDataMagic;
  cds.cbData = static_cast<DWORD>(payload.size());
  cds.lpData = payload.data();

  DWORD_PTR send_result = 0;
  ::SendMessageTimeoutW(target_hwnd, WM_COPYDATA, 0,
                        reinterpret_cast<LPARAM>(&cds), SMTO_ABORTIFHUNG, 3000,
                        &send_result);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance,
                      _In_opt_ HINSTANCE prev,
                      _In_ wchar_t* command_line,
                      _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutexName);
  const DWORD mutex_error = ::GetLastError();
  if (single_instance_mutex != nullptr &&
      mutex_error == ERROR_ALREADY_EXISTS) {
    ForwardToRunningInstance(command_line_arguments);
    ::CloseHandle(single_instance_mutex);
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

  bool start_minimized = false;
  for (const auto& arg : command_line_arguments) {
    if (arg == "--minimized") {
      start_minimized = true;
      break;
    }
  }

  flutter::DartProject project(L"data");
  std::vector<std::string> initial_cli_args = command_line_arguments;
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, std::move(initial_cli_args), start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"SyncHub", origin, size)) {
    ::CoUninitialize();
    if (single_instance_mutex != nullptr) {
      ::CloseHandle(single_instance_mutex);
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    ::CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
