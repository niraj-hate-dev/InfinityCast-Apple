#ifndef RUNNER_USBMUXD_CLIENT_H_
#define RUNNER_USBMUXD_CLIENT_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef _WINSOCK_DEPRECATED_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <cstdint>
#include <string>
#include <vector>
#include <functional>
#include <thread>
#include <atomic>
#include <mutex>
#include <map>

namespace applecast {

#pragma pack(push, 1)
/// Standard Usbmuxd Packet Header (16 bytes)
struct UsbmuxHeader {
  uint32_t length;   // Total packet length including this 16-byte header
  uint32_t version;  // Protocol version (1 for plist protocol)
  uint32_t message;  // Message type (8 = USBMUXD_MESSAGE_PLIST)
  uint32_t tag;      // Request correlation tag
};
#pragma pack(pop)

constexpr uint32_t kUsbmuxdVersionPlist = 1;
constexpr uint32_t kUsbmuxdMessagePlist = 8;
constexpr uint16_t kUsbmuxdDefaultPort  = 27015;
constexpr const char* kUsbmuxdLoopbackIp = "127.0.0.1";

/// Represents an iOS physical device detected by usbmuxd over USB.
struct UsbmuxDevice {
  uint32_t device_id = 0;
  std::string serial_number;  // UDID
  std::string connection_type = "USB";
  uint32_t connection_speed = 480000000;
};

using DeviceAttachedCallback = std::function<void(const UsbmuxDevice& device)>;
using DeviceDetachedCallback = std::function<void(uint32_t device_id)>;

/// Architecture Blueprint: Module 1 - USB Multiplexer Client (PC Side)
/// Interfaces with local usbmuxd daemon (127.0.0.1:27015) to:
/// 1. Listen for dynamic iOS device attach/detach events.
/// 2. Establish raw TCP virtual tunnels over USB to target iOS port (e.g., 15333).
class UsbmuxdClient {
 public:
  UsbmuxdClient();
  ~UsbmuxdClient();

  // Initializes Winsock 2.2 subsystem.
  static bool InitializeWinsock();
  static void CleanupWinsock();

  // Starts the background device discovery thread (sends 'Listen' request).
  bool StartDiscovery(DeviceAttachedCallback on_attached,
                      DeviceDetachedCallback on_detached);

  // Stops background discovery and disconnects discovery socket.
  void StopDiscovery();

  // Establishes a transparent TCP virtual tunnel to an iOS port across the USB cable.
  // Upon success (Result code 0), out_socket contains the connected raw streaming socket.
  bool ConnectTunnel(uint32_t device_id,
                     uint16_t target_port,
                     SOCKET* out_socket,
                     std::string* error_msg);

  // Returns list of currently attached devices.
  std::vector<UsbmuxDevice> GetAttachedDevices();

 private:
  void DiscoveryWorker();
  bool SendUsbmuxPacket(SOCKET sock, const std::string& plist_xml, uint32_t tag);
  bool ReceiveUsbmuxPacket(SOCKET sock, std::string* out_plist, uint32_t timeout_ms = 3000);

  // Plist parsing utilities
  void ParseAttachedDevice(const std::string& xml, UsbmuxDevice* out_device);
  uint32_t ParseDetachedDeviceId(const std::string& xml);
  int ParseResultCode(const std::string& xml);

  std::atomic<bool> is_running_{false};
  SOCKET discovery_sock_ = INVALID_SOCKET;
  std::thread discovery_thread_;

  DeviceAttachedCallback on_attached_;
  DeviceDetachedCallback on_detached_;

  std::mutex devices_mutex_;
  std::map<uint32_t, UsbmuxDevice> attached_devices_;
};

}  // namespace applecast

#endif  // RUNNER_USBMUXD_CLIENT_H_
