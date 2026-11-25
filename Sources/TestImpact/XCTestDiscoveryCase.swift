// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftSyntax

/// XCTest can construct and run cases before Swift Testing discovers its entries.
/// Describe the small set of case implementations we can match to the linked image.
struct XCTestDiscoveryCase: Codable, Sendable {
    let runtimeName: String
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

    init?(_ type: ClassDeclSyntax, module: String) {
        guard type.attributes.isEmpty, let parent = PrivateTestHelperSyntax.safeSuperclass(type),
              ["XCTestCase", "XCTest.XCTestCase"].contains(parent) else { return nil }
        let name = type.name.text
        let nominal = "\(module.utf8.count)\(module)\(name.utf8.count)\(name)"
        runtimeName = "_TtC" + nominal
        var methods: [String: Body] = [:]
        for member in type.memberBlock.members {
            guard let method = member.decl.as(FunctionDeclSyntax.self), method.attributes.isEmpty, method.modifiers.isEmpty,
                  method.name.text.hasPrefix("test"), method.signature.parameterClause.parameters.isEmpty,
                  method.signature.effectSpecifiers == nil, method.signature.returnClause == nil,
                  let statements = method.body?.statements else { return nil }
            let symbol = "$s" + nominal + "C" + String(method.name.text.utf8.count) + method.name.text + "yyF"
            if statements.isEmpty { methods[symbol] = .empty }
            else {
                guard statements.count == 1, let call = statements.first?.item.as(FunctionCallExprSyntax.self),
                      call.arguments.count == 1, let argument = call.arguments.first, argument.label == nil,
                      argument.expression.is(BooleanLiteralExprSyntax.self), call.trailingClosure == nil,
                      call.additionalTrailingClosures.isEmpty,
                      let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return nil }
                switch callee.baseName.text {
                case "XCTAssertTrue": methods[symbol] = .assertTrue
                case "XCTAssertFalse": methods[symbol] = .assertFalse
                default: return nil
                }
            }
        }
        self.methods = methods
    }

    /// Match every Objective-C entry point, including members that could come
    /// from extensions. An unfamiliar mangling or table format leaves discovery open.
    func linkedAssertions(in table: ArraySlice<[Substring]>) -> Set<LinkedTestingRecords.Assertion>? {
        if table.first == ["baseMethods", "0x0"] { return table.count == 1 ? [] : nil }
        let implementations = table.filter { $0.first == "imp" }
        guard let size = table.first(where: { $0.first == "count" }), size.count == 2,
              Int(size[1]) == implementations.count, !implementations.isEmpty else { return nil }
        let prefix = "$s" + runtimeName.dropFirst("_TtC".count) + "C"
        let initializers = ["10invocationACSo12NSInvocationCSg_tcfc", "8selectorAC10ObjectiveC8SelectorV_tcfc", "ACycfc"]
        let inherited = Set(initializers.map { prefix + $0 })
        var assertions = Set<LinkedTestingRecords.Assertion>()
        for imp in implementations {
            guard let thunk = imp.last, thunk.hasPrefix("_$s"), thunk.hasSuffix("To") else { return nil }
            let symbol = String(thunk.dropFirst().dropLast(2))
            if inherited.contains(symbol) { continue }
            guard let body = methods[symbol] else { return nil }
            if let sdk = body.sdkFunction { assertions.insert(.init(method: symbol, sdk: sdk)) }
        }
        return assertions
    }
}
