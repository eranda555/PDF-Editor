import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testScannerHasCameraPermissionDescription() {
    let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
    XCTAssertFalse(description?.isEmpty ?? true)
  }

  func testVaultHasFaceIDPermissionDescription() {
    let description = Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") as? String
    XCTAssertFalse(description?.isEmpty ?? true)
  }

}
