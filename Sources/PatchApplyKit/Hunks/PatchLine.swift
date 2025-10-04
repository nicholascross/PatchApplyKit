import Foundation

/// A single line entry inside a hunk body.
public enum PatchLine: Equatable {
    case context(String)
    case addition(String)
    case deletion(String)
    case noNewlineMarker
}
