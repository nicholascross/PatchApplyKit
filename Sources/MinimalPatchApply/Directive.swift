struct Directive {
    let operation: Operation
    let path: String
    let movePath: String?
    var hunks: [[Line]] = []
}
