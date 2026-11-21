#include "flutter_window.h"

#include <windows.h>
#include <objidl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincred.h>
#include <wtsapi32.h>
#include <dpapi.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace Gdiplus {
using std::max;
using std::min;
}  // namespace Gdiplus

#pragma warning(push)
#pragma warning(disable : 4458)
#include <gdiplus.h>
#pragma warning(pop)

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

#ifndef NIN_BALLOONUSERCLICK
#define NIN_BALLOONUSERCLICK (WM_USER + 5)
#endif

namespace {

constexpr UINT kTrayCallbackMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;

constexpr UINT kCmdOpenWindow = 1001;
constexpr UINT kCmdSendFiles = 1002;
constexpr UINT kCmdSendClipboard = 1003;
constexpr UINT kCmdOpenRecvDir = 1004;
constexpr UINT kCmdOpenWebHub = 1005;
constexpr UINT kCmdToggleAutoAccept = 1006;
constexpr UINT kCmdToggleClipSync = 1007;
constexpr UINT kCmdToggleLaunchAtLogin = 1008;
constexpr UINT kCmdQuit = 1009;
constexpr UINT kCmdSendToDeviceBase = 2000;
constexpr UINT kCmdOpenRecentBase = 3000;
constexpr int kHotkeySendClipboard = 1;
#ifndef MOD_NOREPEAT
#define MOD_NOREPEAT 0x4000
#endif

constexpr const wchar_t kRunRegKeyPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t kRunRegValueName[] = L"SyncHub";
constexpr const wchar_t kCredPrefix[] = L"SyncHub_Next/";
constexpr const wchar_t kSecureRegSubKey[] = L"Software\\SyncHub\\Secure";
constexpr const char kDpapiPrefix[] = "dpapi:";
constexpr size_t kDpapiPrefixLen = 6;

bool DpapiEncrypt(const std::string& plaintext, std::vector<uint8_t>* out_cipher) {
  if (out_cipher == nullptr) return false;
  out_cipher->clear();

  DATA_BLOB in_blob{};
  in_blob.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(plaintext.data()));
  in_blob.cbData = static_cast<DWORD>(plaintext.size());

  DATA_BLOB out_blob{};
  if (!::CryptProtectData(&in_blob, L"SyncHub Secret", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
    return false;
  }

  out_cipher->resize(kDpapiPrefixLen + out_blob.cbData);
  std::memcpy(out_cipher->data(), kDpapiPrefix, kDpapiPrefixLen);
  std::memcpy(out_cipher->data() + kDpapiPrefixLen, out_blob.pbData, out_blob.cbData);

  ::LocalFree(out_blob.pbData);
  return true;
}

bool DpapiDecrypt(const uint8_t* cipher_data, size_t cipher_size, std::string* out_plain) {
  if (cipher_data == nullptr || out_plain == nullptr) return false;
  out_plain->clear();

  if (cipher_size <= kDpapiPrefixLen ||
      std::memcmp(cipher_data, kDpapiPrefix, kDpapiPrefixLen) != 0) {
    return false;
  }

  DATA_BLOB in_blob{};
  in_blob.pbData = const_cast<BYTE*>(cipher_data + kDpapiPrefixLen);
  in_blob.cbData = static_cast<DWORD>(cipher_size - kDpapiPrefixLen);

  DATA_BLOB out_blob{};
  if (!::CryptUnprotectData(&in_blob, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
    return false;
  }

  if (out_blob.pbData != nullptr && out_blob.cbData > 0) {
    out_plain->assign(reinterpret_cast<const char*>(out_blob.pbData),
                      static_cast<size_t>(out_blob.cbData));
  }
  if (out_blob.pbData != nullptr) {
    ::LocalFree(out_blob.pbData);
  }
  return true;
}

bool SaveDpapiSecretToRegistry(const std::wstring& target,
                               const std::vector<uint8_t>& cipher) {
  HKEY hkey = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kSecureRegSubKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
                        &hkey, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const LSTATUS status = ::RegSetValueExW(
      hkey, target.c_str(), 0, REG_BINARY,
      cipher.data(), static_cast<DWORD>(cipher.size()));
  ::RegCloseKey(hkey);
  return status == ERROR_SUCCESS;
}

bool ReadDpapiSecretFromRegistry(const std::wstring& target,
                                 std::vector<uint8_t>* out_cipher) {
  if (out_cipher == nullptr) return false;
  out_cipher->clear();

  HKEY hkey = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kSecureRegSubKey, 0,
                      KEY_QUERY_VALUE, &hkey) != ERROR_SUCCESS) {
    return false;
  }

  DWORD type = 0;
  DWORD cb_data = 0;
  LSTATUS status = ::RegQueryValueExW(hkey, target.c_str(), nullptr,
                                      &type, nullptr, &cb_data);
  if (status != ERROR_SUCCESS || type != REG_BINARY || cb_data == 0) {
    ::RegCloseKey(hkey);
    return false;
  }

  out_cipher->resize(cb_data);
  status = ::RegQueryValueExW(hkey, target.c_str(), nullptr, &type,
                              out_cipher->data(), &cb_data);
  ::RegCloseKey(hkey);
  return status == ERROR_SUCCESS;
}

bool DeleteDpapiSecretFromRegistry(const std::wstring& target) {
  HKEY hkey = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kSecureRegSubKey, 0,
                      KEY_SET_VALUE, &hkey) != ERROR_SUCCESS) {
    return true;
  }
  const LSTATUS status = ::RegDeleteValueW(hkey, target.c_str());
  ::RegCloseKey(hkey);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

// GDI+ PNG encoder CLSID: {557CF406-1A04-11D3-9A73-0000F81EF32E}
constexpr CLSID kPngEncoderClsid = {
    0x557cf406,
    0x1a04,
    0x11d3,
    {0x9a, 0x73, 0x00, 0x00, 0xf8, 0x1e, 0xf3, 0x2e}};

class ScopedClipboard {
 public:
  explicit ScopedClipboard(HWND owner) {
    for (int attempt = 0; attempt < 6; ++attempt) {
      if (::OpenClipboard(owner)) {
        open_ = true;
        break;
      }
      ::Sleep(10);
    }
  }
  ~ScopedClipboard() {
    if (open_) {
      ::CloseClipboard();
    }
  }
  ScopedClipboard(const ScopedClipboard&) = delete;
  ScopedClipboard& operator=(const ScopedClipboard&) = delete;

  bool is_open() const { return open_; }

 private:
  bool open_ = false;
};

std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int input_len = static_cast<int>(utf8.size());
  const int wide_len =
      ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), input_len, nullptr, 0);
  if (wide_len <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(wide_len), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), input_len, wide.data(), wide_len);
  if (converted <= 0) {
    return std::wstring();
  }
  return wide;
}

void CopyWideTruncated(wchar_t* dest,
                       size_t dest_capacity,
                       const std::wstring& src) {
  if (dest == nullptr || dest_capacity == 0) {
    return;
  }
  std::memset(dest, 0, dest_capacity * sizeof(wchar_t));
  if (src.empty() || dest_capacity == 1) {
    return;
  }
  size_t copy_len = std::min(src.size(), dest_capacity - 1);
  // Avoid splitting a UTF-16 surrogate pair at the truncation boundary.
  if (copy_len < src.size() && copy_len > 0) {
    const wchar_t last = src[copy_len - 1];
    if (last >= 0xD800 && last <= 0xDBFF) {
      --copy_len;
    }
  }
  if (copy_len > 0) {
    std::memcpy(dest, src.data(), copy_len * sizeof(wchar_t));
  }
  dest[copy_len] = L'\0';
}

