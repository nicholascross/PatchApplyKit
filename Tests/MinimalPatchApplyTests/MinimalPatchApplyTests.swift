@testable import MinimalPatchApply
import XCTest

final class MinimalPatchApplyTests: XCTestCase {
    func testApplyAdd() throws {
        let patch = """
        *** Begin Patch
        --- /dev/null
        +++ test.txt
        @@
        +Line1
        +Line2
        *** End Patch
        """
        var fileSystem = [String: String]()
        let applier = PatchApplier(
            read: { path in
                if let content = fileSystem[path] {
                    return content
                }
                throw PatchError.missing(path)
            },
            write: { path, data in
                fileSystem[path] = data
            },
            remove: { _ in }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["test.txt"], "Line1\nLine2")
    }

    func testHunkHeaderDisambiguatesSimilarHunks() throws {
        let original = "foo\nbar\nbaz\nbar\nqux"
        var fileSystem = ["dup.txt": original]
        let patch = """
        *** Begin Patch
        --- dup.txt
        +++ dup.txt
        @@ -4,1 +4,1 @@
        -bar
        +BAR
        *** End Patch
        """
        let applier = PatchApplier(
            read: { path in fileSystem[path]! },
            write: { path, data in fileSystem[path] = data },
            remove: { _ in }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["dup.txt"], "foo\nbar\nbaz\nBAR\nqux")
    }

    func testUpdateSimple() throws {
        let original = "A\nB\nC"
        var fileSystem = ["foo.txt": original]
        let patch = """
        *** Begin Patch
        --- foo.txt
        +++ foo.txt
        @@
         A
        -B
        +X
         C
        *** End Patch
        """
        var removed = [String]()
        let applier = PatchApplier(
            read: { path in fileSystem[path]! },
            write: { path, data in fileSystem[path] = data },
            remove: { removed.append($0) }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["foo.txt"], "A\nX\nC")
        XCTAssertTrue(removed.isEmpty)
    }

    func testDeleteFile() throws {
        var fileSystem = ["del.txt": "data"]
        let patch = """
        *** Begin Patch
        --- del.txt
        +++ /dev/null
        @@
        *** End Patch
        """
        var removed = [String]()
        let applier = PatchApplier(
            read: { path in
                if let contents = fileSystem[path] { return contents }
                throw PatchError.missing(path)
            },
            write: { _, _ in XCTFail("Should not write") },
            remove: { fileSystem.removeValue(forKey: $0); removed.append($0) }
        )
        try applier.apply(patch)
        XCTAssertNil(fileSystem["del.txt"])
        XCTAssertEqual(removed, ["del.txt"])
    }

    func testMoveFile() throws {
        var fileSystem = ["old.txt": "HELLO"]
        let patch = """
        *** Begin Patch
        --- old.txt
        +++ new.txt
        @@
         HELLO
        *** End Patch
        """
        var removed = [String]()
        let applier = PatchApplier(
            read: { path in fileSystem[path]! },
            write: { path, data in fileSystem[path] = data },
            remove: { fileSystem.removeValue(forKey: $0); removed.append($0) }
        )
        try applier.apply(patch)
        XCTAssertNil(fileSystem["old.txt"])
        XCTAssertEqual(fileSystem["new.txt"], "HELLO")
        XCTAssertEqual(removed, ["old.txt"])
    }

    func testMultipleDirectives() throws {
        var fileSystem = ["file2.txt": "X\nY\nZ", "file3.txt": "to delete"]
        let patch = """
        *** Begin Patch
        --- /dev/null
        +++ file1.txt
        @@
        +one
        +two
        --- file2.txt
        +++ file2.txt
        @@
         X
        -Y
        +Y2
         Z
        --- file3.txt
        +++ /dev/null
        @@
        *** End Patch
        """
        let applier = PatchApplier(
            read: { path in
                if let content = fileSystem[path] {
                    return content
                }
                throw PatchError.missing(path)
            },
            write: { path, data in fileSystem[path] = data },
            remove: { fileSystem.removeValue(forKey: $0) }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["file1.txt"], "one\ntwo")
        XCTAssertEqual(fileSystem["file2.txt"], "X\nY2\nZ")
        XCTAssertNil(fileSystem["file3.txt"])
    }

    func testMalformedMissingMarkers() {
        let patch = "no markers here"
        XCTAssertThrowsError(try PatchApplier().apply(patch)) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed error")
            }
        }
    }

    func testMalformedDuplicateDirective() {
        let patch = """
        *** Begin Patch
        --- /dev/null
        +++ a.txt
        @@
        +A
        --- /dev/null
        +++ a.txt
        @@
        +B
        *** End Patch
        """
        XCTAssertThrowsError(try PatchApplier().apply(patch)) { error in
            guard case let PatchError.duplicate(path) = error, path == "a.txt" else {
                return XCTFail("Expected duplicate error for a.txt")
            }
        }
    }

    func testMalformedUnknownVerb() {
        let patch = """
        *** Begin Patch
        +++ foo file.txt
        @@
        +A
        *** End Patch
        """
        XCTAssertThrowsError(try PatchApplier().apply(patch)) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed error")
            }
        }
    }

    func testContextMismatch() {
        let original = "line1\nline2"
        var fileSystem = ["ctx.txt": original]
        let patch = """
        *** Begin Patch
        --- ctx.txt
        +++ ctx.txt
        @@
         wrong
        -line2
        +new
        *** End Patch
        """
        XCTAssertThrowsError(
            try PatchApplier(
                read: { fileSystem[$0]! },
                write: { path, data in fileSystem[path] = data },
                remove: { _ in }
            ).apply(patch)
        ) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed context mismatch")
            }
        }
    }

    func testDeleteOOB() {
        let original = "only"
        let fileSystem = ["one.txt": original]
        let patch = """
        *** Begin Patch
        --- one.txt
        +++ one.txt
        @@
        -only
        -extra
        *** End Patch
        """
        XCTAssertThrowsError(
            try PatchApplier(
                read: { fileSystem[$0]! },
                write: { _, _ in },
                remove: { _ in }
            ).apply(patch)
        ) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed delete OOB")
            }
        }
    }

    func testHunkHeaderLineNumbersWithoutContext() throws {
        let original = "L1\nL2\nL3\nL4"
        var fileSystem = ["test.txt": original]
        let patch = """
        *** Begin Patch
        --- test.txt
        +++ test.txt
        @@ -2,2 +2,2 @@
        -L2
        +X
        -L3
        +Y
        *** End Patch
        """
        let applier = PatchApplier(
            read: { path in fileSystem[path]! },
            write: { path, data in fileSystem[path] = data },
            remove: { _ in }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["test.txt"], "L1\nX\nY\nL4")
    }

    func testMultipleHunksPreserveUnmodifiedContent() throws {
        let original = "A\nB\nC\nD\nE"
        var fileSystem = ["file.txt": original]
        let patch = """
        *** Begin Patch
        --- file.txt
        +++ file.txt
        @@ -1 +1 @@
        -A
        +a
        @@ -5 +5 @@
        -E
        +e
        *** End Patch
        """
        let applier = PatchApplier(
            read: { path in fileSystem[path]! },
            write: { path, data in fileSystem[path] = data },
            remove: { _ in }
        )
        try applier.apply(patch)
        XCTAssertEqual(fileSystem["file.txt"], "a\nB\nC\nD\ne")
    }
}
