import AppKit
import Foundation
import IOKit
import IOKit.ps
import LidAwakeCore

struct BatterySnapshot {
    let percentage: Int
    let isCharging: Bool
    let isCharged: Bool
    let isOnACPower: Bool
    let timeToEmptyMinutes: Int?
    let timeToFullMinutes: Int?
    let adapterCapacityWatts: Int?
    let systemLoadWatts: Double?
    let externalInputWatts: Double?
    let batteryWatts: Double?

    var flow: BatteryFlow {
        LidAwakePolicy.batteryFlow(forWatts: batteryWatts)
    }
}

enum BatteryReader {
    private static let systemPowerSensor = SystemPowerSensor()
    private static var batteryFlowResolver = BatteryFlowResolver()

    private struct PowerTelemetry {
        let isCharging: Bool
        let isOnACPower: Bool
        let systemLoadWatts: Double?
        let externalInputWatts: Double?
        let batteryWatts: Double?
    }

    static func read() -> BatterySnapshot? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  (description["Type"] as? String) == "InternalBattery",
                  let current = (description["Current Capacity"] as? NSNumber)?.doubleValue,
                  let maximum = (description["Max Capacity"] as? NSNumber)?.doubleValue,
                  maximum > 0 else {
                continue
            }

            let sourceState = description["Power Source State"] as? String
            let isCharging = (description["Is Charging"] as? NSNumber)?.boolValue ?? false
            let isCharged = (description["Is Charged"] as? NSNumber)?.boolValue ?? false
            let timeToEmpty = normalizedTime(description["Time to Empty"] as? NSNumber)
            let timeToFull = normalizedTime(description["Time to Full Charge"] as? NSNumber)
            let isOnACPower = sourceState == (kIOPSACPowerValue as String)
            let telemetry = readPowerTelemetry(
                isCharging: isCharging,
                isOnACPower: isOnACPower
            )

            return BatterySnapshot(
                percentage: Int((current / maximum * 100).rounded()),
                isCharging: telemetry.isCharging,
                isCharged: isCharged,
                isOnACPower: telemetry.isOnACPower,
                timeToEmptyMinutes: timeToEmpty,
                timeToFullMinutes: timeToFull,
                adapterCapacityWatts: readAdapterCapacityWatts(),
                systemLoadWatts: telemetry.systemLoadWatts,
                externalInputWatts: telemetry.externalInputWatts,
                batteryWatts: telemetry.batteryWatts
            )
        }

        return nil
    }

    private static func normalizedTime(_ number: NSNumber?) -> Int? {
        guard let value = number?.intValue, value > 0 else { return nil }
        return value
    }

    private static func readAdapterCapacityWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
              let watts = details["Watts"] as? NSNumber else {
            return nil
        }
        return watts.intValue
    }

    private static func readPowerTelemetry(
        isCharging: Bool,
        isOnACPower: Bool
    ) -> PowerTelemetry {
        let systemLoadWatts = systemPowerSensor?.readSystemWatts()
        let externalInputWatts = systemPowerSensor?.readExternalInputWatts()
        let batteryDischargeWatts = systemPowerSensor?.readBatteryDischargeWatts()

        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return PowerTelemetry(
                isCharging: isCharging,
                isOnACPower: isOnACPower,
                systemLoadWatts: systemLoadWatts,
                externalInputWatts: externalInputWatts,
                batteryWatts: nil
            )
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return PowerTelemetry(
                isCharging: isCharging,
                isOnACPower: isOnACPower,
                systemLoadWatts: systemLoadWatts,
                externalInputWatts: externalInputWatts,
                batteryWatts: nil
            )
        }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &unmanagedProperties,
            kCFAllocatorDefault,
            0
        ) == KERN_SUCCESS,
        let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else {
            return PowerTelemetry(
                isCharging: isCharging,
                isOnACPower: isOnACPower,
                systemLoadWatts: systemLoadWatts,
                externalInputWatts: externalInputWatts,
                batteryWatts: nil
            )
        }

        let registryIsOnACPower = (properties["ExternalConnected"] as? NSNumber)?.boolValue
            ?? isOnACPower

        let flow = batteryFlowResolver.resolve(
            systemLoadWatts: systemLoadWatts,
            externalInputWatts: externalInputWatts,
            displayedBatteryWatts: batteryDischargeWatts,
            systemIsCharging: isCharging,
            isOnACPower: registryIsOnACPower
        )
        let resolvedIsCharging = flow == .charging
        let batteryWatts: Double?
        switch flow {
        case .charging:
            batteryWatts = readChargingBatteryWatts(from: properties)
        case .discharging:
            batteryWatts = batteryDischargeWatts.map { -abs($0) }
        case .idle:
            batteryWatts = 0
        case .unknown:
            batteryWatts = nil
        }

        return PowerTelemetry(
            isCharging: resolvedIsCharging,
            isOnACPower: registryIsOnACPower,
            systemLoadWatts: systemLoadWatts,
            externalInputWatts: externalInputWatts,
            batteryWatts: batteryWatts
        )
    }

    private static func readChargingBatteryWatts(from properties: [String: Any]) -> Double? {
        guard let charger = properties["ChargerData"] as? [String: Any],
              let voltage = (properties["Voltage"] as? NSNumber)?.int64Value,
              let currentNumber = charger["ChargingCurrent"] as? NSNumber,
              voltage > 0 else {
            return nil
        }
        let current = normalizedSignedMilliamps(currentNumber.int64Value)
        guard current >= 0 else { return nil }
        return LidAwakePolicy.batteryWatts(
            voltageMillivolts: voltage,
            currentMilliamps: current
        )
    }

    private static func normalizedSignedMilliamps(_ rawValue: Int64) -> Int64 {
        if rawValue > Int64(Int16.max), rawValue <= Int64(UInt16.max) {
            return Int64(Int16(bitPattern: UInt16(rawValue)))
        }
        return rawValue
    }

}

