public enum PatchError: Error, CustomStringConvertible {
    case malformed(String), duplicate(String), missing(String), exists(String)

    public var description: String {
        switch self {
        case .malformed(let message):
            return "Malformed patch – \(message)"
        case .duplicate(let message):
            return "Duplicate directive for ‘\(message)’"
        case .missing(let message):
            return "File not found: \(message)"
        case .exists(let message):
            return "File already exists: \(message)"
        }
    }
}
