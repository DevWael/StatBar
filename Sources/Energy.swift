import Foundation

/// Watts for named channels in IOReport's "Energy Model" group, averaged
/// since the previous call.
///
/// On macOS 27 the CPU/ANE/DRAM channels in this group never change
/// (the counters stay frozen), so only "GPU Energy" is usable.
final class Energy {
    private var subscription: IOReportSubscriptionRef?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0

    init(channel: String) {
        guard let group = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0) else { return }
        let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, group) as NSMutableDictionary
        if let list = desired["IOReportChannels"] as? NSArray {
            desired["IOReportChannels"] = list.filter {
                IOReportChannelGetChannelName($0 as! NSDictionary as CFDictionary) as String? == channel
            }
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, desired as CFMutableDictionary, &subscribed, 0, nil)
        channels = subscribed?.takeUnretainedValue()
    }

    /// Nil on the first call, or when the last call was more than 2.5s ago.
    func watts(now: UInt64) -> Double? {
        guard let subscription, let channels,
              let current = IOReportCreateSamples(subscription, channels, nil) else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let previous, now > previousTime, now - previousTime < 2_500_000_000,
              let delta = IOReportCreateSamplesDelta(previous, current, nil),
              let list = (delta as NSDictionary)["IOReportChannels"] as? NSArray else { return nil }
        let seconds = Double(now - previousTime) / 1e9
        var joules = 0.0
        for item in list {
            let channel = item as! NSDictionary as CFDictionary
            let raw = Double(IOReportSimpleGetIntegerValue(channel, 0))
            switch (IOReportChannelGetUnitLabel(channel) as String? ?? "").trimmingCharacters(in: .whitespaces) {
            case "mJ": joules += raw / 1e3
            case "uJ", "µJ": joules += raw / 1e6
            case "nJ": joules += raw / 1e9
            default: break
            }
        }
        return joules / seconds
    }
}
