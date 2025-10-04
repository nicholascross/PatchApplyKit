import XCTest
import Foundation
@testable import PatchApplyKit

final class ApplicatorTests: XCTestCase {
    func testApplierAddsNewFile() throws {
        let fs = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.addGreet)
        XCTAssertEqual(fs.string(at: "greet.txt"), "Hello\nWorld\n")
    }

    func testApplierModifiesExistingFile() throws {
        let fs = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.updateHelloWithoutExclamation)
        XCTAssertEqual(fs.string(at: "hello.txt"), "Hello there\nWorld\n")
    }

    func testApplierDeletesFile() throws {
        let fs = InMemoryFileSystem(initialFiles: ["obsolete.txt": "Goodbye\nWorld\n"])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.deleteObsolete)
        XCTAssertFalse(fs.fileExists(at: "obsolete.txt"))
    }

    func testApplierRenamesAndModifiesFile() throws {
        let fs = InMemoryFileSystem(initialFiles: ["foo.txt": "foo\n"])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.renameFooToBar)
        XCTAssertFalse(fs.fileExists(at: "foo.txt"))
        XCTAssertEqual(fs.string(at: "bar.txt"), "bar\n")
    }

    func testApplierCopiesFileWithoutModifications() throws {
        let fs = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.copyHello)
        XCTAssertEqual(fs.string(at: "hello.txt"), "Hello\nWorld\n")
        XCTAssertEqual(fs.string(at: "hello-copy.txt"), "Hello\nWorld\n")
    }

    func testApplierCopiesFileWithModifications() throws {
        let fs = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.copyHelloWithWelcome)
        XCTAssertEqual(fs.string(at: "hello.txt"), "Hello\nWorld\n")
        XCTAssertEqual(fs.string(at: "welcome.txt"), "Hello\nWorld\nWelcome!\n")
    }

    func testApplierRejectsContextMismatch() throws {
        let fs = InMemoryFileSystem(initialFiles: ["hello.txt": "Something else\n"])
        let applier = PatchApplier(fileSystem: fs)
        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.updateHelloWithoutExclamation))
    }

    func testApplierAppliesFileModeChanges() throws {
        let fs = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.addExecutablePatch)
        XCTAssertEqual(fs.permissions(at: "script.sh"), UInt16(0o0755))
        XCTAssertEqual(fs.string(at: "script.sh"), "echo hello\n")
    }

    func testApplierAddsBinaryFile() throws {
        let fs = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.binaryAddPatch)
        XCTAssertEqual(fs.data(at: "Assets/icon.bin"), Data([0xFF, 0x00, 0xAA, 0x55]))
        XCTAssertEqual(fs.permissions(at: "Assets/icon.bin"), UInt16(0o0644))
    }

    func testApplierModifiesBinaryFile() throws {
        let original = Data([0x01, 0x02, 0x03])
        let fs = InMemoryFileSystem(initialBinaryFiles: ["Assets/icon.bin": original])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.binaryModifyPatch)
        XCTAssertEqual(fs.data(at: "Assets/icon.bin"), Data([0xFF, 0x00, 0xAA, 0x55]))
    }

    func testApplierRejectsBinaryMismatch() throws {
        let fs = InMemoryFileSystem(initialBinaryFiles: ["Assets/icon.bin": Data([0x10, 0x20, 0x30])])
        let applier = PatchApplier(fileSystem: fs)
        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.binaryModifyPatch)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary content mismatch"))
        }
    }

    func testApplierCopiesBinaryFileWithoutPayload() throws {
        let payload = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let fs = InMemoryFileSystem(initialBinaryFiles: ["image.png": payload])
        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.binaryCopyPatch)
        XCTAssertEqual(fs.data(at: "image.png"), payload)
        XCTAssertEqual(fs.data(at: "image-copy.png"), payload)
    }

    func testApplierHonorsWhitespaceTolerance() throws {
        let strictFS = InMemoryFileSystem(initialFiles: ["code.swift": "foo = 1\n"])
        let strictApplier = PatchApplier(fileSystem: strictFS)
        XCTAssertThrowsError(try strictApplier.apply(text: PatchFixtures.whitespaceInsensitivePatch))

        let tolerantFS = InMemoryFileSystem(initialFiles: ["code.swift": "foo = 1\n"])
        let tolerantApplier = PatchApplier(
            fileSystem: tolerantFS,
            configuration: .init(whitespace: .ignoreAll)
        )
        try tolerantApplier.apply(text: PatchFixtures.whitespaceInsensitivePatch)
        XCTAssertEqual(tolerantFS.string(at: "code.swift"), "foo = 2\n")
    }

    func testApplierUsesContextTolerance() throws {
        let original = [
            "line1",
            "line two changed",
            "line3",
            "line four changed",
            "line5"
        ].joined(separator: "\n") + "\n"

        let strictFS = InMemoryFileSystem(initialFiles: ["doc.txt": original])
        let strictApplier = PatchApplier(fileSystem: strictFS)
        XCTAssertThrowsError(try strictApplier.apply(text: PatchFixtures.fuzzyContextPatch))

        let partialFS = InMemoryFileSystem(initialFiles: ["doc.txt": original])
        let partialApplier = PatchApplier(
            fileSystem: partialFS,
            configuration: .init(contextTolerance: 1)
        )
        XCTAssertThrowsError(try partialApplier.apply(text: PatchFixtures.fuzzyContextPatch))

        let fuzzyFS = InMemoryFileSystem(initialFiles: ["doc.txt": original])
        let fuzzyApplier = PatchApplier(
            fileSystem: fuzzyFS,
            configuration: .init(contextTolerance: 2)
        )
        try fuzzyApplier.apply(text: PatchFixtures.fuzzyContextPatch)

        let expected = [
            "line1",
            "line two changed",
            "line 3 updated",
            "line four changed",
            "line5"
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(fuzzyFS.string(at: "doc.txt"), expected)
    }

    func testSandboxedFileSystemWritesWithinRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sandbox")
        defer { try? fm.removeItem(at: base) }

        let sandboxedFS = SandboxedFileSystem(rootPath: root.path)
        let applier = PatchApplier(fileSystem: sandboxedFS)

        try applier.apply(text: PatchFixtures.addGreet)

        let outputURL = root.appendingPathComponent("greet.txt")
        let contents = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(contents, "Hello\nWorld\n")
    }

    func testSandboxedFileSystemPreventsPathTraversal() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sandbox")
        let outside = base.appendingPathComponent("escape.txt")
        try? fm.removeItem(at: outside)
        defer { try? fm.removeItem(at: base) }

        let sandboxedFS = SandboxedFileSystem(rootPath: root.path)
        let applier = PatchApplier(fileSystem: sandboxedFS)

        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.sandboxEscapePatch)) { error in
            guard case let PatchEngineError.ioFailure(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("outside the sandbox"), "Unexpected error message: \(message)")
        }

        XCTAssertFalse(fm.fileExists(atPath: outside.path))
    }

    func testApplierHandlesComplexMultiDirectivePatch() throws {
        let originalFeatureLines = [
            "import Foundation",
            "",
            "struct FeatureService {",
            "    let endpoint: URL",
            "",
            "    func makeRequest(id: String) -> URLRequest {",
            "        var request = URLRequest(url: endpoint.appendingPathComponent(id))",
            #"        request.httpMethod = "GET""#,
            #"        request.addValue("application/json", forHTTPHeaderField: "Accept")"#,
            "        return request",
            "    }",
            "}",
            "",
            "extension FeatureService {",
            "    func headers() -> [String: String] {",
            #"        ["Accept": "application/json"]"#,
            "    }",
            "}"
        ]
        let originalFeature = originalFeatureLines.joined(separator: "\n") + "\n"

        let originalReadmeLines = [
            "# Spatchula",
            "A tiny patch applier.",
            "",
            "Refer to CONTRIBUTING.md for details."
        ]
        let originalReadme = originalReadmeLines.joined(separator: "\n") + "\n"

        let fs = InMemoryFileSystem(initialFiles: [
            "Sources/App/FeatureService.swift": originalFeature,
            "README.md": originalReadme
        ])
        let applier = PatchApplier(fileSystem: fs)

        try applier.apply(text: PatchFixtures.complexFeaturePatch)

        let expectedFeatureLines = [
            "import Foundation",
            "",
            "struct FeatureService {",
            "    let endpoint: URL",
            "    private let formatter: ISO8601DateFormatter",
            "",
            "    func makeRequest(id: String) -> URLRequest {",
            "        var request = URLRequest(url: endpoint.appendingPathComponent(id))",
            #"        request.httpMethod = "POST""#,
            #"        request.httpBody = try? JSONEncoder().encode(["id": id, "timestamp": formatter.string(from: Date())])"#,
            #"        request.addValue("application/json", forHTTPHeaderField: "Accept")"#,
            #"        request.addValue("application/json", forHTTPHeaderField: "Content-Type")"#,
            "        return request",
            "    }",
            "",
            "    func retryDelay() -> TimeInterval {",
            "        0.5",
            "    }",
            "}",
            "",
            "extension FeatureService {",
            "    func headers() -> [String: String] {",
            "        [",
            #"            "Accept": "application/json","#,
            #"            "Content-Type": "application/json""#,
            "        ]",
            "    }",
            "}"
        ]
        let expectedFeature = expectedFeatureLines.joined(separator: "\n")

        let featureContent = try XCTUnwrap(fs.string(at: "Sources/App/FeatureService.swift"))
        XCTAssertEqual(featureContent, expectedFeature)
        XCTAssertFalse(featureContent.hasSuffix("\n"))

        let expectedConfig = [
            "feature:",
            "  enabled: true",
            "  endpoints:",
            #"    - "/v1/feature""#,
            #"    - "/v1/feature/alternate""#,
            "  cache:",
            "    ttl: 15",
            "    strategy: \"background\"",
            "  retries: 3"
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(fs.string(at: "Resources/feature/config.yaml"), expectedConfig)
        XCTAssertEqual(fs.permissions(at: "Resources/feature/config.yaml"), UInt16(0o0644))

        XCTAssertFalse(fs.fileExists(at: "README.md"))

        let expectedDocsReadme = [
            "# Spatchula Documentation",
            "A tiny patch applier.",
            "",
            "Refer to CONTRIBUTING.md for details.",
            "",
            "Additional examples live in `Docs/examples`."
        ].joined(separator: "\n") + "\n"
        XCTAssertEqual(fs.string(at: "Docs/README.md"), expectedDocsReadme)
    }

    func testApplierRejectsAmbiguousContextMatch() throws {
        let content = Array(repeating: "beta", count: 6).joined(separator: "\n") + "\n"
        let fs = InMemoryFileSystem(initialFiles: ["repeated.txt": content])
        let applier = PatchApplier(fileSystem: fs)

        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.ambiguousContextPatch)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("ambiguous hunk match"), "Unexpected error message: \(message)")
        }
    }

    func testApplierHandlesLargeAdditionPatch() throws {
        let fs = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fs)

        let patch = PatchFixtures.makeLargeAdditionPatch(filename: "big.txt", lineCount: 200)
        try applier.apply(text: patch)

        let contents = try XCTUnwrap(fs.string(at: "big.txt"))
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 201)
        XCTAssertTrue(lines.first?.hasPrefix("line001") ?? false)
        XCTAssertEqual(lines.dropLast().last, "line200")
        XCTAssertEqual(contents.last, "\n")
    }

    func testRenameWithHunksPreservesPermissionsWhenMetadataAbsent() throws {
        let fs = InMemoryFileSystem(initialFiles: ["foo.txt": "foo\n"])
        try fs.setPOSIXPermissions(UInt16(0o0755), at: "foo.txt")

        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.renameFooToBar)

        XCTAssertFalse(fs.fileExists(at: "foo.txt"))
        XCTAssertEqual(fs.permissions(at: "bar.txt"), UInt16(0o0755))
    }

    func testCopyWithHunksInheritsPermissionsWhenMetadataAbsent() throws {
        let fs = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        try fs.setPOSIXPermissions(UInt16(0o0740), at: "hello.txt")

        let applier = PatchApplier(fileSystem: fs)
        try applier.apply(text: PatchFixtures.copyHelloWithWelcome)

        XCTAssertEqual(fs.permissions(at: "welcome.txt"), UInt16(0o0740))
    }
}
