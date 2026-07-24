import Foundation
@testable import PatchApplyKit
import XCTest

final class ApplicatorTests: XCTestCase {
    func testApplierAddsNewFile() throws {
        let fileSystem = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.addGreet)
        XCTAssertEqual(fileSystem.string(at: "greet.txt"), "Hello\nWorld\n")
    }

    func testApplierAddsNewFileWithMinimalHunkHeader() throws {
        let fileSystem = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.addGreetMinimalHeader)
        XCTAssertEqual(fileSystem.string(at: "greet-minimal.txt"), "Hello\nWorld\n")
    }

    func testApplierAppliesPatchWithoutFileMarkers() throws {
        let original = [
            "In my toolbox, old and new,",
            "Wrenches whisper what to do.",
            "Hammers sing with rhythmic glee,",
            "Saws hum gentle poetry.",
            "Together, tools build dreams anew."
        ].joined(separator: "\n") + "\n"

        let expected = [
            "In my toolbox, old and new,",
            "Wrenches whisper what to do.",
            "Hammers sing with rhythmic glee,",
            "Beneath the wood, old stories lie,",
            "Shavings curl as time drifts by,",
            "Each tap and turn shapes hopes that grow.",
            "Saws hum gentle poetry.",
            "Together, tools build dreams anew."
        ].joined(separator: "\n") + "\n"

        let fileSystem = InMemoryFileSystem(initialFiles: ["poem.txt": original])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.updatePoemImplicitHeader)
        XCTAssertEqual(fileSystem.string(at: "poem.txt"), expected)
    }

    func testApplierModifiesExistingFile() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.updateHelloWithoutExclamation)
        XCTAssertEqual(fileSystem.string(at: "hello.txt"), "Hello there\nWorld\n")
    }

    func testApplierDeletesFile() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["obsolete.txt": "Goodbye\nWorld\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.deleteObsolete)
        XCTAssertFalse(fileSystem.fileExists(at: "obsolete.txt"))
    }

    func testApplierRenamesAndModifiesFile() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["foo.txt": "foo\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.renameFooToBar)
        XCTAssertFalse(fileSystem.fileExists(at: "foo.txt"))
        XCTAssertEqual(fileSystem.string(at: "bar.txt"), "bar\n")
    }

    func testApplierCopiesFileWithoutModifications() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.copyHello)
        XCTAssertEqual(fileSystem.string(at: "hello.txt"), "Hello\nWorld\n")
        XCTAssertEqual(fileSystem.string(at: "hello-copy.txt"), "Hello\nWorld\n")
    }

    func testApplierCopiesFileWithModifications() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.copyHelloWithWelcome)
        XCTAssertEqual(fileSystem.string(at: "hello.txt"), "Hello\nWorld\n")
        XCTAssertEqual(fileSystem.string(at: "welcome.txt"), "Hello\nWorld\nWelcome!\n")
    }

    func testApplierRejectsContextMismatch() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["hello.txt": "Something else\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.updateHelloWithoutExclamation))
    }

    func testApplierAppliesFileModeChanges() throws {
        let fileSystem = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.addExecutablePatch)
        XCTAssertEqual(fileSystem.permissions(at: "script.sh"), UInt16(0o0755))
        XCTAssertEqual(fileSystem.string(at: "script.sh"), "echo hello\n")
    }

    func testApplierRejectsBinaryPatch() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["Assets/icon.bin": "placeholder\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.unsupportedBinaryModifyPatch)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary patches are not supported"), "Unexpected error message: \(message)")
        }
    }

    func testApplierRejectsBinaryMetadataOnlyPatch() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["image.png": "placeholder\n"])
        let applier = PatchApplier(fileSystem: fileSystem)
        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.unsupportedBinaryCopyPatch)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary patches are not supported"), "Unexpected error message: \(message)")
        }
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

    func testApplierHandlesComplexMultiDirectivePatch() throws {
        let originalFeature = makeOriginalFeatureSource()
        let originalReadme = makeOriginalReadme()
        let expectedFeature = makeExpectedFeatureSource()
        let expectedConfig = makeExpectedConfig()
        let expectedDocsReadme = makeExpectedDocsReadme()

        let fileSystem = InMemoryFileSystem(initialFiles: [
            "Sources/App/FeatureService.swift": originalFeature,
            "README.md": originalReadme
        ])
        let applier = PatchApplier(fileSystem: fileSystem)

        try applier.apply(text: PatchFixtures.complexFeaturePatch)

        let featureContent = try XCTUnwrap(fileSystem.string(at: "Sources/App/FeatureService.swift"))
        XCTAssertEqual(featureContent, expectedFeature)
        XCTAssertFalse(featureContent.hasSuffix("\n"))

        XCTAssertEqual(fileSystem.string(at: "Resources/feature/config.yaml"), expectedConfig)
        XCTAssertEqual(fileSystem.permissions(at: "Resources/feature/config.yaml"), UInt16(0o0644))

        XCTAssertFalse(fileSystem.fileExists(at: "README.md"))

        XCTAssertEqual(fileSystem.string(at: "Docs/README.md"), expectedDocsReadme)
    }

    func testApplierRejectsAmbiguousContextMatch() throws {
        let content = Array(repeating: "beta", count: 6).joined(separator: "\n") + "\n"
        let fileSystem = InMemoryFileSystem(initialFiles: ["repeated.txt": content])
        let applier = PatchApplier(fileSystem: fileSystem)

        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.ambiguousContextPatch)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("ambiguous hunk match"), "Unexpected error message: \(message)")
        }
    }

    func testApplierHandlesLargeAdditionPatch() throws {
        let fileSystem = InMemoryFileSystem()
        let applier = PatchApplier(fileSystem: fileSystem)

        let patch = PatchFixtures.makeLargeAdditionPatch(filename: "big.txt", lineCount: 200)
        try applier.apply(text: patch)

        let contents = try XCTUnwrap(fileSystem.string(at: "big.txt"))
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 201)
        XCTAssertTrue(lines.first?.hasPrefix("line001") ?? false)
        XCTAssertEqual(lines.dropLast().last, "line200")
        XCTAssertEqual(contents.last, "\n")
    }

    func testRenameWithHunksPreservesPermissionsWhenMetadataAbsent() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["foo.txt": "foo\n"])
        try fileSystem.setPOSIXPermissions(UInt16(0o0755), at: "foo.txt")

        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.renameFooToBar)

        XCTAssertFalse(fileSystem.fileExists(at: "foo.txt"))
        XCTAssertEqual(fileSystem.permissions(at: "bar.txt"), UInt16(0o0755))
    }

    func testCopyWithHunksInheritsPermissionsWhenMetadataAbsent() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["hello.txt": "Hello\nWorld\n"])
        try fileSystem.setPOSIXPermissions(UInt16(0o0740), at: "hello.txt")

        let applier = PatchApplier(fileSystem: fileSystem)
        try applier.apply(text: PatchFixtures.copyHelloWithWelcome)

        XCTAssertEqual(fileSystem.permissions(at: "welcome.txt"), UInt16(0o0740))
    }
}

