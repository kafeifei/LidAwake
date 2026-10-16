import XCTest
@testable import LidAwakeCore

final class ADI2VolumeCurveTests: XCTestCase {
    private let capped = ADI2VolumeCurve(pressCount: 40, ceilingTenths: -240, bendX: 0.5, bendY: 0.69)

    func testStandardIsTheTunedCurve() {
        let standard = ADI2VolumeCurve.standard
        XCTAssertEqual(standard.pressCount, 25)
        XCTAssertEqual(standard.ceilingTenths, -250)
        XCTAssertEqual(standard.levels(presses: standard.pressCount)[3], -610)
        XCTAssertEqual(standard.stepped(-500, fine: false, up: true), -475)
    }

    func testCurveRunsFromTheMinimumToTheCeiling() {
        for curve in [ADI2VolumeCurve.standard, capped] {
            XCTAssertEqual(curve.decibels(atPosition: 0), -114.5, accuracy: 1e-9)
            XCTAssertEqual(curve.decibels(atPosition: 1), Double(curve.ceilingTenths) / 10, accuracy: 1e-9)
            XCTAssertEqual(curve.position(ADI2Volume.minimumTenths), 0)
            XCTAssertEqual(curve.position(curve.ceilingTenths), 1)
        }
        XCTAssertEqual(capped.position(-100), 1)
        XCTAssertEqual(capped.levels(presses: capped.pressCount).last, -240)
    }

    func testShapePassesThroughTheBendAndNeverDips() {
        for bendX in stride(from: 0.05, through: 0.95, by: 0.15) {
            for bendY in stride(from: 0.05, through: 0.95, by: 0.15) {
                let curve = ADI2VolumeCurve(pressCount: 40, ceilingTenths: 0, bendX: bendX, bendY: bendY)
                XCTAssertEqual(curve.shape(curve.bendX), curve.bendY, accuracy: 1e-12)
                var previous = curve.shape(0)
                XCTAssertEqual(previous, 0, accuracy: 1e-12)
                for index in 1...400 {
                    let value = curve.shape(Double(index) / 400)
                    XCTAssertGreaterThanOrEqual(value, previous - 1e-12, "bend \(bendX), \(bendY)")
                    previous = value
                }
                XCTAssertEqual(previous, 1, accuracy: 1e-12)
            }
        }
    }

    func testPositionRoundTripsEveryHalfDecibel() {
        for curve in [ADI2VolumeCurve.standard, capped] {
            for tenths in stride(from: ADI2Volume.minimumTenths, through: curve.ceilingTenths, by: 5) {
                let decibels = curve.decibels(atPosition: curve.position(tenths))
                XCTAssertEqual(ADI2Volume.snappedToHalfDecibel(decibels), tenths)
            }
        }
    }

    func testStandardStepsGetFinerAsItGetsLouder() {
        let levels = ADI2VolumeCurve.standard.levels(presses: ADI2VolumeCurve.standard.pressCount)
        let steps = zip(levels, levels.dropFirst()).map { $1 - $0 }
        let near = { (tenths: Int) in levels.firstIndex { $0 >= tenths }! }
        XCTAssertGreaterThan(steps[near(-500)], steps[near(-300)])
        XCTAssertGreaterThan(steps[near(-900)], steps[near(-500)])
    }

    func testEveryKeyPressMovesTheLevel() {
        for curve in [ADI2VolumeCurve.standard, capped] {
            for fine in [false, true] {
                for tenths in stride(from: ADI2Volume.minimumTenths, through: curve.ceilingTenths, by: 5) {
                    if tenths < curve.ceilingTenths {
                        let raised = curve.stepped(tenths, fine: fine, up: true)
                        XCTAssertGreaterThan(raised, tenths)
                        XCTAssertLessThanOrEqual(raised, curve.ceilingTenths)
                    }
                    if tenths > ADI2Volume.minimumTenths {
                        XCTAssertLessThan(curve.stepped(tenths, fine: fine, up: false), tenths)
                    }
                }
            }
        }
    }

    func testCeilingStopsRaising() {
        XCTAssertEqual(capped.stepped(-240, fine: false, up: true), -240)
        XCTAssertEqual(capped.stepped(-100, fine: false, up: true), -100)
        XCTAssertLessThan(capped.stepped(-100, fine: false, up: false), -100)
        XCTAssertEqual(capped.stepped(ADI2Volume.minimumTenths, fine: false, up: false), ADI2Volume.minimumTenths)
    }

    func testInitKeepsValuesInRange() {
        let curve = ADI2VolumeCurve(pressCount: 500, ceilingTenths: -2000, bendX: 2, bendY: -1)
        XCTAssertEqual(curve.pressCount, ADI2VolumeCurve.pressCountRange.upperBound)
        XCTAssertEqual(curve.ceilingTenths, ADI2VolumeCurve.ceilingRange.lowerBound)
        XCTAssertEqual(curve.bendX, ADI2VolumeCurve.bendRange.upperBound)
        XCTAssertEqual(curve.bendY, ADI2VolumeCurve.bendRange.lowerBound)
    }
}
