import Foundation
import XCTest
@testable import ForgeCore

final class PathPolicyTests: XCTestCase {
    func testAcceptsOrdinaryPayloadFileName() throws {
        XCTAssertEqual(try PathPolicy.validateFileName("GameBoost.dylib"), "GameBoost.dylib")
        XCTAssertEqual(try PathPolicy.validateFileName("Example.framework"), "Example.framework")
    }

    func testRejectsUnsafePayloadFileNames() {
        for name in ["", ".", "..", "../GameBoost.dylib", "Folder/GameBoost.dylib", "A\\B", "A:B"] {
            XCTAssertThrowsError(try PathPolicy.validateFileName(name), "Expected rejection for \(name)")
        }
    }

    func testOrdinaryPayloadNameCreatesADirectChildURL() throws {
        let directory = URL(fileURLWithPath: "/tmp/IPAPayloadLab/Frameworks", isDirectory: true)
            .standardizedFileURL
        let destination = directory.appendingPathComponent(
            try PathPolicy.validateFileName("GameBoost.dylib"),
            isDirectory: false
        )

        XCTAssertEqual(
            destination.deletingLastPathComponent().standardizedFileURL.pathComponents,
            directory.pathComponents
        )
    }

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
