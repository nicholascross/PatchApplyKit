import Foundation

struct TextBuffer {
    var lines: [String]
    var hasTrailingNewline: Bool

    init(lines: [String], hasTrailingNewline: Bool) {
        self.lines = lines
        self.hasTrailingNewline = hasTrailingNewline
    }

    init(string: String) {
        var collected: [String] = []
        var current = ""
        for character in string {
            if character == "\n" {
                collected.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        let hasTrailing = string.last == "\n"
        if !hasTrailing {
            if !string.isEmpty {
                collected.append(current)
            }
        }
        lines = collected
        hasTrailingNewline = hasTrailing
    }

    func encode() throws -> Data {
        var text = lines.joined(separator: "\n")
        if hasTrailingNewline {
            text.append("\n")
        }
        guard let data = text.data(using: .utf8) else {
            throw PatchEngineError.ioFailure("failed to encode buffer as UTF-8")
        }
        return data
    }
}

struct HunkTransform {
    enum ExpectedKind: Equatable {
        case context
        case deletion
    }

    enum ReplacementKind: Equatable {
        case context
        case addition
    }

    struct Variant {
        let expected: [String]
        let replacement: [String]
        let expectedTrailingNewline: Bool?
        let replacementTrailingNewline: Bool?
        let leadingContextTrim: Int
        let trailingContextTrim: Int
    }

    private let baseExpected: [String]
    private let baseExpectedKinds: [ExpectedKind]
    private let baseReplacement: [String]
    private let baseReplacementKinds: [ReplacementKind]
    private let baseExpectedTrailingNewline: Bool?
    private let baseReplacementTrailingNewline: Bool?

    init(hunk: PatchHunk) throws {
        var expected: [String] = []
        var expectedKinds: [ExpectedKind] = []
        var replacement: [String] = []
        var replacementKinds: [ReplacementKind] = []
        var expectedTrailing: Bool?
        var replacementTrailing: Bool?
        var lastMeaningfulLine: PatchLine?

        for line in hunk.lines {
            switch line {
            case let .context(value):
                expected.append(value)
                expectedKinds.append(.context)
                replacement.append(value)
                replacementKinds.append(.context)
                lastMeaningfulLine = line
            case let .addition(value):
                replacement.append(value)
                replacementKinds.append(.addition)
                lastMeaningfulLine = line
            case let .deletion(value):
                expected.append(value)
                expectedKinds.append(.deletion)
                lastMeaningfulLine = line
            case .noNewlineMarker:
                guard let last = lastMeaningfulLine else {
                    throw PatchEngineError.validationFailed(
                        "newline marker must follow an addition, deletion, or context line"
                    )
                }
                switch last {
                case .deletion:
                    expectedTrailing = false
                case .context, .addition:
                    replacementTrailing = false
                case .noNewlineMarker:
                    break
                }
            }
        }

        baseExpected = expected
        baseExpectedKinds = expectedKinds
        baseReplacement = replacement
        baseReplacementKinds = replacementKinds
        baseExpectedTrailingNewline = expectedTrailing
        baseReplacementTrailingNewline = replacementTrailing
    }

    func variants(contextTolerance: Int) -> [Variant] {
        var variants: [Variant] = []
        let maxLeading = min(leadingContextCount, contextTolerance)

        for leadingTrim in 0 ... maxLeading {
            let remaining = contextTolerance - leadingTrim
            let maxTrailing = min(trailingContextCount, remaining)
            for trailingTrim in 0 ... maxTrailing {
                variants.append(buildVariant(leadingTrim: leadingTrim, trailingTrim: trailingTrim))
            }
        }

        return variants.sorted { lhs, rhs in
            let lhsTrim = lhs.leadingContextTrim + lhs.trailingContextTrim
            let rhsTrim = rhs.leadingContextTrim + rhs.trailingContextTrim
            if lhsTrim != rhsTrim {
                return lhsTrim < rhsTrim
            }
            return lhs.leadingContextTrim < rhs.leadingContextTrim
        }
    }

    private func buildVariant(leadingTrim: Int, trailingTrim: Int) -> Variant {
        var expected = baseExpected
        var expectedKinds = baseExpectedKinds

        if leadingTrim > 0 {
            let prefixKinds = expectedKinds.prefix(leadingTrim)
            guard prefixKinds.allSatisfy({ $0 == .context }) else {
                preconditionFailure("Attempted to trim non-context lines from hunk prefix")
            }
            expected.removeFirst(leadingTrim)
            expectedKinds.removeFirst(leadingTrim)
        }

        if trailingTrim > 0 {
            let suffixKinds = expectedKinds.suffix(trailingTrim)
            guard suffixKinds.allSatisfy({ $0 == .context }) else {
                preconditionFailure("Attempted to trim non-context lines from hunk suffix")
            }
            expected.removeLast(trailingTrim)
            expectedKinds.removeLast(trailingTrim)
        }

        var replacement = baseReplacement
        var replacementKinds = baseReplacementKinds

        var leadingToRemove = leadingTrim
        while leadingToRemove > 0 {
            guard let index = replacementKinds.firstIndex(of: .context) else {
                preconditionFailure("Missing context entries while trimming hunk prefix")
            }
            replacement.remove(at: index)
            replacementKinds.remove(at: index)
            leadingToRemove -= 1
        }

        var trailingToRemove = trailingTrim
        while trailingToRemove > 0 {
            guard let index = replacementKinds.lastIndex(of: .context) else {
                preconditionFailure("Missing context entries while trimming hunk suffix")
            }
            replacement.remove(at: index)
            replacementKinds.remove(at: index)
            trailingToRemove -= 1
        }

        return Variant(
            expected: expected,
            replacement: replacement,
            expectedTrailingNewline: baseExpectedTrailingNewline,
            replacementTrailingNewline: baseReplacementTrailingNewline,
            leadingContextTrim: leadingTrim,
            trailingContextTrim: trailingTrim
        )
    }

    private var leadingContextCount: Int {
        var count = 0
        for kind in baseExpectedKinds {
            guard kind == .context else { break }
            count += 1
        }
        return count
    }

    private var trailingContextCount: Int {
        var count = 0
        for kind in baseExpectedKinds.reversed() {
            guard kind == .context else { break }
            count += 1
        }
        return count
    }
}
