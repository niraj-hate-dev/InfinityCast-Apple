#include "usbmuxd_client.h"

#include <iostream>
#include <sstream>
#include <chrono>

namespace applecast {

namespace {

// Fast XML string extractor helper for usbmuxd plists
std::string ExtractTagValue(const std::string& xml, const std::string& key_name, const std::string& tag) {
  const std::string search_key = "<key>" + key_name + "</key>";
  size_t key_pos = xml.find(search_key);
  if (key_pos == std::string::npos) return "";

  const std::string open_tag = "<" + tag + ">";
  const std::string close_tag = "</" + tag + ">";

  size_t open_pos = xml.find(open_tag, key_pos + search_key.length());
  if (open_pos == std::string::npos) return "";
  open_pos += open_tag.length();

  size_t close_pos = xml.find(close_tag, open_pos);
  if (close_pos == std::string::npos) return "";

  return xml.substr(open_pos, close_pos - open_pos);
}

}  // namespace

UsbmuxdClient::UsbmuxdClient() = default;

UsbmuxdClient::~UsbmuxdClient() {
  StopDiscovery();
}

bool UsbmuxdClient::InitializeWinsock() {
  WSADATA wsa_data;
  const int res = WSAStartup(MAKEWORD(2, 2), &wsa_data);
  return (res == 0);
}

void UsbmuxdClient::CleanupWinsock() {
  WSACleanup();
}

bool UsbmuxdClient::SendUsbmuxPacket(SOCKET sock, const std::string& plist_xml, uint32_t tag) {
  UsbmuxHeader header;
  header.length = static_cast<uint32_t>(sizeof(UsbmuxHeader) + plist_xml.length());
  header.version = kUsbmuxdVersionPlist;
  header.message = kUsbmuxdMessagePlist;
  header.tag = tag;

  // Send 16-byte header
  const char* header_ptr = reinterpret_cast<const char*>(&header);
  int sent = 0;
  while (sent < static_cast<int>(sizeof(UsbmuxHeader))) {
    const int n = send(sock, header_ptr + sent, static_cast<int>(sizeof(UsbmuxHeader)) - sent, 0);
    if (n <= 0) return false;
    sent += n;
  }

  // Send XML plist payload
  const char* xml_ptr = plist_xml.data();
  sent = 0;
  const int total_xml = static_cast<int>(plist_xml.length());
  while (sent < total_xml) {
    const int n = send(sock, xml_ptr + sent, total_xml - sent, 0);
    if (n <= 0) return false;
    sent += n;
  }

  return true;
}

bool UsbmuxdClient::ReceiveUsbmuxPacket(SOCKET sock, std::string* out_plist, uint32_t timeout_ms) {
  if (!out_plist) return false;

  // Wait for readability with timeout
  fd_set read_fds;
  FD_ZERO(&read_fds);
  FD_SET(sock, &read_fds);

  timeval tv;
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;

  const int sel = select(0, &read_fds, nullptr, nullptr, (timeout_ms > 0) ? &tv : nullptr);
  if (sel <= 0) {
    return false;
  }

  UsbmuxHeader header;
  char* header_ptr = reinterpret_cast<char*>(&header);
  int received = 0;
  while (received < static_cast<int>(sizeof(UsbmuxHeader))) {
    const int n = recv(sock, header_ptr + received, static_cast<int>(sizeof(UsbmuxHeader)) - received, 0);
    if (n <= 0) return false;
    received += n;
  }

  if (header.length < sizeof(UsbmuxHeader)) {
    return false;
  }

  const uint32_t payload_len = header.length - sizeof(UsbmuxHeader);
  if (payload_len == 0) {
    out_plist->clear();
    return true;
  }

  std::vector<char> payload_buf(payload_len);
  received = 0;
  while (received < static_cast<int>(payload_len)) {
    const int n = recv(sock, payload_buf.data() + received, payload_len - received, 0);
    if (n <= 0) return false;
    received += n;
  }

  *out_plist = std::string(payload_buf.data(), payload_len);
  return true;
}

bool UsbmuxdClient::StartDiscovery(DeviceAttachedCallback on_attached,
                                   DeviceDetachedCallback on_detached) {
  if (is_running_) {
    return true;
  }

  on_attached_ = std::move(on_attached);
  on_detached_ = std::move(on_detached);

  discovery_sock_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (discovery_sock_ == INVALID_SOCKET) {
    return false;
  }

  sockaddr_in server_addr{};
  server_addr.sin_family = AF_INET;
  server_addr.sin_port = htons(kUsbmuxdDefaultPort);
  inet_pton(AF_INET, kUsbmuxdLoopbackIp, &server_addr.sin_addr);

  if (connect(discovery_sock_, reinterpret_cast<sockaddr*>(&server_addr), sizeof(server_addr)) != 0) {
    closesocket(discovery_sock_);
    discovery_sock_ = INVALID_SOCKET;
    return false;
  }

  // Plist 'Listen' payload as specified in brain.md Section 3
  const std::string listen_plist =
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
      "<plist version=\"1.0\">\n"
      "<dict>\n"
      "    <key>BundleID</key><string>com.applecast.mirror</string>\n"
      "    <key>ClientVersionString</key><string>applecast-1.0</string>\n"
      "    <key>MessageType</key><string>Listen</string>\n"
      "    <key>ProgName</key><string>AppleCast</string>\n"
      "</dict>\n"
      "</plist>\n";

  if (!SendUsbmuxPacket(discovery_sock_, listen_plist, 1)) {
    closesocket(discovery_sock_);
    discovery_sock_ = INVALID_SOCKET;
    return false;
  }

  is_running_ = true;
  discovery_thread_ = std::thread(&UsbmuxdClient::DiscoveryWorker, this);
  return true;
}

void UsbmuxdClient::StopDiscovery() {
  if (!is_running_) {
    return;
  }

  is_running_ = false;
  if (discovery_sock_ != INVALID_SOCKET) {
    closesocket(discovery_sock_);
    discovery_sock_ = INVALID_SOCKET;
  }

  if (discovery_thread_.joinable()) {
    discovery_thread_.join();
  }

  std::lock_guard<std::mutex> lock(devices_mutex_);
  attached_devices_.clear();
}

void UsbmuxdClient::DiscoveryWorker() {
  while (is_running_) {
    std::string packet_xml;
    // Timeout every 1000ms so thread responds quickly to is_running_ changes
    if (!ReceiveUsbmuxPacket(discovery_sock_, &packet_xml, 1000)) {
      continue;
    }

    const std::string msg_type = ExtractTagValue(packet_xml, "MessageType", "string");
    if (msg_type == "Attached") {
      UsbmuxDevice dev;
      ParseAttachedDevice(packet_xml, &dev);
      if (dev.device_id != 0) {
        {
          std::lock_guard<std::mutex> lock(devices_mutex_);
          attached_devices_[dev.device_id] = dev;
        }
        if (on_attached_) {
          on_attached_(dev);
        }
      }
    } else if (msg_type == "Detached") {
      const uint32_t dev_id = ParseDetachedDeviceId(packet_xml);
      if (dev_id != 0) {
        {
          std::lock_guard<std::mutex> lock(devices_mutex_);
          attached_devices_.erase(dev_id);
        }
        if (on_detached_) {
          on_detached_(dev_id);
        }
      }
    }
  }
}

void UsbmuxdClient::ParseAttachedDevice(const std::string& xml, UsbmuxDevice* out_device) {
  if (!out_device) return;

  const std::string id_str = ExtractTagValue(xml, "DeviceID", "integer");
  out_device->device_id = id_str.empty() ? 0 : static_cast<uint32_t>(std::stoul(id_str));

  out_device->serial_number = ExtractTagValue(xml, "SerialNumber", "string");
  out_device->connection_type = ExtractTagValue(xml, "ConnectionType", "string");
  if (out_device->connection_type.empty()) out_device->connection_type = "USB";

  const std::string speed_str = ExtractTagValue(xml, "ConnectionSpeed", "integer");
  out_device->connection_speed = speed_str.empty() ? 480000000 : static_cast<uint32_t>(std::stoul(speed_str));
}

uint32_t UsbmuxdClient::ParseDetachedDeviceId(const std::string& xml) {
  const std::string id_str = ExtractTagValue(xml, "DeviceID", "integer");
  return id_str.empty() ? 0 : static_cast<uint32_t>(std::stoul(id_str));
}

int UsbmuxdClient::ParseResultCode(const std::string& xml) {
  const std::string num_str = ExtractTagValue(xml, "Number", "integer");
  return num_str.empty() ? -1 : std::stoi(num_str);
}

std::vector<UsbmuxDevice> UsbmuxdClient::GetAttachedDevices() {
  std::lock_guard<std::mutex> lock(devices_mutex_);
  std::vector<UsbmuxDevice> list;
  list.reserve(attached_devices_.size());
  for (const auto& pair : attached_devices_) {
    list.push_back(pair.second);
  }
  return list;
}

bool UsbmuxdClient::ConnectTunnel(uint32_t device_id,
                                  uint16_t target_port,
                                  SOCKET* out_socket,
                                  std::string* error_msg) {
  if (!out_socket) return false;

  SOCKET tunnel_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (tunnel_sock == INVALID_SOCKET) {
    if (error_msg) *error_msg = "Failed to create socket for usbmuxd tunnel.";
    return false;
  }

  // Set low-latency TCP_NODELAY on tunnel socket
  const BOOL flag = TRUE;
  setsockopt(tunnel_sock, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&flag), sizeof(flag));

