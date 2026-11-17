import AppKit

/// Draws the picked metrics into one bitmap in the menu bar's text color.
/// A plain bitmap is far cheaper for AppKit to redraw than a template
/// image, which it re-tints through CoreUI on every update.
enum BarImage {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let iconGap: CGFloat = 3
    private static let itemGap: CGFloat = 8
    private static var symbols: [Metric: NSImage] = [:]
    private static var slots: [Metric: CGFloat] = [:]

    static func make(_ items: [(Metric, String)], color: NSColor, scale: CGFloat) -> NSImage {
        let height = NSStatusBar.system.thickness
        var width: CGFloat = 0
        for (index, (metric, _)) in items.enumerated() {
            width += symbol(metric).size.width + iconGap + slot(metric)
            if index < items.count - 1 { width += itemGap }
        }
        let size = NSSize(width: ceil(width), height: height)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size

        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        var x: CGFloat = 0
        for (metric, text) in items {
            let icon = symbol(metric)
            let iconRect = NSRect(x: x, y: ((height - icon.size.height) / 2).rounded(),
                                  width: icon.size.width, height: icon.size.height)
            icon.draw(in: iconRect)
            color.set()
            iconRect.fill(using: .sourceIn)
            x += icon.size.width + iconGap
            let string = text as NSString
            let textHeight = string.size(withAttributes: attributes).height
            string.draw(at: NSPoint(x: x, y: ((height - textHeight) / 2).rounded()), withAttributes: attributes)
            x += slot(metric) + itemGap
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func symbol(_ metric: Metric) -> NSImage {
        if let cached = symbols[metric] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        let image = NSImage(systemSymbolName: Format.barSymbol(metric), accessibilityDescription: metric.title)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 1, height: 1))
        symbols[metric] = image
        return image
    }

    private static func slot(_ metric: Metric) -> CGFloat {
        if let cached = slots[metric] { return cached }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = ceil((Format.barTemplate(metric) as NSString).size(withAttributes: attributes).width)
        slots[metric] = width
        return width
    }
}

/// The detail panel shown inside the dropdown menu.
final class PanelView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 100)]
        style.headIndent = 100
        style.lineSpacing = 2
        return style
    }()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 10))
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.preferredMaxLayoutWidth = 442
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ s: Snapshot) {
        let text = NSMutableAttributedString()
        let rows = Format.panelRows(s)
        for (index, (name, value)) in rows.enumerated() {
            text.append(NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: "\t" + value, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            if index < rows.count - 1 { text.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
        }
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        label.attributedStringValue = text

        // Measure at the real width so a wrapped row adds to the height
        // instead of pushing the last rows out of view.
        let width = frame.width - 28
        let textHeight = ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
            ?? label.fittingSize.height)
        let height = textHeight + 12
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
        label.frame = NSRect(x: 14, y: 6, width: width, height: textHeight)
    }
}
