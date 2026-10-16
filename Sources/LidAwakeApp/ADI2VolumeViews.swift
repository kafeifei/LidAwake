import AppKit
import LidAwakeCore

/// Menu row with the ADI-2 DAC's current output, level and a slider that sets it on the unit.
final class ADI2VolumeView: NSView {
    private let titleLabel = NSTextField(labelWithString: "ADI-2 DAC")
    private let descriptionLabel = NSTextField(labelWithString: "正在读取…")
    /// The slider runs over bar positions, matching the HUD bar, across the unit's whole range.
    private let slider = NSSlider(
        value: ADI2VolumeCurve.standard.position(-300),
        minValue: 0,
        maxValue: 1,
        target: nil,
        action: nil
    )
    var onVolumeChanged: ((Int) -> Void)?
    /// The user's curve; the slider runs over its positions and ends at its ceiling.
    var curve = ADI2VolumeCurve.standard

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 278, height: 52))

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        descriptionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byTruncatingTail

        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.isContinuous = true
        slider.setAccessibilityLabel("ADI-2 DAC 音量")

        addSubview(titleLabel)
        addSubview(descriptionLabel)
        addSubview(slider)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 14, y: 8, width: 92, height: 17)
        descriptionLabel.frame = NSRect(x: 14, y: 27, width: 92, height: 15)
        slider.frame = NSRect(x: 108, y: 12, width: 156, height: 28)
    }

    func update(output: ADI2Output?, state: ADI2Controller.OutputState?) {
        guard let output, let tenths = state?.volumeTenths else {
            descriptionLabel.stringValue = "正在读取…"
            slider.isEnabled = false
            return
        }
        let muted = state?.muted == true
        let locked = state?.locked == true
        var text = "\(output.title) · \(ADI2Volume.text(tenths))"
        if muted {
            text = "\(output.title) · 已静音"
        } else if locked {
            text += " · 锁定"
        }
        descriptionLabel.stringValue = text
        descriptionLabel.toolTip = text
        slider.isEnabled = !locked
        // Leave the knob alone mid-drag so device echoes cannot fight the pointer.
        if NSEvent.pressedMouseButtons == 0 {
            slider.doubleValue = curve.position(tenths)
        }
        slider.setAccessibilityValue(text)
    }

    @objc private func sliderMoved() {
        let decibels = curve.decibels(atPosition: slider.doubleValue)
        onVolumeChanged?(min(ADI2Volume.snappedToHalfDecibel(decibels), curve.ceilingTenths))
    }
}

/// A small heads-up display shown when the volume keys change the DAC, in place of the system's.
/// Every press redraws it synchronously and restarts the hide timer, so it tracks held keys.
final class VolumeHUD {
    private static let displayDuration: TimeInterval = 1.2
    private static let fadeDuration: TimeInterval = 0.25

    private let panel: NSPanel
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let levelBar = LevelBarView()
    private var hideWorkItem: DispatchWorkItem?
    /// Bumped on every show so a fade that already started cannot hide a newer display.
    private var generation = 0

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        iconView.frame = NSRect(x: 16, y: 22, width: 28, height: 28)
        iconView.contentTintColor = .labelColor
        titleLabel.frame = NSRect(x: 54, y: 40, width: 100, height: 18)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 146, y: 38, width: 80, height: 20)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.alignment = .right
        levelBar.frame = NSRect(x: 54, y: 18, width: 172, height: 6)

        for view in [iconView, titleLabel, valueLabel, levelBar] as [NSView] {
            background.addSubview(view)
        }
        panel.contentView = background
    }

    /// The bar uses the user's curve, so it is full at the curve's ceiling.
    func show(output: ADI2Output, state: ADI2Controller.OutputState, curve: ADI2VolumeCurve) {
        let tenths = state.volumeTenths ?? ADI2Volume.minimumTenths
        // The bar uses the same positions as the slider, so it only empties at the unit's minimum.
        let level = state.muted ? 0 : curve.position(tenths)

        let symbol: String
        switch level {
        case 0: symbol = "speaker.slash.fill"
        case ..<0.34: symbol = "speaker.wave.1.fill"
        case ..<0.67: symbol = "speaker.wave.2.fill"
        default: symbol = "speaker.wave.3.fill"
        }
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        titleLabel.stringValue = "ADI-2 · \(output.title)"
        if state.muted {
            valueLabel.stringValue = "静音"
        } else if state.locked {
            valueLabel.stringValue = "已锁定"
        } else {
            valueLabel.stringValue = ADI2Volume.text(tenths)
        }
        levelBar.level = level

        generation += 1
        hideWorkItem?.cancel()
        if !panel.isVisible {
            position()
        }
        // A zero-length animation replaces any fade still in flight; setting alphaValue directly
        // would leave that fade running and the HUD would dim while the key is held.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
        panel.displayIfNeeded()

        let shownGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut(ifStill: shownGeneration)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displayDuration, execute: workItem)
    }

    private func fadeOut(ifStill shownGeneration: Int) {
        guard shownGeneration == generation else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, shownGeneration == self.generation else { return }
            self.panel.orderOut(nil)
        })
    }

    /// Top-right under the menu bar on the screen with the pointer, where macOS shows its own HUD.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 12))
    }
}

/// A plain level bar that redraws immediately; NSProgressIndicator eases between values, which
/// makes a held volume key look like it lags behind.
private final class LevelBarView: NSView {
    var level: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard level > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * level)
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}