std::wstring EscapeMenuLabel(const std::wstring& raw) {
  std::wstring out;
  out.reserve(raw.size() + 4);
  for (wchar_t ch : raw) {
    if (ch == L'&') {
      out.append(L"&&");
    } else if (ch == L'\r' || ch == L'\n' || ch == L'\t') {
      out.push_back(L' ');
    } else {
      out.push_back(ch);
    }
  }
  return out;
}

const flutter::EncodableMap* AsMap(const flutter::EncodableValue* value) {
  if (value == nullptr) {
    return nullptr;
  }
  return std::get_if<flutter::EncodableMap>(value);
}

const flutter::EncodableValue* FindKey(const flutter::EncodableMap& map,
                                       const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &it->second;
}

const std::string* GetStringField(const flutter::EncodableMap& map,
                                  const char* key) {
  const auto* val = FindKey(map, key);
  if (val == nullptr) {
    return nullptr;
  }
  return std::get_if<std::string>(val);
}

bool GetBoolField(const flutter::EncodableMap& map,
                  const char* key,
                  bool fallback) {
  const auto* val = FindKey(map, key);
  if (val == nullptr) {
    return fallback;
  }
  if (const auto* b = std::get_if<bool>(val)) {
    return *b;
  }
  return fallback;
}

std::string ValueToString(const flutter::EncodableValue* val) {
  if (val == nullptr) {
    return std::string();
  }
  if (const auto* s = std::get_if<std::string>(val)) {
    return *s;
  }
  if (const auto len = val->TryGetLongValue()) {
    return std::to_string(*len);
  }
  return std::string();
}

std::wstring GetCurrentExePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  while (buffer.size() <= 32768) {
    const DWORD len = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (len == 0) {
      return std::wstring();
    }
    if (len < buffer.size() - 1) {
      buffer.resize(static_cast<size_t>(len));
      return buffer;
    }
    buffer.resize(buffer.size() * 2, L'\0');
  }
  return std::wstring();
}

bool ReadLaunchAtLoginFromRegistry() {
  HKEY hkey = nullptr;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunRegKeyPath, 0, KEY_QUERY_VALUE,
                      &hkey) != ERROR_SUCCESS) {
    return false;
  }
  DWORD type = 0;
  DWORD data_bytes = 0;
  const LSTATUS status = ::RegQueryValueExW(
      hkey, kRunRegValueName, nullptr, &type, nullptr, &data_bytes);
  ::RegCloseKey(hkey);
  return status == ERROR_SUCCESS &&
         (type == REG_SZ || type == REG_EXPAND_SZ) &&
         data_bytes > sizeof(wchar_t);
}

bool WriteLaunchAtLoginToRegistry(bool enabled) {
  HKEY hkey = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunRegKeyPath, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &hkey,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status = ERROR_SUCCESS;
  if (enabled) {
    const std::wstring exe_path = GetCurrentExePath();
    if (exe_path.empty()) {
      ::RegCloseKey(hkey);
      return false;
    }
    const std::wstring command = L"\"" + exe_path + L"\" --minimized";
    const DWORD cb =
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
    status = ::RegSetValueExW(hkey, kRunRegValueName, 0, REG_SZ,
                              reinterpret_cast<const BYTE*>(command.c_str()),
                              cb);
  } else {
    status = ::RegDeleteValueW(hkey, kRunRegValueName);
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  ::RegCloseKey(hkey);
  return status == ERROR_SUCCESS;
}

bool DeserializeCliArgs(const void* data,
                        DWORD size,
                        std::vector<std::string>* out_args) {
  if (out_args == nullptr) {
    return false;
  }
  out_args->clear();
  if (data == nullptr || size < sizeof(uint32_t)) {
    return false;
  }

  const auto* bytes = static_cast<const uint8_t*>(data);
  const size_t total = static_cast<size_t>(size);
  size_t offset = 0;

  uint32_t count = 0;
  std::memcpy(&count, bytes + offset, sizeof(uint32_t));
  offset += sizeof(uint32_t);
  if (count > 4096) {
    return false;
  }

  out_args->reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    if (total - offset < sizeof(uint32_t)) {
      out_args->clear();
      return false;
    }
    uint32_t len = 0;
    std::memcpy(&len, bytes + offset, sizeof(uint32_t));
    offset += sizeof(uint32_t);
    const size_t arg_len = static_cast<size_t>(len);
    if (total - offset < arg_len) {
      out_args->clear();
      return false;
    }
    out_args->emplace_back(reinterpret_cast<const char*>(bytes + offset),
                           arg_len);
    offset += arg_len;
  }
  return true;
}

size_t TrimPngBufferLength(const uint8_t* data, size_t size) {
  static constexpr uint8_t kPngSig[8] = {0x89, 'P', 'N', 'G',
                                         0x0D, 0x0A, 0x1A, 0x0A};
  if (data == nullptr || size < sizeof(kPngSig) ||
      std::memcmp(data, kPngSig, sizeof(kPngSig)) != 0) {
    return 0;
  }

  size_t pos = sizeof(kPngSig);
  while (size - pos >= 12) {
    const uint32_t chunk_len =
        (static_cast<uint32_t>(data[pos]) << 24) |
        (static_cast<uint32_t>(data[pos + 1]) << 16) |
        (static_cast<uint32_t>(data[pos + 2]) << 8) |
        static_cast<uint32_t>(data[pos + 3]);
    const size_t full_chunk = 12 + static_cast<size_t>(chunk_len);
    if (size - pos < full_chunk) {
      return size;
    }
    const bool is_iend = std::memcmp(data + pos + 4, "IEND", 4) == 0;
    pos += full_chunk;
    if (is_iend) {
      return pos;
    }
  }
  return size;
}

size_t ComputeDibPixelOffset(const BITMAPINFOHEADER* hdr, size_t total_size) {
  if (hdr == nullptr || hdr->biSize < sizeof(BITMAPINFOHEADER) ||
      hdr->biSize > total_size) {
    return 0;
  }
  size_t offset = static_cast<size_t>(hdr->biSize);
  if (hdr->biSize == sizeof(BITMAPINFOHEADER)) {
    if (hdr->biCompression == BI_BITFIELDS &&
        (hdr->biBitCount == 16 || hdr->biBitCount == 32)) {
      offset += 3 * sizeof(DWORD);
    } else if (hdr->biCompression == 6 /* BI_ALPHABITFIELDS */) {
      offset += 4 * sizeof(DWORD);
    }
  }
  if (hdr->biClrUsed > 0) {
    offset += static_cast<size_t>(hdr->biClrUsed) * sizeof(RGBQUAD);
  } else if (hdr->biBitCount > 0 && hdr->biBitCount <= 8) {
    offset += (static_cast<size_t>(1) << hdr->biBitCount) * sizeof(RGBQUAD);
  }
  if (offset >= total_size) {
    return 0;
  }
  return offset;
}

