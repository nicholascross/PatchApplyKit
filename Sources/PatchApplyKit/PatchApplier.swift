import Foundation

/// High-level façade that coordinates parsing, validation, and application of unified diff patches.
public struct PatchApplier {
    private let tokenizer: PatchTokenizer
    private let parser: PatchParser
    private let validator: PatchValidator
    private let applicator: PatchApplicator

    public init(
        tokenizer: PatchTokenizer = PatchTokenizer(),
        parser: PatchParser = PatchParser(),
        validator: PatchValidator = PatchValidator(),
        fileSystem: PatchFileSystem = LocalFileSystem(),
        configuration: PatchApplicator.Configuration = .init()
    ) {
        self.tokenizer = tokenizer
        self.parser = parser
        self.validator = validator
        applicator = PatchApplicator(fileSystem: fileSystem, configuration: configuration)
    }

    /// Applies a unified diff that is wrapped by `*** Begin Patch` / `*** End Patch` sentinels.
    /// - Parameter text: Raw patch text.
    public func apply(text: String) throws {
        let tokens = try tokenizer.tokenize(text)
        let plan = try parser.parse(tokens: tokens)
        try validator.validate(plan)
        try applicator.apply(plan)
    }
}
