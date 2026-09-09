/// 验证 Trae CN 原生 IDE bundle 路径识别（包括带空格的 bundle 路径）。
import XCTest
@testable import CodeIsland

final class TraeCNIDEBundleTests: XCTestCase {
    func testRecognisesTraeCNBundleWithSpaces() {
        XCTAssertTrue(AppState.isTraeCNIDEBundlePath(
            "/Applications/Trae CN.app/Contents/MacOS/Trae CN"))
        XCTAssertTrue(AppState.isTraeCNIDEBundlePath(
            "/Applications/Trae CN.app/Contents/Frameworks/Trae CN Helper.app/Contents/MacOS/Trae CN Helper"))
    }

    func testStillRecognisesPreviousTraeCNBundleNames() {
        XCTAssertTrue(AppState.isTraeCNIDEBundlePath(
            "/Applications/Trae.app/Contents/MacOS/Trae"))
        XCTAssertTrue(AppState.isTraeCNIDEBundlePath(
            "/Applications/TraeCN.app/Contents/MacOS/TraeCN"))
    }

    func testDoesNotMatchStandaloneTraeCli() {
        XCTAssertFalse(AppState.isTraeCNIDEBundlePath(
            "/Users/me/.local/bin/trae"))
    }
}