bool EncodeGpBitmapToPng(Gdiplus::GpBitmap* bitmap,
                         std::vector<uint8_t>* out_png) {
  if (bitmap == nullptr || out_png == nullptr) {
    return false;
  }
  IStream* stream = nullptr;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      stream == nullptr) {
    return false;
  }

  bool ok = false;
  if (Gdiplus::DllExports::GdipSaveImageToStream(
          bitmap, stream, &kPngEncoderClsid, nullptr) == Gdiplus::Ok) {
    STATSTG stat{};
    HGLOBAL h_mem = nullptr;
    if (SUCCEEDED(stream->Stat(&stat, STATFLAG_NONAME)) &&
        stat.cbSize.QuadPart > 0 &&
        stat.cbSize.QuadPart <= 512ULL * 1024ULL * 1024ULL &&
        SUCCEEDED(::GetHGlobalFromStream(stream, &h_mem)) &&
        h_mem != nullptr) {
      const size_t byte_len = static_cast<size_t>(stat.cbSize.QuadPart);
      const void* ptr = ::GlobalLock(h_mem);
      if (ptr != nullptr) {
        out_png->assign(static_cast<const uint8_t*>(ptr),
                        static_cast<const uint8_t*>(ptr) + byte_len);
        ::GlobalUnlock(h_mem);
        ok = true;
      }
    }
  }

  stream->Release();
  return ok;
}

HGLOBAL CreateDibFromPngBytes(const std::vector<uint8_t>& png_bytes) {
  if (png_bytes.empty()) {
    return nullptr;
  }
  HGLOBAL h_stream_mem = ::GlobalAlloc(GMEM_MOVEABLE, png_bytes.size());
  if (h_stream_mem == nullptr) {
    return nullptr;
  }
  void* stream_ptr = ::GlobalLock(h_stream_mem);
  if (stream_ptr == nullptr) {
    ::GlobalFree(h_stream_mem);
    return nullptr;
  }
  std::memcpy(stream_ptr, png_bytes.data(), png_bytes.size());
  ::GlobalUnlock(h_stream_mem);

  IStream* stream = nullptr;
  if (FAILED(::CreateStreamOnHGlobal(h_stream_mem, TRUE, &stream)) ||
      stream == nullptr) {
    ::GlobalFree(h_stream_mem);
    return nullptr;
  }

  Gdiplus::GpBitmap* bitmap = nullptr;
  if (Gdiplus::DllExports::GdipCreateBitmapFromStream(stream, &bitmap) !=
          Gdiplus::Ok ||
      bitmap == nullptr) {
    stream->Release();
    return nullptr;
  }

  UINT width = 0;
  UINT height = 0;
  if (Gdiplus::DllExports::GdipGetImageWidth(bitmap, &width) != Gdiplus::Ok ||
      Gdiplus::DllExports::GdipGetImageHeight(bitmap, &height) != Gdiplus::Ok ||
      width == 0 || height == 0 || width > 32768 || height > 32768) {
    Gdiplus::DllExports::GdipDisposeImage(bitmap);
    stream->Release();
    return nullptr;
  }

  Gdiplus::Rect lock_rect(0, 0, static_cast<INT>(width),
                          static_cast<INT>(height));
  Gdiplus::BitmapData bmp_data{};
  if (Gdiplus::DllExports::GdipBitmapLockBits(
          bitmap, &lock_rect, Gdiplus::ImageLockModeRead, PixelFormat32bppARGB,
          &bmp_data) != Gdiplus::Ok) {
    Gdiplus::DllExports::GdipDisposeImage(bitmap);
    stream->Release();
    return nullptr;
  }

  const size_t row_bytes = static_cast<size_t>(width) * 4;
  const size_t image_bytes = row_bytes * static_cast<size_t>(height);
  const size_t total_dib_bytes = sizeof(BITMAPINFOHEADER) + image_bytes;

  HGLOBAL h_dib = ::GlobalAlloc(GMEM_MOVEABLE, total_dib_bytes);
  if (h_dib != nullptr) {
    auto* dib_bytes = static_cast<uint8_t*>(::GlobalLock(h_dib));
    if (dib_bytes != nullptr) {
      BITMAPINFOHEADER hdr{};
      hdr.biSize = sizeof(BITMAPINFOHEADER);
      hdr.biWidth = static_cast<LONG>(width);
      hdr.biHeight = static_cast<LONG>(height);  // Bottom-up DIB for max compat
      hdr.biPlanes = 1;
      hdr.biBitCount = 32;
      hdr.biCompression = BI_RGB;
      hdr.biSizeImage = static_cast<DWORD>(image_bytes);
      std::memcpy(dib_bytes, &hdr, sizeof(BITMAPINFOHEADER));

      uint8_t* dst_pixels = dib_bytes + sizeof(BITMAPINFOHEADER);
      const auto* src_base = static_cast<const uint8_t*>(bmp_data.Scan0);
      const ptrdiff_t src_stride = static_cast<ptrdiff_t>(bmp_data.Stride);

      for (UINT y = 0; y < height; ++y) {
        const UINT src_y = height - 1 - y;
        const uint8_t* src_row =
            src_base + static_cast<ptrdiff_t>(src_y) * src_stride;
        std::memcpy(dst_pixels + static_cast<size_t>(y) * row_bytes, src_row,
                    row_bytes);
      }
      ::GlobalUnlock(h_dib);
    } else {
      ::GlobalFree(h_dib);
      h_dib = nullptr;
    }
  }

  Gdiplus::DllExports::GdipBitmapUnlockBits(bitmap, &bmp_data);
  Gdiplus::DllExports::GdipDisposeImage(bitmap);
  stream->Release();
  return h_dib;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : FlutterWindow(project, {}, false) {}

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::vector<std::string> initial_cli_args,
                             bool start_minimized)
    : project_(project), start_minimized_(start_minimized) {
  if (!initial_cli_args.empty()) {
    pending_cli_batches_.push_back(std::move(initial_cli_args));
  }
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  tray_launch_at_login_ = ReadLaunchAtLoginFromRegistry();
  taskbar_created_msg_ = ::RegisterWindowMessageW(L"TaskbarCreated");

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterChannels();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  AddOrUpdateTrayIcon();

  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::ChangeWindowMessageFilterEx(hwnd, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    ::ChangeWindowMessageFilterEx(hwnd, 0x0049 /* WM_COPYGLOBALDATA */, MSGFLT_ALLOW, nullptr);

    if (::AddClipboardFormatListener(hwnd)) {
      clipboard_listener_registered_ = true;
    }
    if (::RegisterHotKey(hwnd, kHotkeySendClipboard,
                         MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT, 'V')) {
      hotkey_registered_ = true;
    }

    if (::WTSRegisterSessionNotification(hwnd, NOTIFY_FOR_THIS_SESSION)) {
      session_notification_registered_ = true;
    }
  }

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    if (!start_minimized_) {
      this->Show();
    }
  });

  // Ensure a frame is pending so SetNextFrameCallback runs reliably.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (secure_channel_) {
    secure_channel_->SetMethodCallHandler(nullptr);
    secure_channel_.reset();
  }
  if (desktop_channel_) {
    desktop_channel_->SetMethodCallHandler(nullptr);
    desktop_channel_.reset();
  }

  RemoveTrayIcon();

  HWND hwnd = GetHandle();
  if (clipboard_listener_registered_ && hwnd != nullptr) {
    ::RemoveClipboardFormatListener(hwnd);
    clipboard_listener_registered_ = false;
  }
  if (hotkey_registered_ && hwnd != nullptr) {
    ::UnregisterHotKey(hwnd, kHotkeySendClipboard);
    hotkey_registered_ = false;
  }
  if (session_notification_registered_ && hwnd != nullptr) {
    ::WTSUnRegisterSessionNotification(hwnd);
    session_notification_registered_ = false;
  }

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();

  secure_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "synchub/secure", codec);
  secure_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        this->HandleSecureCall(call, std::move(result));
      });

  desktop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "synchub/desktop", codec);
  desktop_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        this->HandleDesktopCall(call, std::move(result));
      });
}

