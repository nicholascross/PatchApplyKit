import Foundation

/// Structured error type thrown during parsing or application.
public enum PatchEngineError: Error, CustomStringConvertible {
    case malformed(String)
    case validationFailed(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .malformed(let message):
            return "Malformed patch – \(message)"
        case .validationFailed(let message):
            return "Patch validation failed – \(message)"
        case .ioFailure(let message):
            return "File system error – \(message)"
        }
    }
}
