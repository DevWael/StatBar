import Darwin
import Foundation
import IOKit

enum Metric: String, CaseIterable {
    case cpu, memory, gpu, disk, network
    case cpuTemp, gpuTemp, batteryTemp, fans
    case systemPower, gpuPower, charger, battery

    var title: String {
        switch self {
        case .cpu: return "CPU usage"
        case .memory: return "Memory"
        case .gpu: return "GPU usage"
        case .disk: return "Disk activity"
        case .network: return "Network activity"
        case .cpuTemp: return "CPU temperature"
        case .gpuTemp: return "GPU temperature"
        case .batteryTemp: return "Battery temperature"
        case .fans: return "Fan speed"
        case .systemPower: return "System power"
        case .gpuPower: return "GPU power"
        case .charger: return "Charger input"
        case .battery: return "Battery charge/discharge"
        }
    }
}

struct Snapshot {
    var cpu: Double?
    var cpuP: Double?
    var cpuE: Double?
    var memUsed: Double?
    var memTotal: Double = 0
    var swapUsed: Double?
    var pressure: Int32?
    var gpu: Double?
    var diskRead: Double?
    var diskWrite: Double?
    var netIn: Double?
    var netOut: Double?
    var cpuTemp: Double?
    var gpuTemp: Double?
    var batteryTemp: Double?
    var fans: [Double] = []
    var systemPower: Double?
    var gpuPower: Double?
    var adapterRated: Int?
    var adapterConnected = false
    var adapterInput: Double?
    var batteryWatts: Double?
    var charging = false
}

/// Counter pair turned into per-second rates. Returns nil when there is no
/// fresh previous reading (first call, or more than 2.5s since the last one).
private struct Rate {
    private var last: (time: UInt64, a: UInt64, b: UInt64)?

    mutating func reset() { last = nil }

    mutating func update(_ a: UInt64, _ b: UInt64, now: UInt64) -> (Double, Double)? {
        defer { last = (now, a, b) }
        guard let last, now > last.time, now - last.time < 2_500_000_000,
              a >= last.a, b >= last.b else { return nil }
        let seconds = Double(now - last.time) / 1e9
        return (Double(a - last.a) / seconds, Double(b - last.b) / seconds)
    }
}

/// Reads only the sources the requested metrics need.
final class Sampler {
    private let host = mach_host_self()
    private let pageSize = UInt64(getpagesize())
    private let memTotal: Double
    private let eCores: Int

    private var lastTicks: [UInt32] = []
    private var lastTicksTime: UInt64 = 0

    private let gpuEntry: io_registry_entry_t
    private let batteryEntry: io_registry_entry_t
    private let gpuEnergy = Energy(channel: "GPU Energy")

    private var drives: [io_registry_entry_t] = []
    private var drivesScanned: UInt64 = 0
    private var diskRate = Rate()

    private var netBuffer = [UInt8](repeating: 0, count: 16 * 1024)
    private var physicalInterfaces: [UInt16: Bool] = [:]
    private var netRate = Rate()

    private let smc = SMC()
    private var hasHottestCoreKey = false
    private var cpuTempKeys: [UInt32] = []
    private var gpuTempKeys: [UInt32] = []
    private let fanCount: Int

