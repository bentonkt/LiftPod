import CoreMotion
import XCTest
@testable import LiftPod

final class SensorLocationTests: XCTestCase {
    func testKnownLocationsMapExplicitly() {
        XCTAssertEqual(HeadphoneSensorLocation(rawValue: CMDeviceMotion.SensorLocation.headphoneLeft.rawValue), .leftHeadphone)
        XCTAssertEqual(HeadphoneSensorLocation(rawValue: CMDeviceMotion.SensorLocation.headphoneRight.rawValue), .rightHeadphone)
        XCTAssertEqual(HeadphoneSensorLocation(rawValue: CMDeviceMotion.SensorLocation.default.rawValue), .default)
    }

    func testUnknownLocationPreservesRawValue() {
        XCTAssertEqual(HeadphoneSensorLocation(rawValue: 9_999), .unknown(rawValue: 9_999))
        XCTAssertEqual(HeadphoneSensorLocation(rawValue: 9_999).description, "Unknown (9999)")
    }
}
