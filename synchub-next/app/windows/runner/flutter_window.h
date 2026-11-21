#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

inline constexpr ULONG_PTR kSyncHubCopyDataMagic = 0x53594E43;

// Main Win32 window hosting the Flutter view, system tray, native channels,
// single-instance CLI forwarding, Credential Manager, and clipboard helpers.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  FlutterWindow(const flutter::DartProject& project,
                std::vector<std::string> initial_cli_args,
                bool start_minimized);
  ~FlutterWindow() override;

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window,
                         UINT const message,
                         WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct TrayDeviceItem {
    std::string id;
    std::wstring name;
    bool online = false;
  };

  struct TrayRecentItem {
    flutter::EncodableValue id;
    std::wstring label;
  };

  void RegisterChannels();
  void HandleSecureCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void HandleDesktopCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void AddOrUpdateTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayNotification(const std::wstring& title,
                            const std::wstring& body,
                            const std::string& path);
  void ShowTrayContextMenu();
  void RestoreAndActivateWindow();
  void RequestQuit();

  void InvokeTrayAction(const std::string& action,
                        const char* extra_key = nullptr,
                        const flutter::EncodableValue* extra_val = nullptr);
  void HandleIncomingCliArgs(std::vector<std::string> args);

  bool EnsureGdiplus();
  flutter::EncodableList ReadClipboardFiles();
  flutter::EncodableValue ReadClipboardImage();
  bool WriteClipboardImage(const std::vector<uint8_t>& png_bytes);
  bool WriteClipboardFiles(const std::vector<std::wstring>& paths);
  bool IsClipboardPrivate();

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      secure_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      desktop_channel_;

  std::vector<std::vector<std::string>> pending_cli_batches_;
  bool start_minimized_ = false;
  bool dart_ready_ = false;
  bool allow_quit_ = false;

  HWND tray_hwnd_ = nullptr;
  bool tray_added_ = false;
  UINT taskbar_created_msg_ = 0;
  ULONG_PTR gdiplus_token_ = 0;

  std::wstring tray_status_ = L"SyncHub \u00B7 \u672A\u8FDE\u63A5";
  std::wstring tray_tooltip_ = L"SyncHub \u8DE8\u7AEF\u4F20\u8F93";
  std::vector<TrayDeviceItem> tray_devices_;
  std::vector<TrayRecentItem> tray_recent_items_;
  bool tray_auto_accept_ = true;
  bool tray_clip_sync_ = true;
  bool tray_launch_at_login_ = false;
  std::string last_notif_path_;

  bool clipboard_listener_registered_ = false;
  bool hotkey_registered_ = false;
  bool session_notification_registered_ = false;
  bool is_sleeping_ = false;
  bool session_locked_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
