// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftSyntax

/// XCTest can construct and run cases before Swift Testing discovers its entries.
/// Describe the small set of case implementations we can match to the linked image.
struct XCTestDiscoveryCase: Codable, Hashable, Sendable {
    let path: String
    let qualifiedName: String
    let methods: [String: Body]

    enum Body: String, Codable, Sendable {
        case empty, assertTrue, assertFalse

        var sdkFunction: String? {
            switch self {
            case .empty: nil
            case .assertTrue: "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
            case .assertFalse: "$s6XCTest14XCTAssertFalse__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
            }
        }
    }

    init?(_ type: ClassDeclSyntax, path: String, module: String) {
        guard type.attributes.isEmpty, let parent = PrivateTestHelperSyntax.safeSuperclass(type),
              ["XCTestCase", "XCTest.XCTestCase"].contains(parent) else { return nil }
        self.path = path
        qualifiedName = module + "." + type.name.text
        var methods: [String: Body] = [:]
        for member in type.memberBlock.members {
            guard let method = member.decl.as(FunctionDeclSyntax.self), method.attributes.isEmpty, method.modifiers.isEmpty,
                  method.name.text.hasPrefix("test"), method.signature.parameterClause.parameters.isEmpty,
                  method.signature.effectSpecifiers == nil, method.signature.returnClause == nil,
                  let statements = method.body?.statements else { return nil }
            let name = method.name.text
            if statements.isEmpty { methods[name] = .empty }
            else {
                guard statements.count == 1, let call = statements.first?.item.as(FunctionCallExprSyntax.self),
                      call.arguments.count == 1, let argument = call.arguments.first, argument.label == nil,
                      argument.expression.is(BooleanLiteralExprSyntax.self), call.trailingClosure == nil,
                      call.additionalTrailingClosures.isEmpty,
                      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return nil }
                switch callee.baseName.text {
                case "XCTAssertTrue": methods[name] = .assertTrue
                case "XCTAssertFalse": methods[name] = .assertFalse
                default: return nil
                }
            }
        }
        self.methods = methods
    }

    /// An old empty method needs no compiler binding. A literal assertion
    /// needs the same overload proof used to certify the linked head method.
    func coversExecution(of previous: Self) -> Bool {
        qualifiedName == previous.qualifiedName && previous.methods.allSatisfy { name, old in
            old == .empty || methods[name] == old
        }
    }

    /// A verified head binary describes one revision. For changed case files
    /// its execution bound can only cover the base if the historical syntax
    /// satisfies the same contracts. Unknown history applies to that process.
    static func historicallyUnverifiedTargets(in head: XcodeTestGraph, base: [String: SwiftSourceSnapshot],
                                              touching paths: Set<String>) -> Set<String> {
        guard let graph = head.dependencies, let verified = graph.swiftTestingFactoriesByTarget else { return [] }
        var result = Set<String>()
        for target in head.targets where verified[target.name] != nil && !target.sourceFiles.isDisjoint(with: paths) {
            guard let module = head.modules[target.name], let cases = graph.swiftTestingCasesByTarget?[target.name] else {
                result.insert(target.name)
                continue
            }
            for current in cases where paths.contains(current.path) {
                let previous = base[module + ":" + current.path]?.xctestDiscoveryCases?.filter { $0.qualifiedName == current.qualifiedName }
                guard let previous, previous.count == 1, current.coversExecution(of: previous[0]) else {
                    result.insert(target.name)
                    break
                }
            }
        }
        return result
    }

    /// Resolve the class, initializer and test identities with the compiler's
    /// demangler. Keep the actual linked thunk for subsequent SIL verification.
    func linkedAssertions(in table: ArraySlice<[Substring]>, names: [String: String]) -> Set<LinkedTestingRecords.Assertion>? {
        if table.first == ["baseMethods", "0x0"] { return table.count == 1 ? [] : nil }
        let implementations = table.filter { $0.first == "imp" }
        guard let size = table.first(where: { $0.first == "count" }), size.count == 2,
              Int(size[1]) == implementations.count, !implementations.isEmpty else { return nil }
        let prefix = "@objc " + qualifiedName + "."
        let initializers = ["init()", "init(invocation: __C.NSInvocation?)", "init(selector: ObjectiveC.Selector)"]
        let inherited = Set(initializers.map { prefix + $0 + " -> " + qualifiedName })
        var assertions = Set<LinkedTestingRecords.Assertion>()
        for imp in implementations {
            guard let raw = imp.last, raw.hasPrefix("_$s"), let identity = names[String(raw)] else { return nil }
            if inherited.contains(identity) { continue }
            let suffix = "() -> ()"
            guard identity.hasPrefix(prefix), identity.hasSuffix(suffix),
                  let body = methods[String(identity.dropFirst(prefix.count).dropLast(suffix.count))] else { return nil }
            if let sdk = body.sdkFunction { assertions.insert(.init(thunk: String(raw.dropFirst()), sdk: sdk)) }
        }
        return assertions
    }
}
