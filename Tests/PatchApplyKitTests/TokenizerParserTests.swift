import Foundation
@testable import PatchApplyKit
import XCTest

final class TokenizerParserTests: XCTestCase {
    private let tokenizer = PatchTokenizer()
    private let parser = PatchParser()

    func testTokenizerClassifiesCorePatchElements() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.updateHello)
        XCTAssertEqual(tokens, [
            .beginMarker,
            .header("*** Update File: hello.txt"),
            .fileOld("a/hello.txt"),
            .fileNew("b/hello.txt"),
            .hunkHeader("@@ -1,2 +1,3 @@"),
            .hunkLine("-Hello"),
            .hunkLine("+Hello there"),
            .hunkLine(" World"),
            .hunkLine("+!"),
            .endMarker
        ])
    }

    func testParserBuildsDirectiveStructure() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.updateHello)
        let plan = try parser.parse(tokens: tokens)
        XCTAssertEqual(plan.metadata.title, "*** Update File: hello.txt")
        XCTAssertEqual(plan.directives.count, 1)

        let directive = try XCTUnwrap(plan.directives.first)
        XCTAssertEqual(directive.operation, .modify)
        XCTAssertEqual(directive.oldPath, "hello.txt")
        XCTAssertEqual(directive.newPath, "hello.txt")
        XCTAssertEqual(directive.header, "*** Update File: hello.txt")
        XCTAssertEqual(directive.hunks.count, 1)

        let hunk = try XCTUnwrap(directive.hunks.first)
        XCTAssertEqual(hunk.header.oldRange, PatchLineRange(start: 1, length: 2))
        XCTAssertEqual(hunk.header.newRange, PatchLineRange(start: 1, length: 3))
        XCTAssertNil(hunk.header.sectionHeading)
        XCTAssertEqual(hunk.lines, [
            .deletion("Hello"),
            .addition("Hello there"),
            .context("World"),
            .addition("!")
        ])
    }

    func testParserAcceptsMinimalAddHunkHeader() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.addGreetMinimalHeader)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        XCTAssertEqual(directive.operation, .add)
        XCTAssertNil(directive.oldPath)
        XCTAssertEqual(directive.newPath, "greet-minimal.txt")
        let hunk = try XCTUnwrap(directive.hunks.first)
        XCTAssertNil(hunk.header.oldRange)
        XCTAssertNil(hunk.header.newRange)
        XCTAssertEqual(hunk.lines, [
            .addition("Hello"),
            .addition("World")
        ])
    }

    func testParserDerivesPathsFromHeaderWhenFileMarkersMissing() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.updatePoemImplicitHeader)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        XCTAssertEqual(directive.operation, .modify)
        XCTAssertEqual(directive.oldPath, "poem.txt")
        XCTAssertEqual(directive.newPath, "poem.txt")
        let hunk = try XCTUnwrap(directive.hunks.first)
        XCTAssertEqual(hunk.header.oldRange, PatchLineRange(start: 2, length: 4))
        XCTAssertEqual(hunk.header.newRange, PatchLineRange(start: 2, length: 7))
        XCTAssertEqual(hunk.lines, [
            .context("Wrenches whisper what to do."),
            .context("Hammers sing with rhythmic glee,"),
            .addition("Beneath the wood, old stories lie,"),
            .addition("Shavings curl as time drifts by,"),
            .addition("Each tap and turn shapes hopes that grow."),
            .context("Saws hum gentle poetry."),
            .context("Together, tools build dreams anew.")
        ])
    }

    func testParserRejectsMissingMarkers() {
        XCTAssertThrowsError(try parser.parse(tokens: [.other("--- a/file"), .endMarker]))
    }

    func testTokenizerCapturesMetadataLines() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.updateHelloWithMetadata)
        XCTAssertTrue(tokens.contains(.metadata("index a1b2c3d..d4e5f6a 100644")))
        XCTAssertTrue(tokens.contains(.metadata("old mode 100644")))
        XCTAssertTrue(tokens.contains(.metadata("similarity index 90%")))
    }

    func testParserCapturesDirectiveMetadata() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.updateHelloWithMetadata)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        let metadata = directive.metadata
        XCTAssertEqual(metadata.rawLines.count, 4)
        XCTAssertEqual(metadata.index, PatchIndexLine(oldHash: "a1b2c3d", newHash: "d4e5f6a", mode: "100644"))
        XCTAssertEqual(metadata.fileModeChange, PatchFileModeChange(oldMode: "100644", newMode: "100755"))
        XCTAssertEqual(metadata.similarityIndex, 90)
        XCTAssertNil(metadata.dissimilarityIndex)
    }

    func testParserHandlesComplexPatchWithMultipleDirectives() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.complexFeaturePatch)
        let plan = try parser.parse(tokens: tokens)
        XCTAssertEqual(plan.directives.count, 3)

        let modification = plan.directives[0]
        XCTAssertEqual(modification.operation, PatchOperation.modify)
        XCTAssertEqual(modification.oldPath, "Sources/App/FeatureService.swift")
        XCTAssertEqual(modification.newPath, "Sources/App/FeatureService.swift")
        XCTAssertEqual(modification.hunks.count, 1)
        let expectedIndex = PatchIndexLine(oldHash: "6b7f123", newHash: "9d0a456", mode: "100644")
        XCTAssertEqual(modification.metadata.index, expectedIndex)
        let modificationHunk = try XCTUnwrap(modification.hunks.last)
        XCTAssertEqual(modificationHunk.lines.last, PatchLine.noNewlineMarker)

        let addition = plan.directives[1]
        XCTAssertEqual(addition.operation, PatchOperation.add)
        XCTAssertNil(addition.oldPath)
        XCTAssertEqual(addition.newPath, "Resources/feature/config.yaml")
        XCTAssertEqual(addition.metadata.fileModeChange, PatchFileModeChange(oldMode: nil, newMode: "100644"))
        XCTAssertEqual(addition.hunks.first?.lines.count, 9)

        let rename = plan.directives[2]
        XCTAssertEqual(rename.operation, PatchOperation.rename)
        XCTAssertEqual(rename.oldPath, "README.md")
        XCTAssertEqual(rename.newPath, "Docs/README.md")
        XCTAssertEqual(rename.metadata.similarityIndex, 88)
        XCTAssertEqual(rename.metadata.renameFrom, "README.md")
        XCTAssertEqual(rename.metadata.renameTo, "Docs/README.md")
        XCTAssertEqual(rename.hunks.count, 1)
    }

    func testParserRejectsBinaryMetadata() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.unsupportedBinaryCopyPatch)
        XCTAssertThrowsError(try parser.parse(tokens: tokens)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary patches are not supported"), "Unexpected error message: \(message)")
        }
    }

    func testParserRejectsBinaryPatchBlocks() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.unsupportedBinaryModifyPatch)
        XCTAssertThrowsError(try parser.parse(tokens: tokens)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary patches are not supported"), "Unexpected error message: \(message)")
        }
    }
}
