import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    fileprivate let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let sampler = Sampler()
    private let panel = PanelView()
    private let menu = NSMenu()
    private var pickerItems: [NSMenuItem] = []
    private var timer: Timer?
    private var menuOpen = false
    private var lastBarText: [String]?
    private var appearanceObservation: NSKeyValueObservation?
    private var barColor: NSColor?

    private var picked: Set<Metric> {
        didSet {
            UserDefaults.standard.set(Metric.allCases.filter(picked.contains).map(\.rawValue), forKey: "barMetrics")
        }
    }

    override init() {
        picked = Set((UserDefaults.standard.stringArray(forKey: "barMetrics") ?? []).compactMap(Metric.init(rawValue:)))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let picker = NSMenu()
        for metric in Metric.allCases {
            let item = NSMenuItem(title: metric.title, action: #selector(toggle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.rawValue
            picker.addItem(item)
            pickerItems.append(item)
        }
        let pickerItem = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        pickerItem.submenu = picker
        menu.addItem(pickerItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit StatBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu

        // The bar image is drawn in a fixed color, so redraw it when the
        // menu bar switches between light and dark text.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, !self.picked.isEmpty, self.currentBarColor() != self.barColor else { return }
                self.lastBarText = nil
                self.tick()
            }
        }

        panel.show(Snapshot())
        tick()
        updateTimer()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        for item in pickerItems {
            item.state = picked.contains(Metric(rawValue: item.representedObject as! String)!) ? .on : .off
        }
        tick()
        updateTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        updateTimer()
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard let metric = Metric(rawValue: sender.representedObject as! String) else { return }
        if picked.contains(metric) { picked.remove(metric) } else { picked.insert(metric) }
        lastBarText = nil
        tick()
        updateTimer()
    }

    /// Runs only while there is something on screen to update.
    private func updateTimer() {
        let shouldRun = menuOpen || !picked.isEmpty
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !shouldRun {
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        // Skip the work while the display is off. Checked here instead of
        // through NSWorkspace notifications: NSWorkspace loads a private copy
        // of the LaunchServices database (~12 MB).
        if !menuOpen, CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }
        let needed = menuOpen ? Set(Metric.allCases) : picked
        let snapshot = needed.isEmpty ? Snapshot() : sampler.sample(needed)
        if menuOpen { panel.show(snapshot) }
        renderBar(snapshot)
    }

    private func renderBar(_ snapshot: Snapshot) {
        guard let button = statusItem.button else { return }
        let metrics = Metric.allCases.filter(picked.contains)
        let text = metrics.map { Format.bar($0, snapshot) }
        guard text != lastBarText else { return }
        lastBarText = text
        if metrics.isEmpty {
            let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "StatBar")
            icon?.isTemplate = true
            button.image = icon
            statusItem.length = NSStatusItem.squareLength
        } else {
            let color = currentBarColor()
            barColor = color
            let scale = button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let image = BarImage.make(Array(zip(metrics, text)), color: color, scale: scale)
            // A fixed length stops AppKit from re-running Auto Layout to size
            // the item on every update.
            let length = image.size.width + 10
            if statusItem.length != length { statusItem.length = length }
            button.image = image
        }
    }
}

extension AppDelegate {
    fileprivate func currentBarColor() -> NSColor {
        var color = NSColor.black
        statusItem.button?.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .black
        }
        return color
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
