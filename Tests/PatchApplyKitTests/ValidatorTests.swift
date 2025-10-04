import XCTest
@testable import PatchApplyKit

final class ValidatorTests: XCTestCase {
    private let validator = PatchValidator()

    func testValidatorRejectsAdditionWithContext() {
        let header = PatchHunkHeader(oldRange: nil, newRange: PatchLineRange(start: 1, length: 1), sectionHeading: nil)
        let hunk = PatchHunk(header: header, lines: [.context("should-not-appear")])
        let directive = PatchDirective(oldPath: nil, newPath: "file.txt", hunks: [hunk], operation: .add)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan))
    }

    func testValidatorRejectsDuplicateModifyPaths() {
        let header = PatchHunkHeader(oldRange: PatchLineRange(start: 1, length: 1), newRange: PatchLineRange(start: 1, length: 1), sectionHeading: nil)
        let lines: [PatchLine] = [.deletion("old"), .addition("new")]
        let hunk = PatchHunk(header: header, lines: lines)
        let first = PatchDirective(oldPath: "file.txt", newPath: "file.txt", hunks: [hunk], operation: .modify)
        let second = PatchDirective(oldPath: "file.txt", newPath: "file.txt", hunks: [hunk], operation: .modify)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [first, second])
        XCTAssertThrowsError(try validator.validate(plan))
    }

    func testValidatorAllowsRenameWithoutHunks() throws {
        let directive = PatchDirective(oldPath: "old.txt", newPath: "new.txt", hunks: [], operation: .rename)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertNoThrow(try validator.validate(plan))
    }

    func testValidatorAllowsCopyWithoutHunks() throws {
        let directive = PatchDirective(oldPath: "source.txt", newPath: "dest.txt", hunks: [], operation: .copy)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertNoThrow(try validator.validate(plan))
    }

    func testValidatorRejectsRenameMetadataMismatch() {
        let metadata = PatchDirectiveMetadata(
            renameFrom: "src.txt",
            renameTo: "dst.txt",
            rawLines: ["rename from src.txt", "rename to dst.txt"]
        )
        let directive = PatchDirective(
            oldPath: "other.txt",
            newPath: "dst.txt",
            hunks: [],
            operation: .rename,
            metadata: metadata
        )
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan))
    }

    func testValidatorRejectsAddWithOldModeMetadata() {
        let metadata = PatchDirectiveMetadata(
            fileModeChange: PatchFileModeChange(oldMode: "100644", newMode: "100644"),
            rawLines: ["old mode 100644", "new mode 100644"]
        )
        let directive = PatchDirective(
            oldPath: nil,
            newPath: "file.txt",
            hunks: [PatchHunk(header: PatchHunkHeader(oldRange: nil, newRange: PatchLineRange(start: 1, length: 1), sectionHeading: nil), lines: [.addition("content")])],
            operation: .add,
            metadata: metadata
        )
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan))
    }

    func testValidatorAcceptsComplexPlanWithMixedDirectives() throws {
        let tokenizer = PatchTokenizer()
        let parser = PatchParser()
        let tokens = try tokenizer.tokenize(PatchFixtures.complexFeaturePatch)
        let plan = try parser.parse(tokens: tokens)
        XCTAssertNoThrow(try validator.validate(plan))
    }

    func testValidatorRejectsCarriageReturnInAddition() {
        let header = PatchHunkHeader(
            oldRange: PatchLineRange(start: 1, length: 1),
            newRange: PatchLineRange(start: 1, length: 1),
            sectionHeading: nil
        )
        let hunk = PatchHunk(header: header, lines: [.deletion("old"), .addition("new\rvalue")])
        let directive = PatchDirective(oldPath: "file.txt", newPath: "file.txt", hunks: [hunk], operation: .modify)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("Carriage return"))
        }
    }

    func testValidatorRejectsDuplicateRenameDestinations() {
        let first = PatchDirective(oldPath: "a.txt", newPath: "shared.txt", hunks: [], operation: .rename)
        let second = PatchDirective(oldPath: "b.txt", newPath: "shared.txt", hunks: [], operation: .rename)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [first, second])
        XCTAssertThrowsError(try validator.validate(plan)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("duplicate directive touching new path"))
        }
    }

    func testValidatorRejectsSimilarityIndexForModify() {
        let metadata = PatchDirectiveMetadata(
            similarityIndex: 90,
            rawLines: ["similarity index 90%"]
        )
        let header = PatchHunkHeader(
            oldRange: PatchLineRange(start: 1, length: 1),
            newRange: PatchLineRange(start: 1, length: 1),
            sectionHeading: nil
        )
        let hunk = PatchHunk(header: header, lines: [.deletion("old"), .addition("new")])
        let directive = PatchDirective(
            oldPath: "file.txt",
            newPath: "file.txt",
            hunks: [hunk],
            operation: .modify,
            metadata: metadata
        )
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("similarity metadata"))
        }
    }

    func testValidatorRejectsDuplicateNoNewlineMarkers() {
        let header = PatchHunkHeader(
            oldRange: PatchLineRange(start: 1, length: 1),
            newRange: PatchLineRange(start: 1, length: 1),
            sectionHeading: nil
        )
        let hunk = PatchHunk(header: header, lines: [.deletion("old"), .noNewlineMarker, .noNewlineMarker])
        let directive = PatchDirective(oldPath: "file.txt", newPath: nil, hunks: [hunk], operation: .delete)
        let plan = PatchPlan(metadata: PatchMetadata(), directives: [directive])
        XCTAssertThrowsError(try validator.validate(plan)) { error in
            guard case let PatchEngineError.validationFailed(message) = error else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertTrue(message.contains("must terminate the hunk"), "Unexpected error message: \(message)")
        }
    }

    func testValidatorAllowsModifyAfterRenameOfSamePath() throws {
        let rename = PatchDirective(
            oldPath: "foo.txt",
            newPath: "bar.txt",
            hunks: [],
            operation: .rename
        )

        let header = PatchHunkHeader(
            oldRange: PatchLineRange(start: 1, length: 1),
            newRange: PatchLineRange(start: 1, length: 1),
            sectionHeading: nil
        )
        let hunk = PatchHunk(header: header, lines: [.deletion("old"), .addition("new")])
        let modify = PatchDirective(
            oldPath: "bar.txt",
            newPath: "bar.txt",
            hunks: [hunk],
            operation: .modify
        )

        let plan = PatchPlan(metadata: PatchMetadata(), directives: [rename, modify])
        XCTAssertNoThrow(try validator.validate(plan))
    }
}
