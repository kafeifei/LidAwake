import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime

enum ChargeLimitControllerError: LocalizedError {
    case unavailable
    case system(NSError)
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "此 Mac 不支持充电上限"
        case .system(let error):
            return error.localizedDescription
        case .rejected(let value):
            return "系统拒绝将充电上限设为 \(value)%"
        }
    }
}

final class ChargeLimitController {
    private typealias AllocateMethod = @convention(c) (
        AnyObject,
        Selector
    ) -> Unmanaged<AnyObject>
    private typealias InitWithNameMethod = @convention(c) (
        AnyObject,
        Selector,
        AnyObject
    ) -> Unmanaged<AnyObject>
    private typealias UInt8ErrorMethod = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutablePointer<AnyObject?>?
    ) -> UInt8
    private typealias ObjectErrorMethod = @convention(c) (
        AnyObject,
        Selector,
        UnsafeMutablePointer<AnyObject?>?
    ) -> Unmanaged<AnyObject>?
    private typealias SetLimitMethod = @convention(c) (
        AnyObject,
        Selector,
        UInt8,
        UnsafeMutablePointer<AnyObject?>?
    ) -> Bool

    private static let frameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
    private static let minimumSystemVersion = OperatingSystemVersion(
        majorVersion: 26,
        minorVersion: 4,
        patchVersion: 0
    )

    private let clientClass: AnyClass
    private let client: AnyObject

    init?() {
        #if arch(arm64)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minimumSystemVersion) else {
            return nil
        }
        guard dlopen(Self.frameworkPath, RTLD_LAZY) != nil,
              let clientClass = NSClassFromString("PowerUISmartChargeClient"),
              let allocator = class_getClassMethod(clientClass, NSSelectorFromString("alloc")),
              let initializer = class_getInstanceMethod(
                clientClass,
                NSSelectorFromString("initWithClientName:")
              ),
              Self.hasTypeEncoding(allocator, "@16@0:8"),
              Self.hasTypeEncoding(initializer, "@24@0:8@16") else {
            return nil
        }

        let allocate = unsafeBitCast(
            method_getImplementation(allocator),
            to: AllocateMethod.self
        )
        let initialize = unsafeBitCast(
            method_getImplementation(initializer),
            to: InitWithNameMethod.self
        )
        let allocatedClient = allocate(
            clientClass as AnyObject,
            NSSelectorFromString("alloc")
        ).takeUnretainedValue()
        self.clientClass = clientClass
        self.client = initialize(
            allocatedClient,
            NSSelectorFromString("initWithClientName:"),
            "com.kafeifei.LidAwake" as NSString
        ).takeRetainedValue()
        #else
        return nil
        #endif
    }

    func availableLimits() throws -> [Int] {
        let selector = NSSelectorFromString("availableChargeLimitsWithError:")
        let implementation: ObjectErrorMethod = try method(
            selector,
            encoding: "@24@0:8^@16",
            as: ObjectErrorMethod.self
        )
        var errorObject: AnyObject?
        let object = implementation(client, selector, &errorObject)?.takeUnretainedValue()
        try throwIfNeeded(errorObject)
        guard let values = object as? [NSNumber], !values.isEmpty else {
            throw ChargeLimitControllerError.unavailable
        }
        return values.map(\.intValue).sorted()
    }

    func currentLimit() throws -> Int {
        let selector = NSSelectorFromString("getMCLLimitWithError:")
        let implementation: UInt8ErrorMethod = try method(
            selector,
            encoding: "C24@0:8^@16",
            as: UInt8ErrorMethod.self
        )
        var errorObject: AnyObject?
        let value = implementation(client, selector, &errorObject)
        try throwIfNeeded(errorObject)
        guard value > 0 else { throw ChargeLimitControllerError.unavailable }
        return Int(value)
    }

    func setLimit(_ value: Int) throws {
        let available = try availableLimits()
        guard available.contains(value), let limit = UInt8(exactly: value) else {
            throw ChargeLimitControllerError.rejected(value)
        }

        let selector = NSSelectorFromString("setMCLLimit:error:")
        let implementation: SetLimitMethod = try method(
            selector,
            encoding: "B28@0:8C16^@20",
            as: SetLimitMethod.self
        )
        var errorObject: AnyObject?
        let succeeded = implementation(client, selector, limit, &errorObject)
        try throwIfNeeded(errorObject)
        guard succeeded else { throw ChargeLimitControllerError.rejected(value) }

        let verified = try currentLimit()
        guard verified == value else { throw ChargeLimitControllerError.rejected(value) }
    }

    private func method<T>(_ selector: Selector, encoding: String, as type: T.Type) throws -> T {
        guard let method = class_getInstanceMethod(clientClass, selector),
              Self.hasTypeEncoding(method, encoding) else {
            throw ChargeLimitControllerError.unavailable
        }
        return unsafeBitCast(method_getImplementation(method), to: type)
    }

    private static func hasTypeEncoding(_ method: Method, _ expected: String) -> Bool {
        guard let encoding = method_getTypeEncoding(method) else { return false }
        return String(cString: encoding) == expected
    }

    private func throwIfNeeded(_ object: AnyObject?) throws {
        if let error = object as? NSError {
            throw ChargeLimitControllerError.system(error)
        }
    }
}