  sockaddr_in server_addr{};
  server_addr.sin_family = AF_INET;
  server_addr.sin_port = htons(kUsbmuxdDefaultPort);
  inet_pton(AF_INET, kUsbmuxdLoopbackIp, &server_addr.sin_addr);

  if (connect(tunnel_sock, reinterpret_cast<sockaddr*>(&server_addr), sizeof(server_addr)) != 0) {
    closesocket(tunnel_sock);
    if (error_msg) *error_msg = "Could not reach local usbmuxd daemon on 127.0.0.1:27015.";
    return false;
  }

  // Target Port in Network Byte Order as specified in brain.md line 97:
  // htons converts host byte order to network byte order
  const uint16_t port_nbo = htons(target_port);

  std::ostringstream ss;
  ss << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
     << "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
     << "<plist version=\"1.0\">\n"
     << "<dict>\n"
     << "    <key>BundleID</key><string>com.applecast.mirror</string>\n"
     << "    <key>ClientVersionString</key><string>applecast-1.0</string>\n"
     << "    <key>MessageType</key><string>Connect</string>\n"
     << "    <key>ProgName</key><string>AppleCast</string>\n"
     << "    <key>DeviceID</key><integer>" << device_id << "</integer>\n"
     << "    <key>PortNumber</key><integer>" << port_nbo << "</integer>\n"
     << "</dict>\n"
     << "</plist>\n";

  if (!SendUsbmuxPacket(tunnel_sock, ss.str(), 2)) {
    closesocket(tunnel_sock);
    if (error_msg) *error_msg = "Failed to send 'Connect' request to usbmuxd.";
    return false;
  }

  std::string response_xml;
  if (!ReceiveUsbmuxPacket(tunnel_sock, &response_xml, 5000)) {
    closesocket(tunnel_sock);
    if (error_msg) *error_msg = "Timed out waiting for usbmuxd 'Connect' response.";
    return false;
  }

  const int result_code = ParseResultCode(response_xml);
  if (result_code != 0) {
    closesocket(tunnel_sock);
    if (error_msg) {
      if (result_code == 61) {
        *error_msg = "Connection refused on target port 15333. Please ensure the iOS AppleCast broadcast is active.";
      } else {
        *error_msg = "usbmuxd rejected connection with result code: " + std::to_string(result_code);
      }
    }
    return false;
  }

  // Result code 0: The socket is now transparently tunneling raw TCP directly to port 15333 on the iOS device!
  *out_socket = tunnel_sock;
  return true;
}

}  // namespace applecast