void FlutterWindow::HandleSecureCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = AsMap(call.arguments());
  if (args == nullptr) {
    result->Error("INVALID_ARGS", "Expected map arguments");
    return;
  }
  const std::string* key_ptr = GetStringField(*args, "key");
  if (key_ptr == nullptr || key_ptr->empty()) {
    result->Error("INVALID_ARGS", "Missing non-empty 'key'");
    return;
  }
  const std::wstring target = std::wstring(kCredPrefix) + WideFromUtf8(*key_ptr);
  const std::string& method = call.method_name();

  if (method == "read") {
    PCREDENTIALW cred = nullptr;
    if (::CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &cred)) {
      std::string secret;
      if (cred->CredentialBlob != nullptr && cred->CredentialBlobSize > 0) {
        secret.assign(reinterpret_cast<const char*>(cred->CredentialBlob),
                      static_cast<size_t>(cred->CredentialBlobSize));
      }
      ::CredFree(cred);
      result->Success(flutter::EncodableValue(secret));
      return;
    }

    std::vector<uint8_t> cipher;
    if (ReadDpapiSecretFromRegistry(target, &cipher)) {
      std::string plain;
      if (DpapiDecrypt(cipher.data(), cipher.size(), &plain)) {
        result->Success(flutter::EncodableValue(plain));
        return;
      }
      result->Success(flutter::EncodableValue());
      return;
    }

    const DWORD err = ::GetLastError();
    if (err == ERROR_NOT_FOUND || err == ERROR_FILE_NOT_FOUND) {
      result->Success(flutter::EncodableValue());
    } else {
      result->Error("CRED_READ_FAILED", "CredReadW failed: " + std::to_string(err));
    }
    return;
  }

  if (method == "write") {
    const auto* val_field = FindKey(*args, "value");
    const std::string* val_str =
        val_field != nullptr ? std::get_if<std::string>(val_field) : nullptr;
    if (val_field == nullptr || val_field->IsNull() || val_str == nullptr ||
        val_str->empty()) {
      ::CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
      DeleteDpapiSecretFromRegistry(target);
      result->Success(flutter::EncodableValue(true));
      return;
    }

    if (val_str->size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      std::vector<uint8_t> cipher;
      if (!DpapiEncrypt(*val_str, &cipher) ||
          !SaveDpapiSecretToRegistry(target, cipher)) {
        result->Error("DPAPI_WRITE_FAILED", "Failed to encrypt and store secret with DPAPI");
        return;
      }
      ::CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
      result->Success(flutter::EncodableValue(true));
      return;
    }

    CREDENTIALW cred{};
    cred.Flags = 0;
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = const_cast<LPWSTR>(target.c_str());
    cred.CredentialBlobSize = static_cast<DWORD>(val_str->size());
    cred.CredentialBlob =
        reinterpret_cast<LPBYTE>(const_cast<char*>(val_str->data()));
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = const_cast<LPWSTR>(L"SyncHub");

    if (!::CredWriteW(&cred, 0)) {
      const DWORD err = ::GetLastError();
      result->Error("CRED_WRITE_FAILED", "CredWriteW failed: " + std::to_string(err));
      return;
    }
    DeleteDpapiSecretFromRegistry(target);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "delete") {
    ::CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
    DeleteDpapiSecretFromRegistry(target);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::HandleDesktopCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "ready") {
    dart_ready_ = true;
    flutter::EncodableList queued;
    queued.reserve(pending_cli_batches_.size());
    for (const auto& batch : pending_cli_batches_) {
      flutter::EncodableList args_list;
      args_list.reserve(batch.size());
      for (const auto& item : batch) {
        args_list.emplace_back(item);
      }
      flutter::EncodableMap entry;
      entry[flutter::EncodableValue("kind")] = flutter::EncodableValue("cli");
      entry[flutter::EncodableValue("args")] =
          flutter::EncodableValue(std::move(args_list));
      queued.emplace_back(std::move(entry));
    }
    pending_cli_batches_.clear();
    result->Success(flutter::EncodableValue(std::move(queued)));
    return;
  }

  if (method == "updateTrayState") {
    if (const auto* map = AsMap(call.arguments())) {
      if (const std::string* s = GetStringField(*map, "status")) {
        if (!s->empty()) {
          tray_status_ = WideFromUtf8(*s);
        }
      } else if (const std::string* st = GetStringField(*map, "statusText")) {
        if (!st->empty()) {
          tray_status_ = WideFromUtf8(*st);
        }
      }

      if (const std::string* tip = GetStringField(*map, "tooltip")) {
        if (!tip->empty()) {
          tray_tooltip_ = WideFromUtf8(*tip);
          AddOrUpdateTrayIcon();
        }
      }

      tray_auto_accept_ = GetBoolField(
          *map, "autoAccept",
          GetBoolField(*map, "auto_accept", tray_auto_accept_));
      tray_clip_sync_ = GetBoolField(
          *map, "clipSync",
          GetBoolField(*map, "clip_sync", tray_clip_sync_));
      tray_launch_at_login_ = GetBoolField(
          *map, "launchAtLogin",
          GetBoolField(*map, "launch_at_login", tray_launch_at_login_));

      if (const auto* devs_val = FindKey(*map, "devices")) {
        if (const auto* devs_list =
                std::get_if<flutter::EncodableList>(devs_val)) {
          tray_devices_.clear();
          tray_devices_.reserve(devs_list->size());
          for (const auto& elem : *devs_list) {
            const auto* dm = AsMap(&elem);
            if (dm == nullptr) {
              continue;
            }
            std::string id = ValueToString(FindKey(*dm, "id"));
            if (id.empty()) {
              id = ValueToString(FindKey(*dm, "deviceId"));
            }
            if (id.empty()) {
              id = ValueToString(FindKey(*dm, "device_id"));
            }
            if (id.empty()) {
              continue;
            }
            const std::string* name_ptr = GetStringField(*dm, "name");
            const std::string name_utf8 =
                (name_ptr != nullptr && !name_ptr->empty()) ? *name_ptr : id;
            TrayDeviceItem item;
            item.id = std::move(id);
            item.name = WideFromUtf8(name_utf8);
            item.online = GetBoolField(*dm, "online", false);
            tray_devices_.push_back(std::move(item));
          }
        }
      }

      if (const auto* rec_val = FindKey(*map, "recentItems")) {
        if (const auto* rec_list =
                std::get_if<flutter::EncodableList>(rec_val)) {
          tray_recent_items_.clear();
          for (const auto& elem : *rec_list) {
            if (tray_recent_items_.size() >= 8) {
              break;
            }
            const auto* rm = AsMap(&elem);
            if (rm == nullptr) {
              continue;
            }
            const auto* id_val = FindKey(*rm, "id");
            if (id_val == nullptr || id_val->IsNull()) {
              id_val = FindKey(*rm, "itemId");
            }
            if (id_val == nullptr || id_val->IsNull()) {
              continue;
            }
            std::string label_utf8;
            if (const std::string* t = GetStringField(*rm, "title");
                t != nullptr && !t->empty()) {
              label_utf8 = *t;
            } else if (const std::string* l = GetStringField(*rm, "label");
                       l != nullptr && !l->empty()) {
              label_utf8 = *l;
            } else if (const std::string* n = GetStringField(*rm, "name");
                       n != nullptr && !n->empty()) {
              label_utf8 = *n;
            } else if (const std::string* fn = GetStringField(*rm, "filename");
                       fn != nullptr && !fn->empty()) {
              label_utf8 = *fn;
            } else {
              label_utf8 = ValueToString(id_val);
            }
            TrayRecentItem item;
            item.id = *id_val;
            item.label = WideFromUtf8(label_utf8);
            tray_recent_items_.push_back(std::move(item));
          }
        }
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "notify") {
    std::wstring title = L"SyncHub";
    std::wstring body = L" ";
    std::string path;
    if (const auto* map = AsMap(call.arguments())) {
      if (const std::string* t = GetStringField(*map, "title");
          t != nullptr && !t->empty()) {
        title = WideFromUtf8(*t);
      }
      if (const std::string* b = GetStringField(*map, "body");
          b != nullptr && !b->empty()) {
        body = WideFromUtf8(*b);
      }
      if (const std::string* p = GetStringField(*map, "path"); p != nullptr) {
        path = *p;
      }
    }
    ShowTrayNotification(title, body, path);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "showWindow") {
    RestoreAndActivateWindow();
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "hideWindow") {
    if (HWND hwnd = GetHandle(); hwnd != nullptr) {
      ::ShowWindow(hwnd, SW_HIDE);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "quit") {
    result->Success(flutter::EncodableValue(true));
    RequestQuit();
    return;
  }

  if (method == "getLaunchAtLogin") {
    tray_launch_at_login_ = ReadLaunchAtLoginFromRegistry();
    result->Success(flutter::EncodableValue(tray_launch_at_login_));
    return;
  }

  if (method == "setLaunchAtLogin") {
    bool enabled = false;
    if (const auto* map = AsMap(call.arguments())) {
      enabled = GetBoolField(*map, "enabled", false);
    } else if (call.arguments() != nullptr) {
      if (const auto* b = std::get_if<bool>(call.arguments())) {
        enabled = *b;
      }
    }
    const bool ok = WriteLaunchAtLoginToRegistry(enabled);
    if (ok) {
      tray_launch_at_login_ = enabled;
    } else {
      tray_launch_at_login_ = ReadLaunchAtLoginFromRegistry();
    }
    result->Success(flutter::EncodableValue(ok));
    return;
  }

  if (method == "getClipboardChangeCount") {
    const int64_t seq = static_cast<int64_t>(::GetClipboardSequenceNumber());
    result->Success(flutter::EncodableValue(seq));
    return;
  }

  if (method == "readClipboardFiles") {
    result->Success(flutter::EncodableValue(ReadClipboardFiles()));
    return;
  }

  if (method == "readClipboardImage") {
    result->Success(ReadClipboardImage());
    return;
  }

  if (method == "writeClipboardImage") {
    const std::vector<uint8_t>* bytes_ptr = nullptr;
    if (const auto* map = AsMap(call.arguments())) {
      if (const auto* val = FindKey(*map, "bytes")) {
        bytes_ptr = std::get_if<std::vector<uint8_t>>(val);
      }
    } else if (call.arguments() != nullptr) {
      bytes_ptr = std::get_if<std::vector<uint8_t>>(call.arguments());
    }
    if (bytes_ptr == nullptr || bytes_ptr->empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    result->Success(flutter::EncodableValue(WriteClipboardImage(*bytes_ptr)));
    return;
  }

  if (method == "writeClipboardFiles") {
    std::vector<std::wstring> paths;
    if (const auto* map = AsMap(call.arguments())) {
      if (const auto* val = FindKey(*map, "paths")) {
        if (const auto* list = std::get_if<flutter::EncodableList>(val)) {
          for (const auto& item : *list) {
            if (const auto* text = std::get_if<std::string>(&item)) {
              if (!text->empty()) {
                paths.push_back(WideFromUtf8(*text));
              }
            }
          }
        }
      }
    }
    result->Success(flutter::EncodableValue(WriteClipboardFiles(paths)));
    return;
  }

  if (method == "isClipboardPrivate") {
    result->Success(flutter::EncodableValue(IsClipboardPrivate()));
    return;
  }

  result->NotImplemented();
}

void FlutterWindow::AddOrUpdateTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  tray_hwnd_ = hwnd;

  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = hwnd;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  HICON tray_icon = ::LoadIconW(::GetModuleHandleW(nullptr),
                               MAKEINTRESOURCEW(IDI_APP_ICON));
  if (tray_icon == nullptr) {
    tray_icon = ::LoadIconW(nullptr, IDI_APPLICATION);
  }
  nid.hIcon = tray_icon;
  CopyWideTruncated(nid.szTip, sizeof(nid.szTip) / sizeof(wchar_t),
                    tray_tooltip_);

  if (!tray_added_) {
    if (::Shell_NotifyIconW(NIM_ADD, &nid)) {
      tray_added_ = true;
    } else {
      tray_added_ = ::Shell_NotifyIconW(NIM_MODIFY, &nid) != FALSE;
    }
  } else {
    if (!::Shell_NotifyIconW(NIM_MODIFY, &nid)) {
      tray_added_ = ::Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    }
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_ || tray_hwnd_ == nullptr) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = tray_hwnd_;
  nid.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_added_ = false;
  tray_hwnd_ = nullptr;
}

void FlutterWindow::ShowTrayNotification(const std::wstring& title,
                                         const std::wstring& body,
                                         const std::string& path) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (!tray_added_) {
    AddOrUpdateTrayIcon();
  }
  last_notif_path_ = path;

  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(NOTIFYICONDATAW);
  nid.hWnd = hwnd;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_INFO;
  nid.dwInfoFlags = NIIF_INFO;
  CopyWideTruncated(nid.szInfoTitle, 64, title);
  CopyWideTruncated(nid.szInfo, 256, body.empty() ? std::wstring(L" ") : body);
  ::Shell_NotifyIconW(NIM_MODIFY, &nid);
}

void FlutterWindow::ShowTrayContextMenu() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  const auto devices_snapshot = tray_devices_;
  const auto recent_snapshot = tray_recent_items_;

  // 1. Disabled status header
  const std::wstring header_label = EscapeMenuLabel(tray_status_);
  ::AppendMenuW(menu, MF_STRING | MF_DISABLED | MF_GRAYED, 0,
                header_label.c_str());
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

  // 2. Open SyncHub (default item)
  ::AppendMenuW(menu, MF_STRING, kCmdOpenWindow, L"\u6253\u5F00 SyncHub");
  ::SetMenuDefaultItem(menu, kCmdOpenWindow, FALSE);

  // 3. Send files...
  ::AppendMenuW(menu, MF_STRING, kCmdSendFiles,
                L"\u53D1\u9001\u6587\u4EF6\u2026");

  // 4. Send to device submenu (if devices non-empty)
  if (!devices_snapshot.empty()) {
    HMENU dev_menu = ::CreatePopupMenu();
    if (dev_menu != nullptr) {
      for (size_t i = 0; i < devices_snapshot.size() && i < 500; ++i) {
        const auto& dev = devices_snapshot[i];
        std::wstring label = EscapeMenuLabel(dev.name);
        label += dev.online ? L" (\u5728\u7EBF)" : L" (\u79BB\u7EBF)";
        ::AppendMenuW(dev_menu, MF_STRING,
                      kCmdSendToDeviceBase + static_cast<UINT>(i),
                      label.c_str());
      }
      ::AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(dev_menu),
                    L"\u53D1\u9001\u5230\u8BBE\u5907");
    }
  }

  // 5. Send clipboard
  ::AppendMenuW(menu, MF_STRING, kCmdSendClipboard,
                L"\u53D1\u9001\u526A\u8D34\u677F");

  // 6. Recent items submenu (up to 8)
  HMENU recent_menu = ::CreatePopupMenu();
  if (recent_menu != nullptr) {
    if (recent_snapshot.empty()) {
      ::AppendMenuW(recent_menu, MF_STRING | MF_DISABLED | MF_GRAYED, 0,
                    L"\u6682\u65E0\u6700\u8FD1\u9879\u76EE");
    } else {
      const size_t limit = std::min<size_t>(recent_snapshot.size(), 8);
      for (size_t i = 0; i < limit; ++i) {
        const std::wstring label = EscapeMenuLabel(recent_snapshot[i].label);
        ::AppendMenuW(recent_menu, MF_STRING,
                      kCmdOpenRecentBase + static_cast<UINT>(i), label.c_str());
      }
    }
    ::AppendMenuW(menu, MF_POPUP, reinterpret_cast<UINT_PTR>(recent_menu),
                  L"\u6700\u8FD1\u9879\u76EE");
  }

  // 7. Open receive folder & Web Hub
  ::AppendMenuW(menu, MF_STRING, kCmdOpenRecvDir,
                L"\u6253\u5F00\u63A5\u6536\u6587\u4EF6\u5939");
  ::AppendMenuW(menu, MF_STRING, kCmdOpenWebHub,
                L"\u6253\u5F00\u4E91\u7AEF\u6536\u85CF\u7F51\u9875");

  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

  // 8. Checkable toggles
  ::AppendMenuW(
      menu,
      MF_STRING | (tray_auto_accept_ ? MF_CHECKED : MF_UNCHECKED),
      kCmdToggleAutoAccept, L"\u81EA\u52A8\u63A5\u6536\u6587\u4EF6");
  ::AppendMenuW(
      menu,
      MF_STRING | (tray_clip_sync_ ? MF_CHECKED : MF_UNCHECKED),
      kCmdToggleClipSync, L"\u540C\u6B65\u526A\u8D34\u677F");
  ::AppendMenuW(
      menu,
      MF_STRING | (tray_launch_at_login_ ? MF_CHECKED : MF_UNCHECKED),
      kCmdToggleLaunchAtLogin, L"\u5F00\u673A\u81EA\u52A8\u542F\u52A8");

  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);

  // 9. Quit SyncHub
  ::AppendMenuW(menu, MF_STRING, kCmdQuit, L"\u9000\u51FA SyncHub");

  POINT pt{};
  ::GetCursorPos(&pt);
  ::SetForegroundWindow(hwnd);
  const UINT selected = static_cast<UINT>(::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0,
      hwnd, nullptr));
  ::PostMessageW(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (selected == 0) {
    return;
  }

  switch (selected) {
    case kCmdOpenWindow:
      RestoreAndActivateWindow();
      InvokeTrayAction("openWindow");
      break;
    case kCmdSendFiles:
      InvokeTrayAction("sendFiles");
      break;
    case kCmdSendClipboard:
      InvokeTrayAction("sendClipboard");
      break;
    case kCmdOpenRecvDir:
      InvokeTrayAction("openRecvDir");
      break;
    case kCmdOpenWebHub:
      InvokeTrayAction("openWebHub");
      break;
    case kCmdToggleAutoAccept:
      InvokeTrayAction("toggleAutoAccept");
      break;
    case kCmdToggleClipSync:
      InvokeTrayAction("toggleClipSync");
      break;
    case kCmdToggleLaunchAtLogin:
      InvokeTrayAction("toggleLaunchAtLogin");
      break;
    case kCmdQuit:
      if (dart_ready_ && desktop_channel_) {
        InvokeTrayAction("quit");
      } else {
        RequestQuit();
      }
      break;
    default:
      if (selected >= kCmdSendToDeviceBase &&
          selected < kCmdSendToDeviceBase +
                         static_cast<UINT>(devices_snapshot.size())) {
        const size_t idx = static_cast<size_t>(selected - kCmdSendToDeviceBase);
        const flutter::EncodableValue dev_id(devices_snapshot[idx].id);
        InvokeTrayAction("sendToDevice", "deviceId", &dev_id);
      } else if (selected >= kCmdOpenRecentBase &&
                 selected < kCmdOpenRecentBase +
                                static_cast<UINT>(recent_snapshot.size())) {
        const size_t idx = static_cast<size_t>(selected - kCmdOpenRecentBase);
        InvokeTrayAction("openRecent", "itemId", &recent_snapshot[idx].id);
      }
      break;
  }
}

