import Foundation

enum Format {
    static let dash = "–"

    static func percent(_ v: Double?) -> String {
        guard let v else { return dash }
        return "\(Int((v * 100).rounded()))%"
    }

    static func gigabytes(_ bytes: Double?, digits: Int = 1) -> String {
        guard let bytes else { return dash }
        return String(format: "%.\(digits)f", bytes / 1_073_741_824)
    }

    static func temp(_ v: Double?) -> String {
        guard let v else { return dash }
        return "\(Int(v.rounded()))°"
    }

    static func watts(_ v: Double?) -> String {
        guard let v else { return dash }
        return abs(v) < 10 ? String(format: "%.1fW", v) : String(format: "%.0fW", v)
    }

    static func rpm(_ v: Double) -> String {
        v < 1 ? "off" : "\(Int(v.rounded()))"
    }

    /// Short rate for the menu bar: 0K, 950K, 2.3M, 120M, 1.1G (per second).
    static func shortRate(_ v: Double?) -> String {
        guard let v else { return dash }
        switch v {
        case ..<1e6: return String(format: "%.0fK", v / 1e3)
        case ..<1e8: return String(format: "%.1fM", v / 1e6)
        case ..<1e9: return String(format: "%.0fM", v / 1e6)
        default: return String(format: "%.1fG", v / 1e9)
        }
    }

    /// Long rate for the panel: 120 KB/s, 2.3 MB/s.
    static func rate(_ v: Double?) -> String {
        guard let v else { return dash }
        switch v {
        case ..<1e6: return String(format: "%.0f KB/s", v / 1e3)
        case ..<1e9: return String(format: "%.1f MB/s", v / 1e6)
        default: return String(format: "%.2f GB/s", v / 1e9)
        }
    }

    /// Text shown next to a metric's icon in the menu bar.
    static func bar(_ metric: Metric, _ s: Snapshot) -> String {
        switch metric {
        case .cpu: return percent(s.cpu)
        case .memory: return s.memUsed == nil ? dash : gigabytes(s.memUsed) + "G"
        case .gpu: return percent(s.gpu)
        case .disk: return "R\(shortRate(s.diskRead)) W\(shortRate(s.diskWrite))"
        case .network: return "↓\(shortRate(s.netIn)) ↑\(shortRate(s.netOut))"
        case .cpuTemp: return temp(s.cpuTemp)
        case .gpuTemp: return temp(s.gpuTemp)
        case .batteryTemp: return temp(s.batteryTemp)
        case .fans: return s.fans.isEmpty ? dash : rpm(s.fans.max() ?? 0)
        case .systemPower: return watts(s.systemPower)
        case .gpuPower: return watts(s.gpuPower)
        case .charger: return s.adapterConnected ? watts(s.adapterInput) : "off"
        case .battery:
            guard let w = s.batteryWatts else { return dash }
            return (w > 0 ? "+" : "") + watts(w)
        }
    }

    /// Widest text a metric can show, so its slot in the bar never resizes.
    static func barTemplate(_ metric: Metric) -> String {
        switch metric {
        case .cpu, .gpu: return "100%"
        case .memory: return "99.9G"
        case .disk: return "R99.9M W99.9M"
        case .network: return "↓99.9M ↑99.9M"
        case .cpuTemp, .gpuTemp, .batteryTemp: return "100°"
        case .fans: return "9999"
        case .systemPower, .gpuPower, .charger: return "99.9W"
        case .battery: return "+99.9W"
        }
    }

    static func barSymbol(_ metric: Metric) -> String {
        switch metric {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .gpu, .gpuTemp, .gpuPower: return "display"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .cpuTemp: return "thermometer.medium"
        case .batteryTemp: return "battery.75percent"
        case .fans: return "fan"
        case .systemPower: return "bolt"
        case .charger: return "powerplug"
        case .battery: return "battery.100percent.bolt"
        }
    }

    /// Label/value rows for the dropdown panel. Empty label = spacer row.
    static func panelRows(_ s: Snapshot) -> [(String, String)] {
        var cpu = percent(s.cpu)
        if s.cpuP != nil || s.cpuE != nil { cpu += "   P \(percent(s.cpuP)) · E \(percent(s.cpuE))" }

        let pressure: String
        switch s.pressure {
        case 1: pressure = "normal"
        case 2: pressure = "warning"
        case 4: pressure = "critical"
        default: pressure = dash
        }
        let memory = "\(gigabytes(s.memUsed)) of \(gigabytes(s.memTotal, digits: 0)) GB · pressure \(pressure) · swap \(gigabytes(s.swapUsed)) GB"

        let fans = s.fans.isEmpty ? dash : s.fans.map { $0 < 1 ? "off" : "\(Int($0.rounded())) rpm" }.joined(separator: " · ")

        let charger: String
        if s.adapterConnected {
            let rated = s.adapterRated.map { "\($0) W adapter · " } ?? ""
            charger = rated + "drawing " + spaced(watts(s.adapterInput))
        } else {
            charger = "not connected"
        }

        let battery: String
        if let w = s.batteryWatts {
            if s.charging || w > 0.05 {
                battery = "charging " + spaced(watts(abs(w)))
            } else if w < -0.05 {
                battery = "discharging " + spaced(watts(abs(w)))
            } else {
                battery = "not charging"
            }
        } else {
            battery = dash
        }

        return [
            ("CPU", cpu),
            ("Memory", memory),
            ("GPU", percent(s.gpu)),
            ("Disk", "read \(rate(s.diskRead)) · write \(rate(s.diskWrite))"),
            ("Network", "down \(rate(s.netIn)) · up \(rate(s.netOut))"),
            ("", ""),
            ("CPU temp", spacedTemp(s.cpuTemp)),
            ("GPU temp", spacedTemp(s.gpuTemp)),
            ("Battery temp", spacedTemp(s.batteryTemp)),
            ("Fans", fans),
            ("", ""),
            ("System", spaced(watts(s.systemPower))),
            ("GPU power", spaced(watts(s.gpuPower))),
            ("Charger", charger),
            ("Battery", battery),
        ]
    }

    private static func spaced(_ w: String) -> String {
        w.hasSuffix("W") ? String(w.dropLast()) + " W" : w
    }

    private static func spacedTemp(_ v: Double?) -> String {
        guard let v else { return dash }
        return "\(Int(v.rounded())) °C"
    }
}
