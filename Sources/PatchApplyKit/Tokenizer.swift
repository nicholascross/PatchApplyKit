import Foundation

/// Token representing a semantically meaningful chunk of the patch stream.
public enum PatchToken: Equatable {
    case beginMarker
    case endMarker
    case header(String)
    case metadata(String)
    case fileOld(String)
    case fileNew(String)
    case hunkHeader(String)
    case hunkLine(String)
    case other(String)
}

/// Responsible for turning a raw unified diff string into tokens for the parser.
public struct PatchTokenizer {
    private let beginMarker = "*** Begin Patch"
    private let endMarker = "*** End Patch"

    private let metadataPrefixes = [
        "index ",
        "old mode ",
        "new mode ",
        "deleted file mode ",
        "new file mode ",
        "mode change ",
        "similarity index ",
        "dissimilarity index ",
        "rename from ",
        "rename to ",
        "copy from ",
        "copy to ",
        "Binary files ",
        "binary files ",
        "new file executable mode ",
        "deleted file executable mode ",
        "index .."
    ]

    public init() {}

    public func tokenize(_ text: String) throws -> [PatchToken] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tokens: [PatchToken] = []
        var isInPatch = false
        var hasEndMarker = false

        for line in lines {
            if line == beginMarker {
                guard !isInPatch else {
                    throw PatchEngineError.malformed("nested begin markers detected")
                }
                tokens.append(.beginMarker)
                isInPatch = true
                continue
            }
            if line == endMarker {
                guard isInPatch else {
                    throw PatchEngineError.malformed("end marker encountered before begin marker")
                }
                tokens.append(.endMarker)
                isInPatch = false
                hasEndMarker = true
                continue
            }
            guard isInPatch else {
                // Ignore any preamble prior to the begin marker.
                continue
            }

            if line.hasPrefix("--- ") {
                tokens.append(.fileOld(String(line.dropFirst(4))))
            } else if line.hasPrefix("+++ ") {
                tokens.append(.fileNew(String(line.dropFirst(4))))
            } else if metadataPrefixes.contains(where: line.hasPrefix) {
                tokens.append(.metadata(line))
            } else if line.hasPrefix("@@") {
                tokens.append(.hunkHeader(line))
            } else if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\") {
                tokens.append(.hunkLine(line))
            } else if line.hasPrefix("*** ") {
                tokens.append(.header(line))
            } else if line.isEmpty {
                tokens.append(.hunkLine(line))
            } else {
                tokens.append(.other(line))
            }
        }

        guard hasEndMarker else {
            throw PatchEngineError.malformed("missing end marker")
        }
        return tokens
    }
}