void FlutterWindow::RestoreAndActivateWindow() {
  start_minimized_ = false;
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  ::SetForegroundWindow(hwnd);
  ::BringWindowToTop(hwnd);
  if (flutter_controller_) {
    if (flutter_controller_->view()) {
      ::SetFocus(flutter_controller_->view()->GetNativeWindow());
    }
    flutter_controller_->ForceRedraw();
  }
}

void FlutterWindow::RequestQuit() {
  allow_quit_ = true;
  SetQuitOnClose(true);
  RemoveTrayIcon();
  if (HWND hwnd = GetHandle(); hwnd != nullptr) {
    ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
  } else {
    ::PostQuitMessage(0);
  }
}

void FlutterWindow::InvokeTrayAction(const std::string& action,
                                     const char* extra_key,
                                     const flutter::EncodableValue* extra_val) {
  if (!desktop_channel_) {
    return;
  }
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("action")] = flutter::EncodableValue(action);
  if (extra_key != nullptr && extra_val != nullptr) {
    payload[flutter::EncodableValue(extra_key)] = *extra_val;
  }
  desktop_channel_->InvokeMethod(
      "onTrayAction",
      std::make_unique<flutter::EncodableValue>(std::move(payload)));
}

void FlutterWindow::HandleIncomingCliArgs(std::vector<std::string> args) {
  if (args.empty()) {
    RestoreAndActivateWindow();
  }
  if (!dart_ready_ || !desktop_channel_) {
    if (!args.empty()) {
      pending_cli_batches_.push_back(std::move(args));
    }
    return;
  }
  flutter::EncodableList encoded_args;
  encoded_args.reserve(args.size());
  for (const auto& arg : args) {
    encoded_args.emplace_back(arg);
  }
  desktop_channel_->InvokeMethod(
      "onCliArgs",
      std::make_unique<flutter::EncodableValue>(std::move(encoded_args)));
}

