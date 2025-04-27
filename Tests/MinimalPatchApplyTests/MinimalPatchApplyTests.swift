@testable import MinimalPatchApply
import Testing

@Test
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
    let result = try #require(fileSystem["test.txt"])
    #expect(result == "Line1\nLine2")
}

@Test
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
    let result = try #require(fileSystem["dup.txt"])
    #expect(result == "foo\nbar\nbaz\nBAR\nqux")
}

@Test
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
    let result = try #require(fileSystem["foo.txt"])
    #expect(result == "A\nX\nC")
    #expect(removed.isEmpty)
}

@Test
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
        write: { _, _ in
            Issue.record(PatchError.malformed("Should not write"), "Should not write")
        },
        remove: { fileSystem.removeValue(forKey: $0); removed.append($0) }
    )
    try applier.apply(patch)
    #expect(fileSystem["del.txt"] == nil)
    #expect(removed == ["del.txt"])
}

@Test
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
    #expect(fileSystem["old.txt"] == nil)
    let result = try #require(fileSystem["new.txt"])
    #expect(result == "HELLO")
    #expect(removed == ["old.txt"])
}

@Test
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
    let file1 = try #require(fileSystem["file1.txt"])
    #expect(file1 == "one\ntwo")
    let file2 = try #require(fileSystem["file2.txt"])
    #expect(file2 == "X\nY2\nZ")
    #expect(fileSystem["file3.txt"] == nil)
}

@Test
func testMalformedMissingMarkers() throws {
    let patch = "no markers here"
    #expect(throws: PatchError.self) { try PatchApplier().apply(patch) }
}

@Test
func testMalformedDuplicateDirective() throws {
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
    #expect(throws: PatchError.self) { try PatchApplier().apply(patch) }
}

@Test
func testMalformedUnknownVerb() throws {
    let patch = """
    *** Begin Patch
    +++ foo file.txt
    @@
    +A
    *** End Patch
    """
    #expect(throws: PatchError.self) { try PatchApplier().apply(patch) }
}

@Test
func testContextMismatch() throws {
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
    #expect(throws: PatchError.self) { try PatchApplier(
        read: { fileSystem[$0]! },
        write: { path, data in fileSystem[path] = data },
        remove: { _ in }
    ).apply(patch) }
}

@Test
func testDeleteOOB() throws {
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
    #expect(throws: PatchError.self) { try PatchApplier(
        read: { fileSystem[$0]! },
        write: { _, _ in },
        remove: { _ in }
    ).apply(patch)
    }
}

@Test
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
    let result = try #require(fileSystem["test.txt"])
    #expect(result == "L1\nX\nY\nL4")
}

@Test
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
    let result = try #require(fileSystem["file.txt"])
    #expect(result == "a\nB\nC\nD\ne")
}