final class ChargeLimitView: NSView {
    private let controller: ChargeLimitController
    private let titleLabel = NSTextField(labelWithString: "充电上限")
    private let descriptionLabel = NSTextField(labelWithString: "正在读取系统设置…")
    private let slider = NSSlider(value: 100, minValue: 80, maxValue: 100, target: nil, action: nil)
    private var valueLabels: [NSTextField] = []
    private var lastConfirmedLimit: Int?
    var onLimitChanged: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    init(controller: ChargeLimitController) {
        self.controller = controller
        super.init(frame: NSRect(x: 0, y: 0, width: 278, height: 68))

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        descriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.lineBreakMode = .byWordWrapping
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.cell?.wraps = true
        descriptionLabel.cell?.isScrollable = false

        slider.target = self
        slider.action = #selector(commitLimit)
        slider.isContinuous = false
        slider.allowsTickMarkValuesOnly = true
        slider.numberOfTickMarks = 5
        slider.tickMarkPosition = .below
        slider.setAccessibilityLabel("充电上限")

        addSubview(titleLabel)
        addSubview(descriptionLabel)
        addSubview(slider)

        for value in stride(from: 80, through: 100, by: 5) {
            let label = NSTextField(labelWithString: "\(value)%")
            label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            valueLabels.append(label)
            addSubview(label)
        }

        refresh()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 14, y: 10, width: 84, height: 17)
        descriptionLabel.frame = NSRect(x: 14, y: 29, width: 92, height: 28)
        slider.frame = NSRect(x: 108, y: 8, width: 156, height: 28)

        let labelWidth: CGFloat = 34
        let knobWidth = (slider.cell as? NSSliderCell)?.knobThickness ?? 20
        let tickStart = slider.frame.minX + knobWidth / 2
        let tickWidth = slider.frame.width - knobWidth
        for (index, label) in valueLabels.enumerated() {
            let center = tickStart + tickWidth * CGFloat(index) / CGFloat(valueLabels.count - 1)
            label.frame = NSRect(x: center - labelWidth / 2, y: 40, width: labelWidth, height: 13)
        }
    }

    func refresh() {
        do {
            let limits = try controller.availableLimits()
            guard limits == [80, 85, 90, 95, 100] else {
                throw ChargeLimitControllerError.unavailable
            }
            let limit = try controller.currentLimit()
            lastConfirmedLimit = limit
            slider.doubleValue = Double(limit)
            slider.isEnabled = true
            updateDescription(limit: limit)
            onLimitChanged?(limit)
        } catch {
            slider.isEnabled = false
            descriptionLabel.stringValue = error.localizedDescription
            descriptionLabel.toolTip = error.localizedDescription
        }
    }

    @objc private func commitLimit() {
        let requested = Int(slider.doubleValue.rounded() / 5) * 5
        slider.isEnabled = false
        descriptionLabel.stringValue = "正在设置为 \(requested)%…"

        do {
            try controller.setLimit(requested)
            lastConfirmedLimit = requested
            slider.doubleValue = Double(requested)
            updateDescription(limit: requested)
            onLimitChanged?(requested)
        } catch {
            if let lastConfirmedLimit {
                slider.doubleValue = Double(lastConfirmedLimit)
            }
            descriptionLabel.stringValue = "设置失败"
            descriptionLabel.toolTip = error.localizedDescription
        }
        slider.isEnabled = true
    }

    private func updateDescription(limit: Int) {
        descriptionLabel.stringValue = "Mac 将充电至 \(limit)% 上限。"
        descriptionLabel.toolTip = descriptionLabel.stringValue
        slider.setAccessibilityValue("\(limit)%")
    }
}