bool FlutterWindow::EnsureGdiplus() {
  if (gdiplus_token_ != 0) {
    return true;
  }
  Gdiplus::GdiplusStartupInput input;
  if (Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr) ==
      Gdiplus::Ok) {
    return true;
  }
  gdiplus_token_ = 0;
  return false;
}

flutter::EncodableList FlutterWindow::ReadClipboardFiles() {
  flutter::EncodableList result;
  ScopedClipboard clip(GetHandle());
  if (!clip.is_open() || !::IsClipboardFormatAvailable(CF_HDROP)) {
    return result;
  }
  HANDLE h_data = ::GetClipboardData(CF_HDROP);
  if (h_data == nullptr) {
    return result;
  }
  HDROP h_drop = static_cast<HDROP>(h_data);
  const UINT file_count = ::DragQueryFileW(h_drop, 0xFFFFFFFF, nullptr, 0);
  result.reserve(file_count);
  for (UINT i = 0; i < file_count; ++i) {
    const UINT cch = ::DragQueryFileW(h_drop, i, nullptr, 0);
    if (cch == 0) {
      continue;
    }
    std::wstring wide_path(static_cast<size_t>(cch) + 1, L'\0');
    const UINT copied =
        ::DragQueryFileW(h_drop, i, wide_path.data(), cch + 1);
    if (copied > 0) {
      wide_path.resize(static_cast<size_t>(copied));
      std::string utf8 = Utf8FromUtf16(wide_path.c_str());
      if (!utf8.empty()) {
        result.emplace_back(std::move(utf8));
      }
    }
  }
  return result;
}

