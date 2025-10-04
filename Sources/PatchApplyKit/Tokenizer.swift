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
        var state = TokenizerState()

        for line in lines {
            if let token = try consume(line, state: &state) {
                tokens.append(token)
            }
        }

        guard state.hasEndMarker else {
            throw PatchEngineError.malformed("missing end marker")
        }
        return tokens
    }

    private struct TokenizerState {
        var isInPatch = false
        var hasEndMarker = false
    }

    private func consume(_ line: String, state: inout TokenizerState) throws -> PatchToken? {
        if line == beginMarker {
            guard !state.isInPatch else {
                throw PatchEngineError.malformed("nested begin markers detected")
            }
            state.isInPatch = true
            return .beginMarker
        }
        if line == endMarker {
            guard state.isInPatch else {
                throw PatchEngineError.malformed("end marker encountered before begin marker")
            }
            state.isInPatch = false
            state.hasEndMarker = true
            return .endMarker
        }
        guard state.isInPatch else {
            return nil
        }
        return classifyContent(line)
    }

    private func classifyContent(_ line: String) -> PatchToken {
        if line.hasPrefix("--- ") {
            return .fileOld(String(line.dropFirst(4)))
        }
        if line.hasPrefix("+++ ") {
            return .fileNew(String(line.dropFirst(4)))
        }
        if metadataPrefixes.contains(where: line.hasPrefix) {
            return .metadata(line)
        }
        if line.hasPrefix("@@") {
            return .hunkHeader(line)
        }
        if line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("\\") {
            return .hunkLine(line)
        }
        if line.hasPrefix("*** ") {
            return .header(line)
        }
        if line.isEmpty {
            return .hunkLine(line)
        }
        return .other(line)
    }
}
