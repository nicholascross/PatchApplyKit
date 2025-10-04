# PatchApplyKit

PatchApplyKit is a Swift library for parsing, validating, and applying Git-style unified diff patches wrapped by `*** Begin Patch` / `*** End Patch` sentinels. It handles multi-file changes, file mode updates, and protective validation before touching the file system.

## Features

- High-level `PatchApplier` façade that runs tokenization → parsing → validation → application.
- Support for add, delete, modify, rename, and copy directives in a single patch stream.
- Optional `SandboxedFileSystem` to constrain writes to a specific directory.
- Text-based patching with POSIX permission updates.
- Explicit rejection of binary diffs (`Binary files ...` / `GIT binary patch`).
- Configurable whitespace handling and fuzzy context tolerance for resilient patching.

## Installation

Add PatchApplyKit to your `Package.swift`:

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "YourApp",
    dependencies: [
        // Replace the URL and version once the package is hosted.
        .package(url: "https://github.com/nicholascross/PatchApplyKit.git", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "PatchApplyKit", package: "PatchApplyKit")
            ]
        )
    ]
)
```

For local development, you can use `.package(path: "../PatchApplyKit")` instead.

## Quick Start

```swift
import Foundation
import PatchApplyKit

let patch = """
*** Begin Patch
*** Update File: hello.txt
--- a/hello.txt
+++ b/hello.txt
@@ -1,2 +1,3 @@
-Hello
+Hello there
 World
+!
*** End Patch
"""

do {
    let applier = PatchApplier() // Uses LocalFileSystem by default.
    try applier.apply(text: patch)
    print("Patch applied successfully.")
} catch {
    print("Failed to apply patch: \(error)")
}
```

The default `LocalFileSystem` reads and writes paths relative to the current working directory.

## Applying Inside a Sandbox

Use `SandboxedFileSystem` to confine all file operations beneath a root directory:

```swift
import Foundation
import PatchApplyKit

let root = FileManager.default
    .temporaryDirectory
    .appendingPathComponent("patch-playground")
let sandboxedFS = SandboxedFileSystem(rootPath: root.path)

let patch = """
*** Begin Patch
*** Add File: Notes/todo.txt
--- /dev/null
+++ b/Notes/todo.txt
@@ -0,0 +1,2 @@
+Buy coffee
+Write README
*** End Patch
"""

let applier = PatchApplier(fileSystem: sandboxedFS)
try applier.apply(text: patch)
// Result is confined to <tmp>/patch-playground/Notes/todo.txt
```

Any attempt to escape the sandbox (e.g. `../`) raises a `PatchEngineError.ioFailure`.

## Customizing Whitespace and Context Matching

Tweak patch sensitivity with the `PatchApplicator.Configuration` options exposed by `PatchApplier`:

```swift
import PatchApplyKit

let tolerantApplier = PatchApplier(
    fileSystem: LocalFileSystem(),
    configuration: .init(
        whitespace: .ignoreAll, // Treat "foo=1" and "foo = 1" as equivalent context.
        contextTolerance: 2      // Allow up to 2 mismatched context lines.
    )
)

try tolerantApplier.apply(text: """
*** Begin Patch
*** Update File: code.swift
--- a/code.swift
+++ b/code.swift
@@ -1 +1 @@
-foo=1
+foo = 2
*** End Patch
""")
```

With `whitespace: .ignoreAll`, minor formatting differences in context lines no longer block patch application. `contextTolerance` relaxes exact matches by allowing limited drift between the expected and actual file.

### Understanding `contextTolerance`

The unified-diff format includes context lines around each hunk so the patch engine can anchor additions and deletions to the right location. PatchApplyKit normally requires those context lines to match exactly; otherwise, the patch is rejected to avoid corrupting the target file. Setting `contextTolerance` to a positive integer lets the validator forgive a limited number of mismatched context lines per hunk. When a mismatch is detected, the applicator scans outward—up to the tolerance you provided—trying to find a nearby match before giving up. This is useful when the surrounding code has drifted slightly (for example, due to unrelated formatting or wording changes) but the overall structure is still recognizable. Keep the value small so patches do not land far from their intended anchor; a tolerance between 1 and 3 typically balances resilience with safety.

## File Modes

If the patch describes new POSIX permissions (e.g. `new file mode 100755`), PatchApplyKit applies them after writing the file.

## Limitations

PatchApplyKit intentionally focuses on text-based unified diffs. Patches that declare binary content—such as lines beginning with `Binary files` or sections headed by `GIT binary patch`—are rejected with `PatchEngineError.validationFailed("binary patches are not supported")` to prevent unintended binary writes.

## Error Handling

`PatchApplier` throws `PatchEngineError` for malformed patches, validation failures, or I/O issues. Inspect the associated message to decide whether you can recover (e.g. by regenerating the patch or adjusting configuration).

## Extending PatchApplyKit

- Implement `PatchFileSystem` to integrate with non-disk storage (databases, cloud object stores, etc.).
- Use the lower-level phases (`PatchTokenizer`, `PatchParser`, `PatchValidator`, `PatchApplicator`) directly if you need custom orchestration or diagnostics.