enum BatteryTextFormatter {
    static func estimate(for snapshot: BatterySnapshot, chargeLimit: Int?) -> String {
        let target = min(max(chargeLimit ?? 100, 1), 100)

        if snapshot.isOnACPower && target < 100 && snapshot.percentage >= target && !snapshot.isCharging {
            if snapshot.percentage == target {
                return "已充至 \(target)% 上限"
            }
            return "当前 \(snapshot.percentage)% · 上限 \(target)%"
        }
        if snapshot.isCharged || snapshot.percentage >= 100 {
            return target < 100 ? "已充至 \(target)% 上限" : "电池已充满"
        }
        if snapshot.isCharging {
            guard let minutes = BatteryChargeTimeEstimator.minutesToTarget(
                currentPercentage: snapshot.percentage,
                targetPercentage: target,
                systemMinutesToFull: snapshot.timeToFullMinutes
            ) else {
                return "正在估算充至 \(target)% 的时间…"
            }
            if minutes == 0 { return "已充至 \(target)% 上限" }
            return "预计 \(duration(minutes))后充至 \(target)%"
        }
        if !snapshot.isOnACPower {
            guard let minutes = snapshot.timeToEmptyMinutes else { return "正在估算剩余时间…" }
            return "预计还可使用 \(duration(minutes))"
        }
        return "已接通电源，暂未充电"
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        if abs(value) < 0.05 { return "0.0 W" }
        return String(format: "%.1f W", value)
    }

    static func powerTitle(adapterCapacityWatts: Int?) -> String {
        adapterCapacityWatts.map { "电源 \($0)W" } ?? "电源"
    }

    private static func duration(_ totalMinutes: Int) -> String {
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes) 分钟" }
        if minutes == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(minutes) 分钟"
    }
}

enum BatteryMenuBarIcon {
    private static let size = NSSize(width: 27, height: 18)

    // Geometry and state treatment adapted from Stats' MIT-licensed BatteryWidget.
    // See THIRD_PARTY_NOTICES.md and https://github.com/exelban/stats.
    /// Without a badge the icon stays a template image, so the menu bar tints it as before.
    /// A red dot cannot survive that tinting, so the badged icon is drawn in the button's own
    /// appearance instead; `appearance` is read by the caller on every refresh.
    static func make(
        percentage: Int?,
        isCharging: Bool,
        isOnACPower: Bool,
        showsUpdateBadge: Bool = false,
        appearance: NSAppearance? = nil
    ) -> NSImage {
        guard showsUpdateBadge else {
            let image = NSImage(size: size, flipped: false) { _ in
                drawBattery(
                    percentage: percentage,
                    isCharging: isCharging,
                    isOnACPower: isOnACPower,
                    tint: .black
                )
            }
            image.isTemplate = true
            return image
        }

        let image = NSImage(size: size, flipped: false) { _ in
            var drawn = false
            let draw = {
                drawn = drawBattery(
                    percentage: percentage,
                    isCharging: isCharging,
                    isOnACPower: isOnACPower,
                    tint: .labelColor
                )
                guard drawn else { return }
                drawUpdateBadge()
            }
            if let appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return drawn
        }
        image.isTemplate = false
        return image
    }

