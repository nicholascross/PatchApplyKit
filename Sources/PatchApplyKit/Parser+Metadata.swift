import Foundation

extension PatchParser {
    func parseMetadata(lines: [String]) -> PatchDirectiveMetadata {
        guard !lines.isEmpty else { return PatchDirectiveMetadata(rawLines: []) }

        var components = MetadataComponents()
        for line in lines {
            updateMetadataComponents(&components, with: line)
        }

        return PatchDirectiveMetadata(
            index: components.indexLine,
            fileModeChange: components.modeChange,
            similarityIndex: components.similarity,
            dissimilarityIndex: components.dissimilarity,
            renameFrom: components.renameFrom,
            renameTo: components.renameTo,
            copyFrom: components.copyFrom,
            copyTo: components.copyTo,
            rawLines: lines
        )
    }

    struct MetadataComponents {
        var indexLine: PatchIndexLine?
        var oldMode: String?
        var newMode: String?
        var similarity: Int?
        var dissimilarity: Int?
        var renameFrom: String?
        var renameTo: String?
        var copyFrom: String?
        var copyTo: String?

        var modeChange: PatchFileModeChange? {
            guard oldMode != nil || newMode != nil else { return nil }
            return PatchFileModeChange(oldMode: oldMode, newMode: newMode)
        }
    }

    typealias MetadataAssignment = (prefix: String, keyPath: WritableKeyPath<MetadataComponents, String?>)

    func updateMetadataComponents(
        _ components: inout MetadataComponents,
        with line: String
    ) {
        if line.hasPrefix("index ") {
            components.indexLine = parseIndexLine(line)
            return
        }
        if line.hasPrefix("mode change ") {
            updateModeChange(from: line, components: &components)
            return
        }
        if line.hasPrefix("similarity index ") {
            components.similarity = parsePercentage(line, prefix: "similarity index ")
            return
        }
        if line.hasPrefix("dissimilarity index ") {
            components.dissimilarity = parsePercentage(line, prefix: "dissimilarity index ")
            return
        }

        let assignments: [MetadataAssignment] = [
            ("new file mode ", \.newMode),
            ("new file executable mode ", \.newMode),
            ("new mode ", \.newMode),
            ("deleted file mode ", \.oldMode),
            ("deleted file executable mode ", \.oldMode),
            ("old mode ", \.oldMode),
            ("rename from ", \.renameFrom),
            ("rename to ", \.renameTo),
            ("copy from ", \.copyFrom),
            ("copy to ", \.copyTo)
        ]

        for assignment in assignments {
            if let value = substring(after: assignment.prefix, in: line) {
                components[keyPath: assignment.keyPath] = value
                return
            }
        }
    }

    func updateModeChange(from line: String, components: inout MetadataComponents) {
        let payload = line.dropFirst("mode change ".count)
        let parts = payload.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == ">" })
        if parts.count >= 2 {
            components.oldMode = String(parts[0])
            components.newMode = String(parts[1])
        }
    }

    func substring(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    func parsePercentage(_ line: String, prefix: String) -> Int? {
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let trimmed = value.hasSuffix("%") ? String(value.dropLast()) : value
        return Int(trimmed)
    }
}