final class CodexPatchInputFormatTests: XCTestCase {
    func testDefaultUnifiedDiffModeRejectsCodexShorthand() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["README.md": "# Old\n"])
        let applier = PatchApplier(fileSystem: fileSystem)

        XCTAssertThrowsError(try applier.apply(text: """
        *** Begin Patch
        *** Delete File: README.md
        *** Add File: README.md
        +# New
        *** End Patch
        """))
        XCTAssertEqual(fileSystem.string(at: "README.md"), "# Old\n")
    }

    func testApplierAppliesCodexPatchFormatAndReportsChangedPaths() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["README.md": "# Old\n"])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        let result = try applier.applyReturningResult(text: """
        *** Begin Patch
        *** Update File: README.md
        --- a/README.md
        +++ b/README.md
        @@ -1,1 +1,2 @@
        -# Old
        +# Fulcrum
        +A typed workflow runtime.
        *** Add File: Docs/quickstart.md
        --- /dev/null
        +++ b/Docs/quickstart.md
        @@ -0,0 +1,1 @@
        +Run swift build.
        *** End Patch
        """)

        XCTAssertEqual(result.changedPaths, ["README.md", "Docs/quickstart.md"])
        XCTAssertEqual(fileSystem.string(at: "README.md"), "# Fulcrum\nA typed workflow runtime.\n")
        XCTAssertEqual(fileSystem.string(at: "Docs/quickstart.md"), "Run swift build.\n")
    }

    func testApplierRepairsMissingCodexHunkPrefixes() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: [
            "README.md": """
            # Fulcrum

            Fulcrum is a typed workflow runtime
            for combining deterministic tools
            with bounded model reasoning.
            """
        ])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
        -# Fulcrum
        -
        -Fulcrum is a typed workflow runtime
        for combining deterministic tools
        with bounded model reasoning.
        +# Fulcrum
        +
        +Fulcrum combines typed workflows, deterministic tools,
        +and bounded model reasoning.
        *** End Patch
        """)

        XCTAssertEqual(fileSystem.string(at: "README.md"), """
        # Fulcrum

        Fulcrum combines typed workflows, deterministic tools,
        and bounded model reasoning.
        """)
    }

    func testApplierExpandsCodexShorthandAddAndDeleteDirectives() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: ["README.md": "# Old\nBody\n"])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        let result = try applier.applyReturningResult(text: """
        *** Begin Patch
        *** Delete File: README.md
        *** Add File: README.md
        +# New
        +Replacement body.
        *** End Patch
        """)

        XCTAssertEqual(result.changedPaths, ["README.md"])
        XCTAssertEqual(fileSystem.string(at: "README.md"), "# New\nReplacement body.\n")
    }

    func testApplierDropsContextOnlyCodexHunks() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: [
            "README.md": """
            # Fulcrum

            Current status
            Old description.

            Running
            Keep this command.
            """
        ])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
         # Fulcrum
        @@
         Current status
        -Old description.
        +Improved description.
        @@
         Running
         Keep this command.
        *** End Patch
        """)

        XCTAssertEqual(fileSystem.string(at: "README.md"), """
        # Fulcrum

        Current status
        Improved description.

        Running
        Keep this command.
        """)
    }

    func testApplierAppliesCodexHunksWithStaleLeadingAndTrailingContext() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: [
            "README.md": """
            # Fulcrum

            Fulcrum is still changing.

            ## Running

            swift build
            """
        ])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
         Old heading
         ## Running

        -swift build
        +swift build
        +swift test
         Old trailing context
        *** End Patch
        """)

        XCTAssertEqual(fileSystem.string(at: "README.md"), """
        # Fulcrum

        Fulcrum is still changing.

        ## Running

        swift build
        swift test
        """)
    }

    func testApplierAppliesCodexReplacementWhenOnlyChangedLinesMatchStaleContext() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: [
            "README.md": """
            # Fulcrum

            Fulcrum is still changing.

            ## Running

            swift build
            """
        ])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
         Stale title
         Stale intro
         Stale paragraph
        -Fulcrum is still changing.
        +Fulcrum is an early-stage Swift CLI for typed model-assisted workflows.
         Stale status
         Stale commands
         Stale footer
        *** End Patch
        """)

        XCTAssertEqual(fileSystem.string(at: "README.md"), """
        # Fulcrum

        Fulcrum is an early-stage Swift CLI for typed model-assisted workflows.

        ## Running

        swift build
        """)
    }

    func testApplierRejectsCodexReplacementWhenStaleContextLeavesAmbiguousChangedLines() throws {
        let original = """
        # Fulcrum

        Repeated sentence.

        ## Details

        Repeated sentence.
        """
        let fileSystem = InMemoryFileSystem(initialFiles: ["README.md": original])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        XCTAssertThrowsError(try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
         Stale title
         Stale intro
         Stale paragraph
        -Repeated sentence.
        +Specific replacement.
         Stale status
         Stale commands
         Stale footer
        *** End Patch
        """))
        XCTAssertEqual(fileSystem.string(at: "README.md"), original)
    }

    func testApplierAppliesCodexInsertionHunkWithOneContextAnchor() throws {
        let fileSystem = InMemoryFileSystem(initialFiles: [
            "README.md": """
            # Fulcrum

            ## Running

            swift build
            """
        ])
        let applier = PatchApplier(inputFormat: .codexApplyPatch, fileSystem: fileSystem)

        try applier.apply(text: """
        *** Begin Patch
        *** Update File: README.md
        @@
         swift build
        +swift test
        *** End Patch
        """)

        XCTAssertEqual(fileSystem.string(at: "README.md"), """
        # Fulcrum

        ## Running

        swift build
        swift test
        """)
    }
}

final class SandboxedFileSystemTests: XCTestCase {
    func testSandboxedFileSystemWritesWithinRoot() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sandbox")
        defer { try? fileManager.removeItem(at: base) }

        let sandboxedFileSystem = SandboxedFileSystem(rootPath: root.path)
        let applier = PatchApplier(fileSystem: sandboxedFileSystem)

        try applier.apply(text: PatchFixtures.addGreet)

        let outputURL = root.appendingPathComponent("greet.txt")
        let contents = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(contents, "Hello\nWorld\n")
    }

    func testSandboxedFileSystemPreventsPathTraversal() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("sandbox")
        let outside = base.appendingPathComponent("escape.txt")
        try? fileManager.removeItem(at: outside)
        defer { try? fileManager.removeItem(at: base) }

        let sandboxedFileSystem = SandboxedFileSystem(rootPath: root.path)
        let applier = PatchApplier(fileSystem: sandboxedFileSystem)

        XCTAssertThrowsError(try applier.apply(text: PatchFixtures.sandboxEscapePatch)) { error in
            guard case let PatchEngineError.ioFailure(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("outside the sandbox"), "Unexpected error message: \(message)")
        }

        XCTAssertFalse(fileManager.fileExists(atPath: outside.path))
    }
}

// MARK: - Test Helpers

private func makeOriginalFeatureSource() -> String {
    return [
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
    ].joined(separator: "\n") + "\n"
}

private func makeExpectedFeatureSource() -> String {
    let httpBodyLine = "        request.httpBody = try? JSONEncoder().encode([\"id\": id, " +
        "\"timestamp\": formatter.string(from: Date())])"

    return [
        "import Foundation",
        "",
        "struct FeatureService {",
        "    let endpoint: URL",
        "    private let formatter: ISO8601DateFormatter",
        "",
        "    func makeRequest(id: String) -> URLRequest {",
        "        var request = URLRequest(url: endpoint.appendingPathComponent(id))",
        #"        request.httpMethod = "POST""#,
        httpBodyLine,
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
    ].joined(separator: "\n")
}

private func makeOriginalReadme() -> String {
    return [
        "# Spatchula",
        "A tiny patch applier.",
        "",
        "Refer to CONTRIBUTING.md for details."
    ].joined(separator: "\n") + "\n"
}

private func makeExpectedDocsReadme() -> String {
    return [
        "# Spatchula Documentation",
        "A tiny patch applier.",
        "",
        "Refer to CONTRIBUTING.md for details.",
        "",
        "Additional examples live in `Docs/examples`."
    ].joined(separator: "\n") + "\n"
}

private func makeExpectedConfig() -> String {
    return [
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
}