    init() {
        var size = MemoryLayout<UInt64>.size
        var bytes: UInt64 = 0
        sysctlbyname("hw.memsize", &bytes, &size, nil, 0)
        memTotal = Double(bytes)
        eCores = Int(Sampler.sysctlInt32("hw.perflevel1.logicalcpu") ?? 0)

        gpuEntry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        batteryEntry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))

        fanCount = Int(smc?.value("FNum") ?? 0)
        if let smc {
            // TCMz is the hottest CPU core. Reading it costs one SMC call
            // instead of ~30 (each read takes ~250µs).
            hasHottestCoreKey = smc.value("TCMz") != nil
            for key in smc.allKeys() {
                let name = SMC.name(key)
                let isCPU = name.hasPrefix("Tp") || name.hasPrefix("Te")
                let isGPU = name.hasPrefix("Tg")
                guard isCPU || isGPU, let type = smc.read(key)?.type, SMC.name(type) == "flt " else { continue }
                if isCPU { cpuTempKeys.append(key) } else { gpuTempKeys.append(key) }
            }
        }
    }

    func sample(_ needed: Set<Metric>) -> Snapshot {
        let now = DispatchTime.now().uptimeNanoseconds
        var s = Snapshot()
        s.memTotal = memTotal

        if needed.contains(.cpu) { readCPU(into: &s, now: now) }
        if needed.contains(.memory) { readMemory(into: &s) }
        if needed.contains(.gpu) { s.gpu = readGPU() }
        if needed.contains(.disk) {
            if let (r, w) = diskTotals(now: now), let rate = diskRate.update(r, w, now: now) {
                (s.diskRead, s.diskWrite) = rate
            }
        }
        if needed.contains(.network) {
            if let (i, o) = netTotals(), let rate = netRate.update(i, o, now: now) {
                (s.netIn, s.netOut) = rate
            }
        }
        if let smc {
            if needed.contains(.cpuTemp) {
                s.cpuTemp = hasHottestCoreKey ? smc.value("TCMz") : hottest(cpuTempKeys, smc)
            }
            if needed.contains(.gpuTemp) { s.gpuTemp = hottest(gpuTempKeys, smc) }
            if needed.contains(.batteryTemp) { s.batteryTemp = smc.value("TB0T") }
            if needed.contains(.fans) {
                s.fans = (0..<fanCount).compactMap { smc.value("F\($0)Ac") }
            }
            if needed.contains(.systemPower) { s.systemPower = smc.value("PSTR") }
            if needed.contains(.charger) { s.adapterInput = smc.value("PDTR") }
        }
        if needed.contains(.gpuPower) { s.gpuPower = gpuEnergy.watts(now: now) }
        if needed.contains(.charger) || needed.contains(.battery) { readBattery(into: &s) }
        return s
    }

    private func hottest(_ keys: [UInt32], _ smc: SMC) -> Double? {
        keys.compactMap(smc.value).filter { $0 > 0 && $0 < 150 }.max()
    }

    // MARK: CPU

    private func readCPU(into s: inout Snapshot, now: UInt64) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        defer {
            lastTicks = ticks
            lastTicksTime = now
        }
        guard ticks.count == lastTicks.count, now - lastTicksTime < 2_500_000_000 else { return }

        let states = Int(CPU_STATE_MAX)
        func usage(_ cores: Range<Int>) -> Double? {
            var busy: UInt64 = 0
            var total: UInt64 = 0
            for core in cores {
                let i = core * states
                let user = UInt64(ticks[i + Int(CPU_STATE_USER)] &- lastTicks[i + Int(CPU_STATE_USER)])
                let system = UInt64(ticks[i + Int(CPU_STATE_SYSTEM)] &- lastTicks[i + Int(CPU_STATE_SYSTEM)])
                let nice = UInt64(ticks[i + Int(CPU_STATE_NICE)] &- lastTicks[i + Int(CPU_STATE_NICE)])
                let idle = UInt64(ticks[i + Int(CPU_STATE_IDLE)] &- lastTicks[i + Int(CPU_STATE_IDLE)])
                busy += user + system + nice
                total += user + system + nice + idle
            }
            return total > 0 ? Double(busy) / Double(total) : nil
        }
        let cores = ticks.count / states
        s.cpu = usage(0..<cores)
        // Apple Silicon numbers efficiency cores first.
        if eCores > 0, eCores < cores {
            s.cpuE = usage(0..<eCores)
            s.cpuP = usage(eCores..<cores)
        }
    }

    // MARK: Memory

    private func readMemory(into s: inout Snapshot) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            // Same as Activity Monitor's "Memory Used": app + wired + compressed.
            let app = UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)
            let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            s.memUsed = Double(pages * pageSize)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { s.swapUsed = Double(swap.xsu_used) }
        s.pressure = Sampler.sysctlInt32("kern.memorystatus_vm_pressure_level")
    }

    // MARK: GPU

    private func readGPU() -> Double? {
        guard gpuEntry != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuEntry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary,
              let value = stats["Device Utilization %"] as? NSNumber else { return nil }
        return value.doubleValue / 100
    }

    // MARK: Disk

    private func diskTotals(now: UInt64) -> (UInt64, UInt64)? {
        if drives.isEmpty || now - drivesScanned > 10_000_000_000 {
            let previousCount = drives.count
            drives.forEach { IOObjectRelease($0) }
            drives.removeAll()
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
                while case let entry = IOIteratorNext(iterator), entry != 0 { drives.append(entry) }
                IOObjectRelease(iterator)
            }
            drivesScanned = now
            if drives.count != previousCount { diskRate.reset() }
            physicalInterfaces.removeAll()
        }
        guard !drives.isEmpty else { return nil }
        var read: UInt64 = 0
        var written: UInt64 = 0
        for drive in drives {
            guard let stats = IORegistryEntryCreateCFProperty(drive, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSDictionary else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }

    // MARK: Network

    /// Bytes in/out summed over en* interfaces (Wi-Fi, Ethernet). Skips
    /// loopback and tunnels so VPN traffic isn't counted twice.
    private func netTotals() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0 else { return nil }
        if length > netBuffer.count { netBuffer = [UInt8](repeating: 0, count: length * 2) }
        length = netBuffer.count
        guard sysctl(&mib, 6, &netBuffer, &length, nil, 0) == 0 else { return nil }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        netBuffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if isPhysical(message.ifm_index) {
                        received += message.ifm_data.ifi_ibytes
                        sent += message.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (received, sent)
    }

    private func isPhysical(_ index: UInt16) -> Bool {
        if let known = physicalInterfaces[index] { return known }
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let physical = if_indextoname(UInt32(index), &name) != nil && String(cString: name).hasPrefix("en")
        physicalInterfaces[index] = physical
        return physical
    }

    // MARK: Battery and charger

    private func readBattery(into s: inout Snapshot) {
        guard batteryEntry != 0 else { return }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(batteryEntry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        s.adapterConnected = (property("ExternalConnected") as? Bool) ?? false
        if s.adapterConnected, let details = property("AdapterDetails") as? NSDictionary {
            s.adapterRated = (details["Watts"] as? NSNumber)?.intValue
        }
        s.charging = (property("IsCharging") as? Bool) ?? false
        if let volts = (property("Voltage") as? NSNumber)?.int64Value,
           let amps = (property("Amperage") as? NSNumber)?.int64Value {
            s.batteryWatts = Double(volts) * Double(amps) / 1e6
        }
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}