flutter::EncodableValue FlutterWindow::ReadClipboardImage() {
  ScopedClipboard clip(GetHandle());
  if (!clip.is_open()) {
    return flutter::EncodableValue();
  }

  // 1. Prefer registered raw "PNG" clipboard format if present.
  const UINT png_fmt = ::RegisterClipboardFormatW(L"PNG");
  if (png_fmt != 0 && ::IsClipboardFormatAvailable(png_fmt)) {
    HANDLE h_png = ::GetClipboardData(png_fmt);
    if (h_png != nullptr) {
      const SIZE_T raw_size = ::GlobalSize(h_png);
      const auto* raw_ptr = static_cast<const uint8_t*>(::GlobalLock(h_png));
      if (raw_ptr != nullptr && raw_size >= 8) {
        const size_t valid_len =
            TrimPngBufferLength(raw_ptr, static_cast<size_t>(raw_size));
        if (valid_len >= 8) {
          std::vector<uint8_t> png_bytes(raw_ptr, raw_ptr + valid_len);
          ::GlobalUnlock(h_png);
          return flutter::EncodableValue(std::move(png_bytes));
        }
      }
      if (raw_ptr != nullptr) {
        ::GlobalUnlock(h_png);
      }
    }
  }

  // 2. Fallback to CF_DIB or CF_BITMAP encoded to PNG via GDI+.
  if ((!::IsClipboardFormatAvailable(CF_DIB) &&
       !::IsClipboardFormatAvailable(CF_BITMAP)) ||
      !EnsureGdiplus()) {
    return flutter::EncodableValue();
  }

  Gdiplus::GpBitmap* gp_bitmap = nullptr;

  if (::IsClipboardFormatAvailable(CF_DIB)) {
    HANDLE h_dib = ::GetClipboardData(CF_DIB);
    if (h_dib != nullptr) {
      const SIZE_T dib_size = ::GlobalSize(h_dib);
      void* dib_ptr = ::GlobalLock(h_dib);
      if (dib_ptr != nullptr && dib_size > sizeof(BITMAPINFOHEADER)) {
        const auto* hdr = static_cast<const BITMAPINFOHEADER*>(dib_ptr);
        const size_t pixel_offset =
            ComputeDibPixelOffset(hdr, static_cast<size_t>(dib_size));
        if (pixel_offset > 0) {
          auto* bmi = static_cast<BITMAPINFO*>(dib_ptr);
          void* pixel_bits = static_cast<uint8_t*>(dib_ptr) + pixel_offset;
          if (Gdiplus::DllExports::GdipCreateBitmapFromGdiDib(
                  bmi, pixel_bits, &gp_bitmap) == Gdiplus::Ok &&
              gp_bitmap != nullptr) {
            std::vector<uint8_t> png_bytes;
            const bool ok = EncodeGpBitmapToPng(gp_bitmap, &png_bytes);
            Gdiplus::DllExports::GdipDisposeImage(gp_bitmap);
            gp_bitmap = nullptr;
            ::GlobalUnlock(h_dib);
            if (ok && !png_bytes.empty()) {
              return flutter::EncodableValue(std::move(png_bytes));
            }
          } else {
            gp_bitmap = nullptr;
          }
        }
      }
      if (dib_ptr != nullptr) {
        ::GlobalUnlock(h_dib);
      }
    }
  }

  if (::IsClipboardFormatAvailable(CF_BITMAP)) {
    HBITMAP h_bmp = static_cast<HBITMAP>(::GetClipboardData(CF_BITMAP));
    if (h_bmp != nullptr &&
        Gdiplus::DllExports::GdipCreateBitmapFromHBITMAP(
            h_bmp, nullptr, &gp_bitmap) == Gdiplus::Ok &&
        gp_bitmap != nullptr) {
      std::vector<uint8_t> png_bytes;
      const bool ok = EncodeGpBitmapToPng(gp_bitmap, &png_bytes);
      Gdiplus::DllExports::GdipDisposeImage(gp_bitmap);
      if (ok && !png_bytes.empty()) {
        return flutter::EncodableValue(std::move(png_bytes));
      }
    }
  }

  return flutter::EncodableValue();
}

bool FlutterWindow::WriteClipboardImage(const std::vector<uint8_t>& png_bytes) {
  if (png_bytes.empty() || !EnsureGdiplus()) {
    return false;
  }

  HGLOBAL h_dib = CreateDibFromPngBytes(png_bytes);
  if (h_dib == nullptr) {
    return false;
  }

  HGLOBAL h_png = ::GlobalAlloc(GMEM_MOVEABLE, png_bytes.size());
  if (h_png != nullptr) {
    void* png_dst = ::GlobalLock(h_png);
    if (png_dst != nullptr) {
      std::memcpy(png_dst, png_bytes.data(), png_bytes.size());
      ::GlobalUnlock(h_png);
    } else {
      ::GlobalFree(h_png);
      h_png = nullptr;
    }
  }

  ScopedClipboard clip(GetHandle());
  if (!clip.is_open()) {
    if (h_png != nullptr) {
      ::GlobalFree(h_png);
    }
    ::GlobalFree(h_dib);
    return false;
  }

  if (!::EmptyClipboard()) {
    if (h_png != nullptr) {
      ::GlobalFree(h_png);
    }
    ::GlobalFree(h_dib);
    return false;
  }

  bool any_set = false;
  const UINT png_fmt = ::RegisterClipboardFormatW(L"PNG");
  if (png_fmt != 0 && h_png != nullptr) {
    if (::SetClipboardData(png_fmt, h_png) != nullptr) {
      h_png = nullptr;  // Owned by system clipboard now.
      any_set = true;
    }
  }
  if (h_png != nullptr) {
    ::GlobalFree(h_png);
  }

  if (::SetClipboardData(CF_DIB, h_dib) != nullptr) {
    h_dib = nullptr;  // Owned by system clipboard now.
    any_set = true;
  }
  if (h_dib != nullptr) {
    ::GlobalFree(h_dib);
  }

  return any_set;
}

