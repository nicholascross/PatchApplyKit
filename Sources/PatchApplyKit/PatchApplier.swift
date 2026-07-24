import Foundation

/// High-level façade that coordinates parsing, validation, and application of unified diff patches.
public struct PatchApplier {
    private let inputFormat: PatchInputFormat
    private let tokenizer: PatchTokenizer
    private let parser: PatchParser
    private let validator: PatchValidator
    private let fileSystem: PatchFileSystem
    private let configuration: PatchApplicator.Configuration
    private let applicator: PatchApplicator

    public init(
        inputFormat: PatchInputFormat = .unifiedDiff,
        tokenizer: PatchTokenizer = PatchTokenizer(),
        parser: PatchParser = PatchParser(),
        validator: PatchValidator = PatchValidator(),
        fileSystem: PatchFileSystem = LocalFileSystem(),
        configuration: PatchApplicator.Configuration = .init()
    ) {
        self.inputFormat = inputFormat
        self.tokenizer = tokenizer
        self.parser = parser
        self.validator = validator
        self.fileSystem = fileSystem
        self.configuration = configuration
        applicator = PatchApplicator(fileSystem: fileSystem, configuration: configuration)
    }

    /// Applies a unified diff that is wrapped by `*** Begin Patch` / `*** End Patch` sentinels.
    /// - Parameter text: Raw patch text.
    public func apply(text: String) throws {
        _ = try applyReturningResult(text: text)
    }

    /// Applies patch text and returns a summary of touched paths.
    /// - Parameter text: Raw patch text.
    public func applyReturningResult(text: String) throws -> PatchApplicationResult {
        let plan = try preparePlan(from: text)
        switch inputFormat {
        case .unifiedDiff:
            try applicator.apply(plan)
        case .codexApplyPatch:
            let applicator = CodexPatchApplicator(fileSystem: fileSystem, configuration: configuration)
            try applicator.apply(plan)
        }
        return PatchApplicationResult(changedPaths: plan.changedPaths)
    }

    /// Parses and validates patch text without applying it.
    /// - Parameter text: Raw patch text.
    public func preparePlan(from text: String) throws -> PatchPlan {
        let normalizedText = try normalize(text)
        let tokens = try tokenizer.tokenize(normalizedText)
        let plan = try parser.parse(tokens: tokens)
        try validator.validate(plan)
        guard !plan.directives.isEmpty else {
            throw PatchEngineError.validationFailed("patch does not contain any executable directives")
        }
        return plan
    }

    private func normalize(_ text: String) throws -> String {
        switch inputFormat {
        case .unifiedDiff:
            return text
        case .codexApplyPatch:
            return try CodexPatchNormalizer(fileSystem: fileSystem).normalize(text)
        }
    }
}

/// Patch text dialect accepted by `PatchApplier`.
public enum PatchInputFormat {
    /// Strict unified diff content wrapped by `*** Begin Patch` and `*** End Patch`.
    case unifiedDiff
    /// Codex apply-patch text, including shorthand add/delete directives and relaxed hunk syntax.
    case codexApplyPatch
}

/// Result returned after applying a patch.
public struct PatchApplicationResult: Equatable {
    public let changedPaths: [String]

    public init(changedPaths: [String]) {
        self.changedPaths = changedPaths
    }
}
