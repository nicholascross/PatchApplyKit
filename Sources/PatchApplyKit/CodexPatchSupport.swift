import Foundation

struct CodexPatchNormalizer {
    let fileSystem: PatchFileSystem

    func normalize(_ text: String) throws -> String {
        try expandShorthandDirectives(
            in: dropNoOpHunks(from: repairHunkLinePrefixes(in: text))
        )
    }

    private func repairHunkLinePrefixes(in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var inHunk = false
        var previousPrefix: Character?

        for index in lines.indices {
            let line = lines[index]
            if line.hasPrefix("@@") {
                inHunk = true
                previousPrefix = nil
                continue
            }
            if line.hasPrefix("*** ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                inHunk = false
                previousPrefix = nil
                continue
            }
            guard inHunk, line != "\\ No newline at end of file" else { continue }

            guard let first = line.first else {
                lines[index] = previousPrefix.map(String.init) ?? " "
                continue
            }
            if first == " " || first == "+" || first == "-" {
                previousPrefix = first
            } else if let previousPrefix {
                lines[index] = "\(previousPrefix)\(line)"
            } else {
                lines[index] = " \(line)"
                previousPrefix = " "
            }
        }

        return lines.joined(separator: "\n")
    }

    private func dropNoOpHunks(from text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < lines.count {
            guard lines[index].hasPrefix("@@") else {
                output.append(lines[index])
                index += 1
                continue
            }

            let hunkStart = index
            index += 1
            while index < lines.count,
                  !lines[index].hasPrefix("@@"),
                  !lines[index].hasPrefix("*** "),
                  !lines[index].hasPrefix("--- "),
                  !lines[index].hasPrefix("+++ ")
            {
                index += 1
            }

            let hunk = Array(lines[hunkStart ..< index])
            if hunk.dropFirst().contains(where: isChangedHunkLine) {
                output.append(contentsOf: hunk)
            }
        }

        return output.joined(separator: "\n")
    }

    private func isChangedHunkLine(_ line: String) -> Bool {
        line.hasPrefix("+") || line.hasPrefix("-")
    }

    private func expandShorthandDirectives(in text: String) throws -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard let directive = CodexDirective(line) else {
                output.append(line)
                index += 1
                continue
            }

            let bodyStart = index + 1
            var bodyEnd = bodyStart
            while bodyEnd < lines.count, !lines[bodyEnd].hasPrefix("*** ") {
                bodyEnd += 1
            }

            let body = Array(lines[bodyStart ..< bodyEnd])
            output.append(line)
            switch directive.operation {
            case .add:
                output.append(contentsOf: expandAddFile(path: directive.path, body: body))
            case .delete:
                try output.append(contentsOf: expandDeleteFile(path: directive.path, body: body))
            case .update:
                output.append(contentsOf: body)
            }
            index = bodyEnd
        }

        return output.joined(separator: "\n")
    }

    private func expandAddFile(path: String, body: [String]) -> [String] {
        guard !body.contains(where: isFileHeaderOrHunk) else { return body }
        let additionCount = body.count { $0.hasPrefix("+") }
        return [
            "--- /dev/null",
            "+++ b/\(path)",
            "@@ -0,0 +1,\(additionCount) @@",
        ] + body
    }

    private func expandDeleteFile(path: String, body: [String]) throws -> [String] {
        guard body.isEmpty else { return body }
        let data = try fileSystem.readFile(at: path)
        guard let content = String(data: data, encoding: .utf8) else {
            throw PatchEngineError.ioFailure("file at \(path) is not valid UTF-8")
        }

        let source = TextBuffer(string: content)
        guard !source.lines.isEmpty else {
            throw PatchEngineError.validationFailed("delete directive for \(path) is missing content markers")
        }

        var hunk = [
            "--- a/\(path)",
            "+++ /dev/null",
            "@@ -1,\(source.lines.count) +0,0 @@",
        ]
        hunk += source.lines.map { "-\($0)" }
        if !source.hasTrailingNewline {
            hunk.append("\\ No newline at end of file")
        }
        return hunk
    }

    private func isFileHeaderOrHunk(_ line: String) -> Bool {
        line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("@@")
    }

    private struct CodexDirective {
        enum Operation {
            case add
            case delete
            case update
        }

        let operation: Operation
        let path: String

        init?(_ line: String) {
            if line.hasPrefix("*** Add File: ") {
                operation = .add
                path = String(line.dropFirst("*** Add File: ".count))
            } else if line.hasPrefix("*** Delete File: ") {
                operation = .delete
                path = String(line.dropFirst("*** Delete File: ".count))
            } else if line.hasPrefix("*** Update File: ") {
                operation = .update
                path = String(line.dropFirst("*** Update File: ".count))
            } else {
                return nil
            }
        }
    }
}

struct CodexPatchApplicator {
    let fileSystem: PatchFileSystem
    let configuration: PatchApplicator.Configuration

    func apply(_ plan: PatchPlan) throws {
        let applicator = PatchApplicator(fileSystem: fileSystem, configuration: configuration)

        for directive in plan.directives {
            switch directive.operation {
            case .modify:
                try applicator.applyModification(directive, contextToleranceForHunk: contextTolerance)
            case .add:
                try applicator.applyAddition(directive)
            case .delete:
                try applicator.applyDeletion(directive)
            case .rename:
                try applicator.applyRename(directive)
            case .copy:
                try applicator.applyCopy(directive)
            }
        }
    }

    private func contextTolerance(for hunk: PatchHunk) -> Int {
        let maximumContext = hunk.lines.reduce(0) { count, line in
            guard case .context = line else { return count }
            return count + 1
        }
        if hunk.lines.contains(where: isDeletion) {
            return max(configuration.contextTolerance, max(2, maximumContext))
        }
        if hasSingleContextInsertionAnchor(hunk) {
            return max(configuration.contextTolerance, 1)
        }
        return max(configuration.contextTolerance, 2)
    }

    private func isDeletion(_ line: PatchLine) -> Bool {
        guard case .deletion = line else { return false }
        return true
    }

    private func hasSingleContextInsertionAnchor(_ hunk: PatchHunk) -> Bool {
        var contextCount = 0
        for line in hunk.lines {
            switch line {
            case .context:
                contextCount += 1
            case .deletion:
                return false
            case .addition, .noNewlineMarker:
                continue
            }
        }
        return contextCount == 1
    }
}

public extension PatchPlan {
    /// Unique old/new paths touched by the plan, in directive order.
    var changedPaths: [String] {
        var paths: [String] = []
        var seen = Set<String>()

        for directive in directives {
            for path in [directive.oldPath, directive.newPath].compactMap({ $0 }) {
                if seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }

        return paths
    }
}
