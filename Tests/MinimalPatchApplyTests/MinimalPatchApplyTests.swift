import XCTest
@testable import MinimalPatchApply

final class MinimalPatchApplyTests: XCTestCase {
    func testApplyAdd() throws {
        let patch = """
        *** Begin Patch
        +++ add test.txt
        @@
        +Line1
        +Line2
        *** End Patch
        """
        var fs = [String: String]()
        try applyPatch(
            patch,
            read: { path in
                if let content = fs[path] {
                    return content
                }
                throw PatchError.missing(path)
            },
            write: { path, data in
                fs[path] = data
            },
            remove: { _ in }
        )
        XCTAssertEqual(fs["test.txt"], "Line1\nLine2")
    }
    func testUpdateSimple() throws {
        let original = "A\nB\nC"
        var fs = ["foo.txt": original]
        let patch = """
        *** Begin Patch
        +++ update foo.txt
        @@
         A
        -B
        +X
         C
        *** End Patch
        """
        var removed = [String]()
        try applyPatch(
            patch,
            read: { path in fs[path]! },
            write: { path, data in fs[path] = data },
            remove: { removed.append($0) }
        )
        XCTAssertEqual(fs["foo.txt"], "A\nX\nC")
        XCTAssertTrue(removed.isEmpty)
    }

    func testDeleteFile() throws {
        var fs = ["del.txt": "data"]
        let patch = """
        *** Begin Patch
        +++ delete del.txt
        @@
        *** End Patch
        """
        var removed = [String]()
        try applyPatch(
            patch,
            read: { path in
                if let c = fs[path] { return c }
                throw PatchError.missing(path)
            },
            write: { _,_ in XCTFail("Should not write") },
            remove: { fs.removeValue(forKey: $0); removed.append($0) }
        )
        XCTAssertNil(fs["del.txt"] )
        XCTAssertEqual(removed, ["del.txt"])
    }

    func testMoveFile() throws {
        var fs = ["old.txt": "HELLO"]
        let patch = """
        *** Begin Patch
        +++ move old.txt to new.txt
        @@
         HELLO
        *** End Patch
        """
        var removed = [String]()
        try applyPatch(
            patch,
            read: { path in fs[path]! },
            write: { path, data in fs[path] = data },
            remove: { fs.removeValue(forKey: $0); removed.append($0) }
        )
        XCTAssertNil(fs["old.txt"])
        XCTAssertEqual(fs["new.txt"], "HELLO")
        XCTAssertEqual(removed, ["old.txt"])
    }

    func testMultipleDirectives() throws {
        var fs = ["file2.txt": "X\nY\nZ", "file3.txt": "to delete"]
        let patch = """
        *** Begin Patch
        +++ add file1.txt
        @@
        +one
        +two
        +++ update file2.txt
        @@
         X
        -Y
        +Y2
         Z
        +++ delete file3.txt
        @@
        *** End Patch
        """
        try applyPatch(
            patch,
            read: { path in
                if let content = fs[path] {
                    return content
                }
                throw PatchError.missing(path)
            },
            write: { path, data in fs[path] = data },
            remove: { fs.removeValue(forKey: $0) }
        )
        XCTAssertEqual(fs["file1.txt"], "one\ntwo")
        XCTAssertEqual(fs["file2.txt"], "X\nY2\nZ")
        XCTAssertNil(fs["file3.txt"])
    }

    func testMalformedMissingMarkers() {
        let patch = "no markers here"
        XCTAssertThrowsError(try applyPatch(patch)) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed error")
            }
        }
    }

    func testMalformedDuplicateDirective() {
        let patch = """
        *** Begin Patch
        +++ add a.txt
        @@
        +A
        +++ add a.txt
        @@
        +B
        *** End Patch
        """
        XCTAssertThrowsError(try applyPatch(patch)) { error in
            guard case PatchError.duplicate(let path) = error, path == "a.txt" else {
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
        XCTAssertThrowsError(try applyPatch(patch)) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed error")
            }
        }
    }

    func testContextMismatch() {
        let original = "line1\nline2"
        var fs = ["ctx.txt": original]
        let patch = """
        *** Begin Patch
        +++ update ctx.txt
        @@
         wrong
        -line2
        +new
        *** End Patch
        """
        XCTAssertThrowsError(
            try applyPatch(
                patch,
                read: { fs[$0]! },
                write: { path, data in fs[path] = data },
                remove: { _ in }
            )
        ) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed context mismatch")
            }
        }
    }

    func testDeleteOOB() {
        let original = "only"
        var fs = ["one.txt": original]
        let patch = """
        *** Begin Patch
        +++ update one.txt
        @@
        -only
        -extra
        *** End Patch
        """
        XCTAssertThrowsError(
            try applyPatch(
                patch,
                read: { fs[$0]! },
                write: { _,_ in },
                remove: { _ in }
            )
        ) { error in
            guard case PatchError.malformed = error else {
                return XCTFail("Expected malformed delete OOB")
            }
        }
    }
}