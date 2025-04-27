// Represents a single diff hunk with optional header line number information and patch lines
struct Hunk {
    // Original file start line (1-based) and number of lines in the hunk (optional)
    let oldStart: Int?
    let oldCount: Int?
    // New file start line (1-based) and number of lines in the hunk (optional)
    let newStart: Int?
    let newCount: Int?
    // Parsed lines of the hunk: context, delete, or insert operations
    let lines: [Line]
}

// Represents a patch directive for a single file (add, delete, or update) with associated hunks
struct Directive {
    let operation: Operation
    let path: String
    let movePath: String?
    // Sequence of hunks to apply for this directive
    var hunks: [Hunk] = []
}
