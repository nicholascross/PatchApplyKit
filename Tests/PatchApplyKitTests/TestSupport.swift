import Foundation
@testable import PatchApplyKit

enum PatchFixtures {
    static let updateHello = """
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

    static let addGreet = """
    *** Begin Patch
    *** Add File: greet.txt
    --- /dev/null
    +++ b/greet.txt
    @@ -0,0 +1,2 @@
    +Hello
    +World
    *** End Patch
    """

    static let updateHelloWithoutExclamation = """
    *** Begin Patch
    *** Update File: hello.txt
    --- a/hello.txt
    +++ b/hello.txt
    @@ -1,2 +1,2 @@
    -Hello
    +Hello there
     World
    *** End Patch
    """

    static let deleteObsolete = """
    *** Begin Patch
    *** Delete File: obsolete.txt
    --- a/obsolete.txt
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -Goodbye
    -World
    *** End Patch
    """

    static let renameFooToBar = """
    *** Begin Patch
    *** Rename File: foo.txt -> bar.txt
    --- a/foo.txt
    +++ b/bar.txt
    @@ -1 +1 @@
    -foo
    +bar
    *** End Patch
    """

    static let copyHello = """
    *** Begin Patch
    *** Copy File: hello.txt -> hello-copy.txt
    --- a/hello.txt
    +++ b/hello-copy.txt
    *** End Patch
    """

    static let copyHelloWithWelcome = """
    *** Begin Patch
    *** Copy File: hello.txt -> welcome.txt
    --- a/hello.txt
    +++ b/welcome.txt
    @@ -1,2 +1,3 @@
     Hello
     World
    +Welcome!
    *** End Patch
    """

    static let updateHelloWithMetadata = """
    *** Begin Patch
    *** Update File: hello.txt
    index a1b2c3d..d4e5f6a 100644
    old mode 100644
    new mode 100755
    similarity index 90%
    --- a/hello.txt
    +++ b/hello.txt
    @@ -1,2 +1,3 @@
    -Hello
    +Hello there
     World
    +!
    *** End Patch
    """

    static let binaryCopyPatch = """
    *** Begin Patch
    *** Copy Binary File: image.png -> image-copy.png
    Binary files a/image.png and b/image-copy.png differ
    --- a/image.png
    +++ b/image-copy.png
    *** End Patch
    """

    static let binaryModifyPatch = """
    *** Begin Patch
    *** Update Binary File: Assets/icon.bin
    Binary files a/Assets/icon.bin and b/Assets/icon.bin differ
    --- a/Assets/icon.bin
    +++ b/Assets/icon.bin
    GIT binary patch
    literal 4
    /wCqVQ==

    literal 3
    AQID

    *** End Patch
    """

    static let binaryAddPatch = """
    *** Begin Patch
    *** Add Binary File: Assets/icon.bin
    new file mode 100644
    Binary files /dev/null and b/Assets/icon.bin differ
    --- /dev/null
    +++ b/Assets/icon.bin
    GIT binary patch
    literal 4
    /wCqVQ==

    literal 0


    *** End Patch
    """

    static let addExecutablePatch = """
    *** Begin Patch
    *** Add File: script.sh
    new file mode 100755
    --- /dev/null
    +++ b/script.sh
    @@ -0,0 +1 @@
    +echo hello
    *** End Patch
    """

    static let whitespaceInsensitivePatch = """
    *** Begin Patch
    *** Update File: code.swift
    --- a/code.swift
    +++ b/code.swift
    @@ -1 +1 @@
    -foo=1
    +foo = 2
    *** End Patch
    """

    static let complexFeaturePatch = #"""
    *** Begin Patch
    *** Update File: Sources/App/FeatureService.swift
    index 6b7f123..9d0a456 100644
    --- a/Sources/App/FeatureService.swift
    +++ b/Sources/App/FeatureService.swift
    @@ -2,17 +2,27 @@
     
     struct FeatureService {
         let endpoint: URL
    +    private let formatter: ISO8601DateFormatter
     
         func makeRequest(id: String) -> URLRequest {
             var request = URLRequest(url: endpoint.appendingPathComponent(id))
    -        request.httpMethod = "GET"
    +        request.httpMethod = "POST"
    +        request.httpBody = try? JSONEncoder().encode(["id": id, "timestamp": formatter.string(from: Date())])
             request.addValue("application/json", forHTTPHeaderField: "Accept")
    +        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
             return request
         }
    +
    +    func retryDelay() -> TimeInterval {
    +        0.5
    +    }
     }
     
     extension FeatureService {
         func headers() -> [String: String] {
    -        ["Accept": "application/json"]
    +        [
    +            "Accept": "application/json",
    +            "Content-Type": "application/json"
    +        ]
         }
    -}
    +}
    \ No newline at end of file
    *** Add File: Resources/feature/config.yaml
    new file mode 100644
    --- /dev/null
    +++ b/Resources/feature/config.yaml
    @@ -0,0 +1,9 @@
    +feature:
    +  enabled: true
    +  endpoints:
    +    - "/v1/feature"
    +    - "/v1/feature/alternate"
    +  cache:
    +    ttl: 15
    +    strategy: "background"
    +  retries: 3
    *** Rename File: README.md -> Docs/README.md
    rename from README.md
    rename to Docs/README.md
    similarity index 88%
    --- a/README.md
    +++ b/Docs/README.md
    @@ -1,4 +1,6 @@
    -# Spatchula
    +# Spatchula Documentation
     A tiny patch applier.
     
     Refer to CONTRIBUTING.md for details.
    +
    +Additional examples live in `Docs/examples`.
    *** End Patch
    """#
}

final class InMemoryFileSystem: PatchFileSystem {
    enum FileError: Swift.Error {
        case notFound(String)
    }

    private struct Entry {
        var data: Data
        var permissions: UInt16?
    }

    private var storage: [String: Entry]

    init(initialFiles: [String: String] = [:], initialBinaryFiles: [String: Data] = [:]) {
        var storage = initialFiles.reduce(into: [String: Entry]()) { result, element in
            result[element.key] = Entry(data: Data(element.value.utf8), permissions: nil)
        }
        for (path, data) in initialBinaryFiles {
            storage[path] = Entry(data: data, permissions: storage[path]?.permissions)
        }
        self.storage = storage
    }

    func fileExists(at path: String) -> Bool {
        storage[path] != nil
    }

    func readFile(at path: String) throws -> Data {
        guard let entry = storage[path] else {
            throw FileError.notFound(path)
        }
        return entry.data
    }

    func writeFile(_ data: Data, to path: String) throws {
        storage[path] = Entry(data: data, permissions: storage[path]?.permissions)
    }

    func removeItem(at path: String) throws {
        storage.removeValue(forKey: path)
    }

    func moveItem(from source: String, to destination: String) throws {
        guard let entry = storage[source] else {
            throw FileError.notFound(source)
        }
        storage[destination] = entry
        storage.removeValue(forKey: source)
    }

    func setPOSIXPermissions(_ permissions: UInt16, at path: String) throws {
        guard var entry = storage[path] else {
            throw FileError.notFound(path)
        }
        entry.permissions = permissions
        storage[path] = entry
    }

    func string(at path: String) -> String? {
        storage[path].flatMap { String(data: $0.data, encoding: .utf8) }
    }

    func data(at path: String) -> Data? {
        storage[path]?.data
    }

    func permissions(at path: String) -> UInt16? {
        storage[path]?.permissions
    }
}
