import AppKit
import LidAwakeCore

/// A window with the volume curve drawn on a presses-by-dB chart, where dragging the bend point
/// reshapes the curve and dragging the end point sets the ceiling and how many presses reach it.
final class ADI2CurveWindowController: NSWindowController, NSWindowDelegate {
    private let editor = ADI2CurveEditorView()
    private let hintLabel = NSTextField(
        wrappingLabelWithString: "拖动圆点改变曲线形状；拖动右端，上下改最大音量，左右改总次数。曲线越陡，那一段每按一下跳得越多。"
    )
    private let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    var onChange: ((ADI2VolumeCurve) -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "ADI-2 音量曲线"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        editor.frame = NSRect(x: 12, y: 64, width: 576, height: 384)
        editor.onChange = { [weak self] curve in
            self?.onChange?(curve)
        }
        hintLabel.frame = NSRect(x: 20, y: 14, width: 440, height: 36)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        resetButton.frame = NSRect(x: 480, y: 18, width: 100, height: 28)
        resetButton.bezelStyle = .rounded
        resetButton.target = self
        resetButton.action = #selector(reset)
        for view in [editor, hintLabel, resetButton] as [NSView] {
            content.addSubview(view)
        }
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(curve: ADI2VolumeCurve, currentTenths: Int?) {
        editor.update(curve: curve, currentTenths: currentTenths)
    }

    func present() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func reset() {
        let curve = ADI2VolumeCurve.standard
        editor.update(curve: curve, currentTenths: editor.currentTenths)
        onChange?(curve)
    }
}

/// The chart itself. The axes are fixed (0 to the most presses allowed, the unit's whole dB
/// range) so the end point can move; each press is marked as a tick on the curve.
private final class ADI2CurveEditorView: NSView {
    private enum Handle {
        case bend
        case end
    }

    private(set) var curve = ADI2VolumeCurve.standard
    private(set) var currentTenths: Int?
    var onChange: ((ADI2VolumeCurve) -> Void)?
    private var dragging: Handle?
    private var hoverPress: Int?
    private static let handleRadius: CGFloat = 7
    private static let lowestDecibels = Double(ADI2Volume.minimumTenths) / 10
    private static let highestDecibels = Double(ADI2Volume.maximumTenths) / 10
    private static let mostPresses = Double(ADI2VolumeCurve.pressCountRange.upperBound)

    override var isFlipped: Bool { false }

