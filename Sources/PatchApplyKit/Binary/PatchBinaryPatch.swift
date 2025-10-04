import Foundation

/// Represents a binary diff payload consisting of git-style literal or delta blocks.
public struct PatchBinaryPatch: Equatable {
    public struct Block: Equatable {
        public enum Kind: Equatable {
            case literal
            case delta
        }

        public let kind: Kind
        public let expectedSize: Int
        public let data: Data

        public init(kind: Kind, expectedSize: Int, data: Data) {
            self.kind = kind
            self.expectedSize = expectedSize
            self.data = data
        }
    }

    public let blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public var newBlock: Block? {
        blocks.first
    }

    public var oldBlock: Block? {
        blocks.dropFirst().first
    }

    public var newData: Data? {
        newBlock?.data
    }

    public var oldData: Data? {
        oldBlock?.data
    }
}