    /// A filled red dot in the top-right corner, with the artwork behind it cleared so the
    /// dot keeps a visible gap from the battery outline.
    private static func drawUpdateBadge() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let diameter: CGFloat = 6
        let inset: CGFloat = 0.5
        let badgeRect = NSRect(
            x: size.width - diameter - inset,
            y: size.height - diameter - inset,
            width: diameter,
            height: diameter
        )

        context.saveGState()
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1, dy: -1)).fill()
        context.restoreGState()

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
    }

    private static func drawBattery(
        percentage: Int?,
        isCharging: Bool,
        isOnACPower: Bool,
        tint: NSColor
    ) -> Bool {
        guard let context = NSGraphicsContext.current?.cgContext else { return false }

        let batterySize = NSSize(width: 22, height: 12)
        let borderWidth: CGFloat = 1
        let offset: CGFloat = 0.5
        let batteryFrame = NSBezierPath(
            roundedRect: NSRect(
                x: borderWidth + offset,
                y: ((18 - batterySize.height) / 2) + offset,
                width: batterySize.width - borderWidth,
                height: batterySize.height - borderWidth
            ),
            xRadius: 2,
            yRadius: 2
        )

        tint.withAlphaComponent(0.5).setStroke()
        batteryFrame.lineWidth = borderWidth
        batteryFrame.stroke()

        let terminalRect = NSRect(
            x: batteryFrame.bounds.maxX + 1,
            y: batteryFrame.bounds.midY - 2,
            width: 2,
            height: 4
        )
        let terminal = NSBezierPath()
        terminal.move(to: terminalRect.origin)
        terminal.line(to: NSPoint(x: terminalRect.maxX - 1, y: terminalRect.minY))
        terminal.appendArc(
            withCenter: NSPoint(x: terminalRect.maxX - 1, y: terminalRect.minY + 1),
            radius: 1,
            startAngle: -90,
            endAngle: 0
        )
        terminal.line(to: NSPoint(x: terminalRect.maxX, y: terminalRect.maxY - 1))
        terminal.appendArc(
            withCenter: NSPoint(x: terminalRect.maxX - 1, y: terminalRect.maxY - 1),
            radius: 1,
            startAngle: 0,
            endAngle: 90
        )
        terminal.line(to: NSPoint(x: terminalRect.minX, y: terminalRect.maxY))
        terminal.close()
        tint.withAlphaComponent(0.5).setFill()
        terminal.fill()

        if let percentage {
            let clamped = min(max(percentage, 0), 100)
            let fraction = CGFloat(clamped) / 100
            let maxWidth: CGFloat = 18
            let innerRect = NSRect(
                x: batteryFrame.bounds.minX + 1.5,
                y: batteryFrame.bounds.minY + 1.5,
                width: max(1, maxWidth * fraction),
                height: 8
            )

            if !isOnACPower {
                let underlay = NSBezierPath(
                    roundedRect: NSRect(
                        x: innerRect.minX,
                        y: innerRect.minY,
                        width: maxWidth,
                        height: innerRect.height
                    ),
                    xRadius: 1,
                    yRadius: 1
                )
                tint.withAlphaComponent(0.5).setFill()
                underlay.fill()
            }

            tint.setFill()
            NSBezierPath(roundedRect: innerRect, xRadius: 1, yRadius: 1).fill()

            if isOnACPower {
                drawPowerState(
                    in: context,
                    center: NSPoint(x: batteryFrame.bounds.midX, y: batteryFrame.bounds.midY),
                    charging: isCharging,
                    tint: tint
                )
            } else {
                drawPercentage(clamped, in: context, rect: NSRect(
                    x: innerRect.minX,
                    y: 4,
                    width: maxWidth,
                    height: 10
                ))
            }
        } else {
            drawUnknown(in: context, center: NSPoint(
                x: batteryFrame.bounds.midX,
                y: batteryFrame.bounds.midY
            ), tint: tint)
        }

        return true
    }

    private static func drawPercentage(_ percentage: Int, in context: CGContext, rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let value = NSAttributedString(
            string: String(percentage),
            attributes: [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph,
            ]
        )
        context.saveGState()
        context.setBlendMode(.clear)
        value.draw(in: rect)
        context.restoreGState()
    }

    private static func drawUnknown(in context: CGContext, center: NSPoint, tint: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        NSAttributedString(
            string: "?",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: tint,
                .paragraphStyle: paragraph,
            ]
        ).draw(in: NSRect(x: center.x - 4, y: center.y - 6, width: 8, height: 12))
    }

    private static func drawPowerState(
        in context: CGContext,
        center: NSPoint,
        charging: Bool,
        tint: NSColor
    ) {
        let points: [NSPoint]
        if charging {
            let min = NSPoint(x: center.x - 4.5, y: center.y - 9)
            let max = NSPoint(x: center.x + 4.5, y: center.y + 9)
            points = [
                NSPoint(x: center.x - 3, y: min.y),
                NSPoint(x: max.x, y: center.y + 1.5),
                NSPoint(x: center.x + 1, y: center.y + 1.5),
                NSPoint(x: center.x + 3, y: max.y),
                NSPoint(x: min.x, y: center.y - 1.5),
                NSPoint(x: center.x - 1, y: center.y - 1.5),
            ]
        } else {
            let minY = center.y - 7
            let maxY = center.y + 7
            points = [
                NSPoint(x: center.x - 1.5, y: minY + 0.5),
                NSPoint(x: center.x + 1.5, y: minY + 0.5),
                NSPoint(x: center.x + 1.5, y: center.y - 2.5),
                NSPoint(x: center.x + 4, y: center.y + 0.5),
                NSPoint(x: center.x + 4, y: center.y + 4.25),
                NSPoint(x: center.x + 2.75, y: center.y + 4.25),
                NSPoint(x: center.x + 2.75, y: maxY - 0.25),
                NSPoint(x: center.x + 0.25, y: maxY - 0.25),
                NSPoint(x: center.x + 0.25, y: center.y + 4.25),
                NSPoint(x: center.x - 0.25, y: center.y + 4.25),
                NSPoint(x: center.x - 0.25, y: maxY - 0.25),
                NSPoint(x: center.x - 2.75, y: maxY - 0.25),
                NSPoint(x: center.x - 2.75, y: center.y + 4.25),
                NSPoint(x: center.x - 4, y: center.y + 4.25),
                NSPoint(x: center.x - 4, y: center.y + 0.5),
                NSPoint(x: center.x - 1.5, y: center.y - 2.5),
            ]
        }

        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.close()

        tint.setFill()
        path.fill()

        context.saveGState()
        context.setBlendMode(.clear)
        NSColor.black.setStroke()
        path.lineWidth = 1
        path.stroke()
        context.restoreGState()
    }
}

