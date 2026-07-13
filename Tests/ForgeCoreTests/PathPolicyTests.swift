import XCTest
@testable import ForgeCore

final class PathPolicyTests: XCTestCase {
    func testNormalizesArchivePaths() throws {
        XCTAssertEqual(try PathPolicy.sanitizedArchivePath("./Payload/Test.app/Test"), "Payload/Test.app/Test")
    }

    func testRejectsArchiveTraversalAndAbsolutePaths() {
        XCTAssertThrowsError(try PathPolicy.sanitizedArchivePath("../Payload/Test.app"))
        XCTAssertThrowsError(try PathPolicy.sanitizedArchivePath("/Payload/Test.app"))
        XCTAssertThrowsError(try PathPolicy.sanitizedArchivePath("Payload\\Test.app"))
    }

    func testValidatesLoaderPaths() throws {
        XCTAssertEqual(try PathPolicy.validateLoadPath("@rpath/Test.dylib"), "@rpath/Test.dylib")
        XCTAssertEqual(
            try PathPolicy.validateRPath("@executable_path/Frameworks"),
            "@executable_path/Frameworks"
        )
        XCTAssertThrowsError(try PathPolicy.validateLoadPath("@rpath/../Test.dylib"))
        XCTAssertThrowsError(try PathPolicy.validateLoadPath("/usr/lib/Test.dylib"))
    }

    func testSymlinkTargetsStayRelative() {
        XCTAssertTrue(PathPolicy.safeRelativeSymlinkTarget("Versions/Current"))
        XCTAssertFalse(PathPolicy.safeRelativeSymlinkTarget("../Outside"))
        XCTAssertFalse(PathPolicy.safeRelativeSymlinkTarget("/absolute/path"))
    }
}
