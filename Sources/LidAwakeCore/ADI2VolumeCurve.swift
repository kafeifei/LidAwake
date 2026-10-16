import Foundation

/// How the volume keys, the slider and the HUD bar spread the ADI-2's range, as the user drew it.
///
/// The curve runs from the unit's minimum at press 0 to `ceilingTenths` at press `pressCount`.
/// In between it passes smoothly through the bend point, given as fractions of the press count
/// and of the dB range, so a steep stretch means big steps there and a flat one fine steps. The
/// bar and slider position is the press count fraction, so every press moves the bar equally.
public struct ADI2VolumeCurve: Equatable, Sendable {
    public static let pressCountRange = 16...96
    /// The ceiling can be dragged from -60 dB up to the unit's maximum.
    public static let ceilingRange = -600...ADI2Volume.maximumTenths
    /// The bend stays clear of the ends so the curve keeps rising everywhere.
    public static let bendRange = 0.05...0.95

    /// 25 presses up to -25 dB: three presses skip the inaudible bottom to about -61 dB, then
    /// about 3 dB per press around -50 dB, 2 dB around -35 dB and 1 dB or less near the top.
    public static let standard = ADI2VolumeCurve(
        pressCount: 25,
        ceilingTenths: -250,
        bendX: 0.118,
        bendY: 0.596
    )

    public var pressCount: Int
    public var ceilingTenths: Int
    public var bendX: Double
    public var bendY: Double

    public init(pressCount: Int, ceilingTenths: Int, bendX: Double, bendY: Double) {
        self.pressCount = min(max(pressCount, Self.pressCountRange.lowerBound), Self.pressCountRange.upperBound)
        self.ceilingTenths = min(max(ceilingTenths, Self.ceilingRange.lowerBound), Self.ceilingRange.upperBound)
        self.bendX = min(max(bendX, Self.bendRange.lowerBound), Self.bendRange.upperBound)
        self.bendY = min(max(bendY, Self.bendRange.lowerBound), Self.bendRange.upperBound)
    }

    /// ⌥⇧ moves a quarter of a press.
    public var finePressCount: Int { pressCount * 4 }

    /// The level at a bar or slider position from 0 to 1, in dB.
    public func decibels(atPosition position: Double) -> Double {
        let low = Double(ADI2Volume.minimumTenths) / 10
        let high = Double(ceilingTenths) / 10
        return low + shape(min(max(position, 0), 1)) * (high - low)
    }

    /// Where a level sits on the bar and the slider, the inverse of `decibels(atPosition:)`.
    /// Levels above the ceiling show a full bar.
    public func position(_ tenths: Int) -> Double {
        let tenths = ADI2Volume.clamped(tenths)
        if tenths >= ceilingTenths { return 1 }
        if tenths <= ADI2Volume.minimumTenths { return 0 }
        let target = Double(tenths) / 10
        var lower = 0.0
        var upper = 1.0
        for _ in 0..<48 {
            let middle = (lower + upper) / 2
            if decibels(atPosition: middle) < target {
                lower = middle
            } else {
                upper = middle
            }
        }
        return (lower + upper) / 2
    }

    /// The level each press lands on, from the minimum up to the ceiling, on the knob's 0.5 dB.
    /// Neighbouring presses that round to the same level are kept, so the array has
    /// `presses + 1` entries and index n is press n.
    public func levels(presses: Int) -> [Int] {
        (0...presses).map {
            min(ADI2Volume.snappedToHalfDecibel(decibels(atPosition: Double($0) / Double(presses))), ceilingTenths)
        }
    }

    /// Moves to the next press level in the key's direction, the way macOS lands every press on
    /// its step grid, so a level reached by fine steps or the knob rejoins the grid. A press always
    /// changes the level unless it is at the end already; raising stops at the ceiling, and a level
    /// the knob put above the ceiling is never raised further.
    public func stepped(_ tenths: Int, fine: Bool, up: Bool) -> Int {
        let current = ADI2Volume.clamped(tenths)
        let levels = levels(presses: fine ? finePressCount : pressCount)
        if up {
            guard current < ceilingTenths else { return current }
            return levels.first { $0 > current } ?? ceilingTenths
        }
        return levels.last { $0 < current } ?? ADI2Volume.minimumTenths
    }

    /// The curve in fractions, through (0, 0), the bend and (1, 1): a monotone cubic Hermite
    /// spline (Fritsch–Carlson), so it is smooth and never dips however the bend is dragged.
    public func shape(_ x: Double) -> Double {
        let h0 = bendX
        let h1 = 1 - bendX
        let d0 = bendY / h0
        let d1 = (1 - bendY) / h1
        let middle = 3 / ((2 * h1 + h0) / d0 + (h1 + 2 * h0) / d1)
        let start = Self.endTangent(near: d0, far: d1, nearWidth: h0, farWidth: h1)
        let end = Self.endTangent(near: d1, far: d0, nearWidth: h1, farWidth: h0)
        if x <= bendX {
            return Self.hermite(x / h0, y0: 0, y1: bendY, m0: start * h0, m1: middle * h0)
        }
        return Self.hermite((x - bendX) / h1, y0: bendY, y1: 1, m0: middle * h1, m1: end * h1)
    }

    private static func endTangent(near: Double, far: Double, nearWidth: Double, farWidth: Double) -> Double {
        let tangent = ((2 * nearWidth + farWidth) * near - nearWidth * far) / (nearWidth + farWidth)
        return min(max(tangent, 0), 3 * near)
    }

    private static func hermite(_ t: Double, y0: Double, y1: Double, m0: Double, m1: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * y0 + (t3 - 2 * t2 + t) * m0 + (-2 * t3 + 3 * t2) * y1 + (t3 - t2) * m1
    }
}
