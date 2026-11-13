import XCTest
@testable import LidAwakeApp

// These Objective-C entry points use the same ABI as PowerUI, including autoreleased NSError **.
private final class TestChargeLimitClient: NSObject {
    enum Operation: Int {
        case available = 1, current, set
    }

    static var failingOperation: Operation?
    private var limit: UInt8 = 80

    @objc(initWithClientName:)
    init(clientName: NSString) {
        super.init()
    }

    private func fail(_ operation: Operation, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        guard Self.failingOperation == operation else { return false }
        error?.pointee = NSError(
            domain: "ChargeLimitControllerTests",
            code: operation.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Charge limit unavailable"]
        )
        return true
    }

    @objc(availableChargeLimitsWithError:)
    func availableLimits(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> NSArray? {
        guard !fail(.available, error: error) else { return nil }
        return [80, 85, 90, 95, 100]
    }

    @objc(getMCLLimitWithError:)
    func currentLimit(_ error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> UInt8 {
        fail(.current, error: error) ? 0 : limit
    }

    @objc(setMCLLimit:error:)
    func setLimit(_ value: UInt8, error: AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool {
        guard !fail(.set, error: error) else { return false }
        limit = value
        return true
    }
}

final class ChargeLimitControllerTests: XCTestCase {
    override func tearDown() {
        TestChargeLimitClient.failingOperation = nil
        super.tearDown()
    }

    func testReadsAndSetsChargeLimitThroughRuntimeBridge() throws {
        let controller = try XCTUnwrap(ChargeLimitController(clientClass: TestChargeLimitClient.self))
        XCTAssertEqual(try controller.availableLimits(), [80, 85, 90, 95, 100])
        XCTAssertEqual(try controller.currentLimit(), 80)
        try controller.setLimit(90)
        XCTAssertEqual(try controller.currentLimit(), 90)
    }

    func testUnavailableLimitsErrorSurvivesAutoreleasePool() throws {
        try assertErrorOwnership(.available) { _ = try $0.availableLimits() }
    }

    func testCurrentLimitErrorSurvivesAutoreleasePool() throws {
        try assertErrorOwnership(.current) { _ = try $0.currentLimit() }
    }

    func testSetLimitErrorSurvivesAutoreleasePool() throws {
        try assertErrorOwnership(.set) { try $0.setLimit(90) }
    }

    private func assertErrorOwnership(
        _ operation: TestChargeLimitClient.Operation,
        perform: (ChargeLimitController) throws -> Void
    ) throws {
        TestChargeLimitClient.failingOperation = operation
        let controller = try XCTUnwrap(ChargeLimitController(clientClass: TestChargeLimitClient.self))
        autoreleasepool {
            var caughtError: NSError?
            autoreleasepool {
                do {
                    try perform(controller)
                    XCTFail("Expected the PowerUI error to be propagated")
                } catch ChargeLimitControllerError.system(let error) {
                    caughtError = error
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
            // A strong Swift reference must keep the error alive after Objective-C drains its pool.
            XCTAssertEqual(caughtError?.domain, "ChargeLimitControllerTests")
            XCTAssertEqual(caughtError?.code, operation.rawValue)
            XCTAssertEqual(caughtError?.localizedDescription, "Charge limit unavailable")
        }
    }
}
