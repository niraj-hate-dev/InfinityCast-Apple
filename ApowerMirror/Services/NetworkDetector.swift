//
//  NetworkDetector.swift
//  ApowerMirror / Services
//
//  Reconstructed 1:1 from ApowerMirror WXMirrorCore / Services.
//  Detects active network interfaces (USB cable via Personal Hotspot bridge, Wi-Fi, Loopback).
//

import Foundation
import Network
import Darwin

public final class NetworkDetector {

    public static let shared = NetworkDetector()

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.apowermirror.network.monitor")
    public private(set) var isConnectedViaWifi = false
    public private(set) var isConnectedViaCellular = false
    public private(set) var isConnectedViaWired = false

    /// Returns the currently active network name / SSID fallback
    public static func currentSSID() -> String? {
        let interfaces = NetworkDetector.shared.getActiveIPv4Interfaces()
        if interfaces.keys.contains(where: { $0.hasPrefix("en") }) {
            return "Wi-Fi (Active)"
        }
        return "Connected"
    }

    private init() {
        startMonitoring()
    }

    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.isConnectedViaWifi = path.usesInterfaceType(.wifi)
            self.isConnectedViaCellular = path.usesInterfaceType(.cellular)
            self.isConnectedViaWired = path.usesInterfaceType(.wiredEthernet)
            NSLog("[NetworkDetector] Path updated: WiFi=%d, Cellular=%d, Wired=%d",
                  self.isConnectedViaWifi, self.isConnectedViaCellular, self.isConnectedViaWired)
        }
        monitor.start(queue: monitorQueue)
    }

    /// Returns list of all active IPv4 interfaces
    public func getActiveIPv4Interfaces() -> [String: String] {
        var interfaces: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return interfaces }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }
            guard let interface = ptr?.pointee, let addr = interface.ifa_addr else { continue }
            let addrFamily = addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                interfaces[name] = ip
            }
        }
        return interfaces
    }
}
