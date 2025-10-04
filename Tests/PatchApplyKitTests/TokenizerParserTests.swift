import XCTest
import Foundation
@testable import PatchApplyKit

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

    func testParserMarksBinaryMetadata() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.binaryCopyPatch)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        XCTAssertTrue(directive.metadata.isBinary)
        XCTAssertTrue(directive.hunks.isEmpty)
    }

    func testParserCapturesBinaryPatchBlocks() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.binaryModifyPatch)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        let binary = try XCTUnwrap(directive.binaryPatch)
        XCTAssertEqual(binary.blocks.count, 2)
        XCTAssertEqual(binary.newBlock?.expectedSize, 4)
        XCTAssertEqual(binary.oldBlock?.expectedSize, 3)
        XCTAssertEqual(binary.newData, Data([0xFF, 0x00, 0xAA, 0x55]))
        XCTAssertEqual(binary.oldData, Data([0x01, 0x02, 0x03]))
        XCTAssertTrue(directive.metadata.isBinary)
        XCTAssertTrue(directive.hunks.isEmpty)
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
        XCTAssertEqual(modification.metadata.index, PatchIndexLine(oldHash: "6b7f123", newHash: "9d0a456", mode: "100644"))
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

    func testParserCapturesBinaryDeltaBlocks() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.binaryDeltaPatch)
        let plan = try parser.parse(tokens: tokens)
        let directive = try XCTUnwrap(plan.directives.first)
        let binary = try XCTUnwrap(directive.binaryPatch)
        XCTAssertEqual(binary.blocks.map { $0.kind }, [.delta, .literal])
        XCTAssertEqual(binary.newBlock?.data, Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(binary.oldBlock?.data, Data([0x01, 0x02, 0x03]))
    }

    func testParserRejectsBinaryPatchWithMissingPayload() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.binaryMissingPayloadPatch)
        XCTAssertThrowsError(try parser.parse(tokens: tokens)) { error in
            guard case let PatchEngineError.malformed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("binary block"), "Unexpected error message: \(message)")
        }
    }

    func testParserRejectsBinaryPatchWithInvalidBase64() throws {
        let tokens = try tokenizer.tokenize(PatchFixtures.binaryMalformedPatch)
        XCTAssertThrowsError(try parser.parse(tokens: tokens)) { error in
            guard case let PatchEngineError.malformed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("base64"), "Unexpected error message: \(message)")
        }
    }
}