private final class BatteryGaugeView: NSView {
    var percentage = 0 { didSet { needsDisplay = true } }
    var isCharging = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let clamped = min(max(percentage, 0), 100)
        let bodyRect = NSRect(x: 1, y: 3, width: bounds.width - 6, height: bounds.height - 6)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 4, yRadius: 4)
        NSColor.tertiaryLabelColor.setStroke()
        body.lineWidth = 1.5
        body.stroke()

        let terminalRect = NSRect(x: bounds.width - 4, y: bounds.midY - 4, width: 3, height: 8)
        NSBezierPath(roundedRect: terminalRect, xRadius: 1, yRadius: 1).fill()

        let fillColor: NSColor
        if clamped <= 10 {
            fillColor = .systemRed
        } else if isCharging {
            fillColor = .systemGreen
        } else {
            fillColor = .labelColor
        }
        fillColor.setFill()
        let inner = bodyRect.insetBy(dx: 3, dy: 3)
        let fillWidth = inner.width * CGFloat(clamped) / 100
        if fillWidth > 0.5 {
            NSBezierPath(
                roundedRect: NSRect(x: inner.minX, y: inner.minY, width: fillWidth, height: inner.height),
                xRadius: 2,
                yRadius: 2
            ).fill()
        }
    }
}

final class BatterySummaryView: NSView {
    private let gauge = BatteryGaugeView(frame: .zero)
    private let percentageLabel = NSTextField(labelWithString: "—")
    private let estimateLabel = NSTextField(labelWithString: "正在读取电池…")
    private let systemTitle = NSTextField(labelWithString: "电脑")
    private let externalTitle = NSTextField(labelWithString: "电源")
    private let batteryTitle = NSTextField(labelWithString: "电池")
    private let systemValue = NSTextField(labelWithString: "—")
    private let externalValue = NSTextField(labelWithString: "—")
    private let batteryValue = NSTextField(labelWithString: "—")
    private let horizontalRule = NSBox()
    private let firstVerticalRule = NSBox()
    private let secondVerticalRule = NSBox()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 278, height: 116))

        gauge.translatesAutoresizingMaskIntoConstraints = false
        percentageLabel.translatesAutoresizingMaskIntoConstraints = false
        estimateLabel.translatesAutoresizingMaskIntoConstraints = false
        let metricLabels = [
            systemTitle,
            externalTitle,
            batteryTitle,
            systemValue,
            externalValue,
            batteryValue,
        ]
        for label in metricLabels {
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        for rule in [horizontalRule, firstVerticalRule, secondVerticalRule] {
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.boxType = .separator
        }

        percentageLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        estimateLabel.font = .systemFont(ofSize: 12, weight: .regular)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.lineBreakMode = .byTruncatingTail
        for title in [systemTitle, externalTitle, batteryTitle] {
            title.font = .systemFont(ofSize: 11, weight: .regular)
            title.textColor = .secondaryLabelColor
        }
        for value in [systemValue, externalValue, batteryValue] {
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        addSubview(gauge)
        addSubview(percentageLabel)
        addSubview(estimateLabel)
        for view in [horizontalRule, firstVerticalRule, secondVerticalRule] {
            addSubview(view)
        }
        for label in metricLabels { addSubview(label) }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 278),
            heightAnchor.constraint(equalToConstant: 116),
            gauge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            gauge.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            gauge.widthAnchor.constraint(equalToConstant: 42),
            gauge.heightAnchor.constraint(equalToConstant: 24),
            percentageLabel.leadingAnchor.constraint(equalTo: gauge.trailingAnchor, constant: 12),
            percentageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            percentageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            estimateLabel.leadingAnchor.constraint(equalTo: percentageLabel.leadingAnchor),
            estimateLabel.topAnchor.constraint(equalTo: percentageLabel.bottomAnchor, constant: 1),
            estimateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            horizontalRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            horizontalRule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            horizontalRule.topAnchor.constraint(equalTo: topAnchor, constant: 66),
            horizontalRule.heightAnchor.constraint(equalToConstant: 1),
            externalTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            externalTitle.topAnchor.constraint(equalTo: horizontalRule.bottomAnchor, constant: 8),
            systemTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 104),
            systemTitle.topAnchor.constraint(equalTo: externalTitle.topAnchor),
            batteryTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 194),
            batteryTitle.topAnchor.constraint(equalTo: externalTitle.topAnchor),
            externalValue.leadingAnchor.constraint(equalTo: externalTitle.leadingAnchor),
            externalValue.topAnchor.constraint(equalTo: externalTitle.bottomAnchor, constant: 2),
            systemValue.leadingAnchor.constraint(equalTo: systemTitle.leadingAnchor),
            systemValue.topAnchor.constraint(equalTo: systemTitle.bottomAnchor, constant: 2),
            batteryValue.leadingAnchor.constraint(equalTo: batteryTitle.leadingAnchor),
            batteryValue.topAnchor.constraint(equalTo: batteryTitle.bottomAnchor, constant: 2),
            firstVerticalRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 91),
            firstVerticalRule.widthAnchor.constraint(equalToConstant: 1),
            firstVerticalRule.topAnchor.constraint(equalTo: horizontalRule.bottomAnchor, constant: 8),
            firstVerticalRule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            secondVerticalRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 181),
            secondVerticalRule.widthAnchor.constraint(equalToConstant: 1),
            secondVerticalRule.topAnchor.constraint(equalTo: firstVerticalRule.topAnchor),
            secondVerticalRule.bottomAnchor.constraint(equalTo: firstVerticalRule.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(with snapshot: BatterySnapshot?, chargeLimit: Int? = nil) {
        guard let snapshot else {
            gauge.percentage = 0
            gauge.isCharging = false
            percentageLabel.stringValue = "—"
            estimateLabel.stringValue = "正在读取电池…"
            externalTitle.stringValue = "电源"
            systemValue.stringValue = "—"
            externalValue.stringValue = "—"
            batteryValue.stringValue = "—"
            return
        }

        gauge.percentage = snapshot.percentage
        gauge.isCharging = snapshot.isCharging
        percentageLabel.stringValue = "\(snapshot.percentage)%"
        estimateLabel.stringValue = BatteryTextFormatter.estimate(
            for: snapshot,
            chargeLimit: chargeLimit
        )
        externalTitle.stringValue = BatteryTextFormatter.powerTitle(
            adapterCapacityWatts: snapshot.adapterCapacityWatts
        )
        systemValue.stringValue = BatteryTextFormatter.watts(snapshot.systemLoadWatts)
        externalValue.stringValue = BatteryTextFormatter.watts(snapshot.externalInputWatts)
        batteryValue.stringValue = BatteryTextFormatter.watts(snapshot.batteryWatts)
        setAccessibilityLabel(
            "电池 \(snapshot.percentage)%，\(estimateLabel.stringValue)，电源输入 \(externalValue.stringValue)，电脑 \(systemValue.stringValue)，电池 \(batteryValue.stringValue)"
        )
    }
}
