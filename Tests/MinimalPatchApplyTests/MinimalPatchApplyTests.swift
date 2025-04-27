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
}