bool FlutterWindow::WriteClipboardFiles(const std::vector<std::wstring>& paths) {
  if (paths.empty()) {
    return false;
  }
  size_t chars = 1;
  for (const auto& path : paths) {
    if (!path.empty()) {
      chars += path.size() + 1;
    }
  }
  const SIZE_T bytes = sizeof(DROPFILES) + chars * sizeof(wchar_t);
  HGLOBAL mem = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (mem == nullptr) {
    return false;
  }
  auto* base = static_cast<uint8_t*>(::GlobalLock(mem));
  if (base == nullptr) {
    ::GlobalFree(mem);
    return false;
  }
  auto* drop = reinterpret_cast<DROPFILES*>(base);
  drop->pFiles = sizeof(DROPFILES);
  drop->pt.x = 0;
  drop->pt.y = 0;
  drop->fNC = FALSE;
  drop->fWide = TRUE;
  auto* cursor = reinterpret_cast<wchar_t*>(base + sizeof(DROPFILES));
  for (const auto& path : paths) {
    if (path.empty()) continue;
    std::memcpy(cursor, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    cursor += path.size() + 1;
  }
  *cursor = L'\0';
  ::GlobalUnlock(mem);

  ScopedClipboard clip(GetHandle());
  if (!clip.is_open() || !::EmptyClipboard()) {
    ::GlobalFree(mem);
    return false;
  }
  if (::SetClipboardData(CF_HDROP, mem) == nullptr) {
    ::GlobalFree(mem);
    return false;
  }
  return true;
}

bool FlutterWindow::IsClipboardPrivate() {
  ScopedClipboard clip(GetHandle());
  if (!clip.is_open()) {
    return false;
  }
  const UINT excluded =
      ::RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
  if (excluded != 0 && ::IsClipboardFormatAvailable(excluded)) {
    return true;
  }
  const UINT cloud = ::RegisterClipboardFormatW(L"CanUploadToCloudClipboard");
  if (cloud != 0 && ::IsClipboardFormatAvailable(cloud)) {
    HANDLE data = ::GetClipboardData(cloud);
    if (data != nullptr) {
      const auto* flag = static_cast<const DWORD*>(::GlobalLock(data));
      const bool blocked = flag != nullptr && ::GlobalSize(data) >= sizeof(DWORD) && *flag == 0;
      if (flag != nullptr) {
        ::GlobalUnlock(data);
      }
      if (blocked) return true;
    }
  }
  return false;
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd,
                              UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_msg_ != 0 && message == taskbar_created_msg_) {
    tray_added_ = false;
    AddOrUpdateTrayIcon();
    return 0;
  }

  if (message == WM_CLOSE && !allow_quit_) {
    ::ShowWindow(hwnd, SW_HIDE);
    return 0;
  }

  if (message == WM_HOTKEY && wparam == kHotkeySendClipboard) {
    InvokeTrayAction("sendClipboard");
    return 0;
  }

  if (message == WM_CLIPBOARDUPDATE) {
    const int64_t seq = static_cast<int64_t>(::GetClipboardSequenceNumber());
    if (dart_ready_ && desktop_channel_) {
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("seq")] = flutter::EncodableValue(seq);
      desktop_channel_->InvokeMethod(
          "clipboard_changed",
          std::make_unique<flutter::EncodableValue>(std::move(payload)));
    }
    return 0;
  }

  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) {
      is_sleeping_ = true;
      if (dart_ready_ && desktop_channel_) {
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("event")] =
            flutter::EncodableValue("sleep");
        desktop_channel_->InvokeMethod(
            "system_event",
            std::make_unique<flutter::EncodableValue>(std::move(payload)));
      }
      return TRUE;
    }
    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) {
      if (is_sleeping_ || wparam == PBT_APMRESUMEAUTOMATIC) {
        is_sleeping_ = false;
        if (dart_ready_ && desktop_channel_) {
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("event")] =
              flutter::EncodableValue("wake");
          desktop_channel_->InvokeMethod(
              "system_event",
              std::make_unique<flutter::EncodableValue>(std::move(payload)));
        }
      }
      return TRUE;
    }
    return TRUE;
  }

  if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK) {
      session_locked_ = true;
      if (dart_ready_ && desktop_channel_) {
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("event")] =
            flutter::EncodableValue("lock");
        payload[flutter::EncodableValue("sessionId")] =
            flutter::EncodableValue(static_cast<int64_t>(lparam));
        desktop_channel_->InvokeMethod(
            "system_event",
            std::make_unique<flutter::EncodableValue>(std::move(payload)));
      }
      return 0;
    }
    if (wparam == WTS_SESSION_UNLOCK) {
      session_locked_ = false;
      if (dart_ready_ && desktop_channel_) {
        flutter::EncodableMap payload;
        payload[flutter::EncodableValue("event")] =
            flutter::EncodableValue("unlock");
        payload[flutter::EncodableValue("sessionId")] =
            flutter::EncodableValue(static_cast<int64_t>(lparam));
        desktop_channel_->InvokeMethod(
            "system_event",
            std::make_unique<flutter::EncodableValue>(std::move(payload)));
      }
      return 0;
    }
    return 0;
  }

  if (message == WM_ENDSESSION && wparam != FALSE) {
    allow_quit_ = true;
    SetQuitOnClose(true);
    RemoveTrayIcon();
  }

  if (message == WM_COPYDATA) {
    const auto* cds = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (cds != nullptr && cds->dwData == kSyncHubCopyDataMagic) {
      std::vector<std::string> incoming_args;
      if (DeserializeCliArgs(cds->lpData, cds->cbData, &incoming_args)) {
        HandleIncomingCliArgs(std::move(incoming_args));
        return TRUE;
      }
    }
  }

  if (message == kTrayCallbackMessage) {
    const UINT event = LOWORD(lparam);
    switch (event) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        RestoreAndActivateWindow();
        return 0;
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayContextMenu();
        return 0;
      case NIN_BALLOONUSERCLICK:
        if (desktop_channel_) {
          flutter::EncodableMap payload;
          payload[flutter::EncodableValue("path")] =
              flutter::EncodableValue(last_notif_path_);
          desktop_channel_->InvokeMethod(
              "onNotificationClick",
              std::make_unique<flutter::EncodableValue>(std::move(payload)));
        }
        return 0;
      default:
        break;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
