import CoreWLAN
import SystemConfiguration

/// Wi-Fi band names used in the menu.
enum WiFiBand: String {
    case ghz2_4 = "2.4 GHz"
    case ghz5 = "5 GHz"
    case ghz6 = "6 GHz"

    /// From a frequency in MHz, e.g. 2412 → 2.4 GHz, 5180 → 5 GHz.
    init?(frequencyMHz: Int) {
        switch frequencyMHz {
        case 2400..<2500: self = .ghz2_4
        case 4900..<5925: self = .ghz5
        case 5925..<7200: self = .ghz6
        default: return nil
        }
    }
}

/// Facts about the Mac's own Wi-Fi, read locally from macOS.
/// No network traffic, no permissions needed, and network names are never read.
enum MacNetwork {

    struct WiFiLink {
        let band: WiFiBand?
        let rssi: Int            // signal strength in dBm (closer to 0 is stronger)
        let interfaceName: String
    }

    /// The Mac's current Wi-Fi band and signal (nil if Wi-Fi is off / not connected).
    static func wifiLink() -> WiFiLink? {
        guard let wifi = CWWiFiClient.shared().interface(),
              let name = wifi.interfaceName,
              let channel = wifi.wlanChannel() else { return nil }

        let band: WiFiBand?
        switch channel.channelBand {
        case .band2GHz: band = .ghz2_4
        case .band5GHz: band = .ghz5
        case .band6GHz: band = .ghz6
        default:        band = nil
        }
        return WiFiLink(band: band, rssi: wifi.rssiValue(), interfaceName: name)
    }

    /// The router address of the Mac's Wi-Fi connection, read from macOS's network
    /// configuration. When the Mac is joined to the phone's hotspot, the "router" IS the
    /// phone. Only returned if it's a private home-network IPv4 address.
    static func wifiRouterIP() -> String? {
        let wifiName = CWWiFiClient.shared().interface()?.interfaceName
        guard let store = SCDynamicStoreCreate(nil, "PhoneMirror" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString)
                as? [String] else { return nil }

        for key in keys {
            guard let info = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let router = info["Router"] as? String else { continue }
            // Only the Wi-Fi connection counts (not Ethernet or VPNs).
            if let wifiName, (info["InterfaceName"] as? String) != wifiName { continue }
            if Validation.isPrivateLANIPv4(router) { return router }
        }
        return nil
    }
}
