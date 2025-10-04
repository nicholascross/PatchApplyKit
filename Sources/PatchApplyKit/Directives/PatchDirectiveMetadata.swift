import Foundation

/// Additional metadata extracted from diff headers between directives and hunks.
public struct PatchDirectiveMetadata: Equatable {
    public let index: PatchIndexLine?
    public let fileModeChange: PatchFileModeChange?
    public let similarityIndex: Int?
    public let dissimilarityIndex: Int?
    public let renameFrom: String?
    public let renameTo: String?
    public let copyFrom: String?
    public let copyTo: String?
    public let isBinary: Bool
    public let rawLines: [String]

    public init(
        index: PatchIndexLine? = nil,
        fileModeChange: PatchFileModeChange? = nil,
        similarityIndex: Int? = nil,
        dissimilarityIndex: Int? = nil,
        renameFrom: String? = nil,
        renameTo: String? = nil,
        copyFrom: String? = nil,
        copyTo: String? = nil,
        isBinary: Bool = false,
        rawLines: [String] = []
    ) {
        self.index = index
        self.fileModeChange = fileModeChange
        self.similarityIndex = similarityIndex
        self.dissimilarityIndex = dissimilarityIndex
        self.renameFrom = renameFrom
        self.renameTo = renameTo
        self.copyFrom = copyFrom
        self.copyTo = copyTo
        self.isBinary = isBinary
        self.rawLines = rawLines
    }
}
