import Foundation

/// Abstracts file system interactions so the patch engine can run against disk or in-memory data.
public protocol PatchFileSystem {
    func fileExists(at path: String) -> Bool
    func readFile(at path: String) throws -> Data
    func writeFile(_ data: Data, to path: String) throws
    func removeItem(at path: String) throws
    func moveItem(from source: String, to destination: String) throws
    func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws
    func posixPermissions(at path: String) throws -> UInt16?
}

/// Default implementation backed by `FileManager`.
public struct LocalFileSystem: PatchFileSystem {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func fileExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    public func readFile(at path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func writeFile(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    public func removeItem(at path: String) throws {
        if fileExists(at: path) {
            try fileManager.removeItem(atPath: path)
        }
    }

    public func moveItem(from source: String, to destination: String) throws {
        if fileExists(at: destination) {
            try fileManager.removeItem(atPath: destination)
        }
        try fileManager.moveItem(atPath: source, toPath: destination)
    }

    public func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws {
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: NSNumber(value: permissions)]
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
    }

    public func posixPermissions(at path: String) throws -> UInt16? {
        let attributes = try fileManager.attributesOfItem(atPath: path)
        guard let value = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return UInt16(truncating: value)
    }
}

/// Wraps another file system and confines all operations to a specified root directory.
public struct SandboxedFileSystem: PatchFileSystem {
    private let base: PatchFileSystem
    private let root: URL
    private let rootPathPrefix: String

    public init(rootPath: String, base: PatchFileSystem = LocalFileSystem()) {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        root = rootURL
        let normalizedRootPath = rootURL.path
        if normalizedRootPath.hasSuffix("/") {
            rootPathPrefix = normalizedRootPath
        } else {
            rootPathPrefix = normalizedRootPath + "/"
        }
        self.base = base
    }

    public func fileExists(at path: String) -> Bool {
        guard let resolved = try? resolve(path) else {
            return false
        }
        return base.fileExists(at: resolved.path)
    }

    public func readFile(at path: String) throws -> Data {
        let resolved = try resolve(path)
        return try base.readFile(at: resolved.path)
    }

    public func writeFile(_ data: Data, to path: String) throws {
        let resolved = try resolve(path)
        try base.writeFile(data, to: resolved.path)
    }

    public func removeItem(at path: String) throws {
        let resolved = try resolve(path)
        try base.removeItem(at: resolved.path)
    }

    public func moveItem(from source: String, to destination: String) throws {
        let resolvedSource = try resolve(source)
        let resolvedDestination = try resolve(destination)
        try base.moveItem(from: resolvedSource.path, to: resolvedDestination.path)
    }

    public func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws {
        let resolved = try resolve(path)
        try base.setPOSIXPermissions(permissions, at: resolved.path)
    }

    public func posixPermissions(at path: String) throws -> UInt16? {
        let resolved = try resolve(path)
        return try base.posixPermissions(at: resolved.path)
    }

    private func resolve(_ path: String) throws -> URL {
        let candidate: URL
        if path.hasPrefix("/") {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = root.appendingPathComponent(path)
        }
        let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(normalized) else {
            throw SandboxError.pathOutsideSandbox(requested: path, resolved: normalized.path)
        }
        return normalized
    }

    private func contains(_ url: URL) -> Bool {
        let path = url.path
        if path == root.path {
            return true
        }
        return path.hasPrefix(rootPathPrefix)
    }

    public enum SandboxError: Error, CustomStringConvertible {
        case pathOutsideSandbox(requested: String, resolved: String)

        public var description: String {
            switch self {
            case let .pathOutsideSandbox(requested, resolved):
                return "path \(requested) resolves to \(resolved) which is outside the sandbox"
            }
        }
    }
}

/// Applies a validated patch plan to the provided file system.
public struct PatchApplicator {
    let fileSystem: PatchFileSystem
    let configuration: Configuration

    public enum WhitespaceMode {
        case exact
        case ignoreAll
    }

    public struct Configuration {
        public let whitespace: WhitespaceMode
        public let contextTolerance: Int

        public init(
            whitespace: WhitespaceMode = .exact,
            contextTolerance: Int = 0
        ) {
            self.whitespace = whitespace
            self.contextTolerance = max(0, contextTolerance)
        }
    }

    public init(fileSystem: PatchFileSystem, configuration: Configuration = .init()) {
        self.fileSystem = fileSystem
        self.configuration = configuration
    }

    public func apply(_ plan: PatchPlan) throws {
        for directive in plan.directives {
            switch directive.operation {
            case .add:
                try applyAddition(directive)
            case .delete:
                try applyDeletion(directive)
            case .modify:
                try applyModification(directive)
            case .rename:
                try applyRename(directive)
            case .copy:
                try applyCopy(directive)
            }
        }
    }
}