    func update(curve: ADI2VolumeCurve, currentTenths: Int?) {
        self.curve = curve
        self.currentTenths = currentTenths
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    // MARK: Geometry

    private var plot: NSRect {
        NSRect(x: bounds.minX + 52, y: bounds.minY + 30, width: bounds.width - 72, height: bounds.height - 60)
    }

    private func point(presses: Double, decibels: Double) -> NSPoint {
        let plot = plot
        return NSPoint(
            x: plot.minX + presses / Self.mostPresses * plot.width,
            y: plot.minY + (decibels - Self.lowestDecibels) / (Self.highestDecibels - Self.lowestDecibels) * plot.height
        )
    }

    private func value(at location: NSPoint) -> (presses: Double, decibels: Double) {
        let plot = plot
        let presses = Double((location.x - plot.minX) / plot.width) * Self.mostPresses
        let decibels = Self.lowestDecibels
            + Double((location.y - plot.minY) / plot.height) * (Self.highestDecibels - Self.lowestDecibels)
        return (presses, decibels)
    }

    private var ceilingDecibels: Double { Double(curve.ceilingTenths) / 10 }

    private var bendPoint: NSPoint {
        point(
            presses: curve.bendX * Double(curve.pressCount),
            decibels: Self.lowestDecibels + curve.bendY * (ceilingDecibels - Self.lowestDecibels)
        )
    }

    private var endPoint: NSPoint {
        point(presses: Double(curve.pressCount), decibels: ceilingDecibels)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        NSColor.separatorColor.setStroke()
        for decibels in stride(from: -110, through: 0, by: 10) {
            let y = point(presses: 0, decibels: Double(decibels)).y
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y))
            line.line(to: NSPoint(x: plot.maxX, y: y))
            line.lineWidth = decibels == 0 ? 1 : 0.5
            line.stroke()
            let text = "\(decibels)" as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: NSPoint(x: plot.minX - size.width - 8, y: y - size.height / 2), withAttributes: labelAttributes)
        }
        for presses in stride(from: 0, through: Int(Self.mostPresses), by: 16) {
            let x = point(presses: Double(presses), decibels: Self.lowestDecibels).x
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plot.minY))
            line.line(to: NSPoint(x: x, y: plot.maxY))
            line.lineWidth = 0.5
            line.stroke()
            let text = "\(presses)" as NSString
            let size = text.size(withAttributes: labelAttributes)
            text.draw(at: NSPoint(x: x - size.width / 2, y: plot.minY - size.height - 6), withAttributes: labelAttributes)
        }
        ("dB" as NSString).draw(at: NSPoint(x: plot.minX - 30, y: plot.maxY + 8), withAttributes: labelAttributes)
        ("按键次数" as NSString).draw(at: NSPoint(x: plot.maxX - 40, y: plot.minY + 6), withAttributes: labelAttributes)

        drawCurrentLevel(in: plot, attributes: labelAttributes)

        let path = NSBezierPath()
        let samples = 240
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let target = point(
                presses: fraction * Double(curve.pressCount),
                decibels: curve.decibels(atPosition: fraction)
            )
            index == 0 ? path.move(to: target) : path.line(to: target)
        }
        path.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        let levels = curve.levels(presses: curve.pressCount)
        NSColor.labelColor.setFill()
        for (press, tenths) in levels.enumerated() {
            let center = point(presses: Double(press), decibels: Double(tenths) / 10)
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
        }

        drawHandle(at: bendPoint, round: true)
        drawHandle(at: endPoint, round: false)
        drawReadout(levels: levels)
    }

    private func drawCurrentLevel(in plot: NSRect, attributes: [NSAttributedString.Key: Any]) {
        guard let currentTenths else { return }
        let y = point(presses: 0, decibels: Double(currentTenths) / 10).y
        let line = NSBezierPath()
        line.move(to: NSPoint(x: plot.minX, y: y))
        line.line(to: NSPoint(x: plot.maxX, y: y))
        line.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.systemOrange.setStroke()
        line.stroke()
        var orange = attributes
        orange[.foregroundColor] = NSColor.systemOrange
        let text = "当前 \(ADI2Volume.text(currentTenths))" as NSString
        let size = text.size(withAttributes: orange)
        text.draw(at: NSPoint(x: plot.maxX - size.width, y: y + 2), withAttributes: orange)
    }

    private func drawHandle(at center: NSPoint, round: Bool) {
        let radius = Self.handleRadius
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let shape = round ? NSBezierPath(ovalIn: rect) : NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.white.setFill()
        shape.fill()
        shape.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        shape.stroke()
    }

    private func drawReadout(levels: [Int]) {
        let text: String
        if let hoverPress, hoverPress > 0, hoverPress < levels.count {
            let level = levels[hoverPress]
            let change = Double(level - levels[hoverPress - 1]) / 10
            text = "第 \(hoverPress) 下 · \(ADI2Volume.text(level)) · 这一下 +\(String(format: "%.1f", change)) dB"
        } else {
            text = "共 \(curve.pressCount) 下 · 最大 \(ADI2Volume.text(curve.ceilingTenths))"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        (text as NSString).draw(at: NSPoint(x: plot.minX + 8, y: plot.maxY - 20), withAttributes: attributes)
    }

    // MARK: Dragging

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let reach = Self.handleRadius + 6
        if hypot(location.x - endPoint.x, location.y - endPoint.y) <= reach {
            dragging = .end
        } else if hypot(location.x - bendPoint.x, location.y - bendPoint.y) <= reach {
            dragging = .bend
        } else {
            dragging = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let (presses, decibels) = value(at: convert(event.locationInWindow, from: nil))
        var next = curve
        switch dragging {
        case .bend:
            let span = ceilingDecibels - Self.lowestDecibels
            next = ADI2VolumeCurve(
                pressCount: curve.pressCount,
                ceilingTenths: curve.ceilingTenths,
                bendX: presses / Double(curve.pressCount),
                bendY: span > 0 ? (decibels - Self.lowestDecibels) / span : 0.5
            )
        case .end:
            // Whole presses and whole dB keep the end readable and the menu limits reachable.
            next = ADI2VolumeCurve(
                pressCount: Int(presses.rounded()),
                ceilingTenths: Int(decibels.rounded()) * 10,
                bendX: curve.bendX,
                bendY: curve.bendY
            )
        }
        hoverPress = nil
        guard next != curve else { return }
        curve = next
        needsDisplay = true
        onChange?(next)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let (presses, _) = value(at: convert(event.locationInWindow, from: nil))
        let press = Int(presses.rounded())
        let hovered = (1...curve.pressCount).contains(press) ? press : nil
        guard hovered != hoverPress else { return }
        hoverPress = hovered
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPress = nil
        needsDisplay = true
    }
}
