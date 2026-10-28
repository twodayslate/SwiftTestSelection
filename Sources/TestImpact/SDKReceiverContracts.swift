// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Receiver-origin contracts, not effect-purity contracts. Never infer these
/// from module ownership or return type. Unknown SDK entry points fall back.
/// Generic operations additionally require compiler-captured substitutions;
/// protocol dispatch on an arbitrary user type is not a trusted primitive.
enum SDKReceiverContracts {
    static let objectBridge = "$ss27_bridgeAnythingToObjectiveCyyXlxlF"
    static let unreachableNil = "@unreachable-literal-nil"
    // Concrete SDK values and XCTest assertions. Explicit callback references stay in the caller graph.
    static let primitives: Set<String> = [
        // Importer-synthesized Equatable for the SDK's CGFloat-backed velocity.
        // This exact witness uses the SDK RawValue implementation; it is not a
        // contract for arbitrary RawRepresentable equality or formatting.
        "$sSo19XCUIGestureVelocityaSQSCSQ2eeoiySbx_xtFZTW",
        // Concrete String/Character storage operations cannot dispatch a project conformance.
        "$sSS12makeIteratorSS0B0VyF", "$sSS8IteratorV4nextSJSgyF", "$sSS6appendyySJF", "$sSSySSSJcfC",
        "$sSS1poiyS2S_SStFZ", "$sSS9repeating5countS2S_SitcfC", "$sSS5countSivg", "$sSS7isEmptySbvg", "$sSS10lowercasedSSyF",
        "$sSJ38_builtinExtendedGraphemeClusterLiteral17utf8CodeUnitCount7isASCIISJBp_BwBi1_tcfC",
        "$sSJ8isNumberSbvg", "$sSdySdSgSscfC",
        // These split defaults construct only the standard Int/Bool argument values.
        "$sSlsSQ7ElementRpzrlE5split9separator9maxSplits25omittingEmptySubsequencesSay11SubSequenceQzGAB_SiSbtFfA0_",
        "$sSlsSQ7ElementRpzrlE5split9separator9maxSplits25omittingEmptySubsequencesSay11SubSequenceQzGAB_SiSbtFfA1_",
        // XCTest's default messages are constant closures; payload type parameters are unused.
        "$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlFfA1_",
        "$s6XCTest14XCTAssertEqual__8accuracy_4file4lineyxyKXK_xyKXKxSSyXKs12StaticStringVSutSFRzlFfA2_",
        "$s6XCTest9XCTUnwrap__4file4linexxSgyKXK_SSyXKs12StaticStringVSutKlFfA0_",
        "$s6XCTest7XCTFail_4file4lineySS_s12StaticStringVSutF",
        "$s6XCTest20XCTAssertGreaterThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlFfA1_",
        "$s6XCTest17XCTAssertLessThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlFfA1_",
        "$s6XCTest24XCTAssertLessThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlFfA1_",
        "$s6XCTest27XCTAssertGreaterThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlFfA1_",
        // Unwrap also formats thrown errors; receiver proofs audit its input producers.
        "$s6XCTest9XCTUnwrap__4file4linexxSgyKXK_SSyXKs12StaticStringVSutKlF",
        // Concrete CoreGraphics value operations and the SDK keyboard-key value wrapper.
        "$sSo6CGRectV12CoreGraphicsE4minXAC7CGFloatVvg", "$sSo6CGRectV12CoreGraphicsE4minYAC7CGFloatVvg",
        "$sSo6CGRectV12CoreGraphicsE4maxXAC7CGFloatVvg", "$sSo6CGRectV12CoreGraphicsE4maxYAC7CGFloatVvg",
        "$sSo6CGRectV12CoreGraphicsE7isEmptySbvg", "$sSo6CGRectV12CoreGraphicsE12intersectionyA2BF",
        "$sSo6CGRectV12CoreGraphicsE8containsySbABF", "$sSo6CGRectV12CoreGraphicsE10intersectsySbABF", "$sSo15XCUIKeyboardKeya8rawValueSSvg",
        "$sSo21UIContentSizeCategorya8rawValueSSvg",
        // Wrap an existing continuation handle without resuming it or producing
        // its payload. Resumption and runtime producers remain separate edges.
        "$ss34_createCheckedThrowingContinuationyScCyxs5Error_pGSccyxsAB_pGnlF",
        // Finalize already initialized array storage without invoking element protocols.
        "$ss27_finalizeUninitializedArrayySayxGABnlF",
        // Allocate empty array storage; element initialization remains in the caller.
        "$ss27_allocateUninitializedArrayySayxG_BptBwlF",
        // Foundation.URL._bridgeToObjectiveC() -> __C.NSURL
        "$s10Foundation3URLV19_bridgeToObjectiveCSo5NSURLCyF",
        // Foundation.URL.init(string: __shared Swift.String) -> Foundation.URL?
        "$s10Foundation3URLV6stringACSgSSh_tcfC",
        // XCTest.XCTAssertTrue(_: @autoclosure () throws -> Swift.Bool, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF",
        // default argument 1 of XCTest.XCTAssertTrue(_: @autoclosure () throws -> Swift.Bool, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutFfA0_",
        // XCTest.XCTAssertFalse(_: @autoclosure () throws -> Swift.Bool, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest14XCTAssertFalse__4file4lineySbyKXK_SSyXKs12StaticStringVSutF",
        // default argument 1 of XCTest.XCTAssertFalse(_: @autoclosure () throws -> Swift.Bool, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest14XCTAssertFalse__4file4lineySbyKXK_SSyXKs12StaticStringVSutFfA0_",
        // XCTest.XCTAssertNotNil(_: @autoclosure () throws -> Any?, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest15XCTAssertNotNil__4file4lineyypSgyKXK_SSyXKs12StaticStringVSutF",
        // default argument 1 of XCTest.XCTAssertNotNil(_: @autoclosure () throws -> Any?, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest15XCTAssertNotNil__4file4lineyypSgyKXK_SSyXKs12StaticStringVSutFfA0_",
        // (extension in Foundation):Swift.String._bridgeToObjectiveC() -> __C.NSString
        "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF",
        // static (extension in Foundation):Swift.String._unconditionallyBridgeFromObjectiveC(__C.NSString?) -> Swift.String
        "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ",
        // Swift.String.init(stringInterpolation: Swift.DefaultStringInterpolation) -> Swift.String
        "$sSS19stringInterpolationSSs013DefaultStringB0V_tcfC",
        // Swift.String.init(_builtinStringLiteral: Builtin.RawPointer, utf8CodeUnitCount: Builtin.Word, isASCII: Builtin.Int1) -> Swift.String
        "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC",
        // static Swift.String.== infix(Swift.String, Swift.String) -> Swift.Bool
        "$sSS2eeoiySbSS_SStFZ",
        // static Swift.String.+= infix(inout Swift.String, Swift.String) -> ()
        "$sSS2peoiyySSz_SStFZ",
        // static Swift.MainActor.shared.getter : Swift.MainActor
        "$sScM6sharedScMvgZ",
        // (extension in Foundation):__C.NSPredicate.init(format: __shared Swift.String, _: Swift.CVarArg...) -> __C.NSPredicate
        "$sSo11NSPredicateC10FoundationE6format_ABSSh_s7CVarArg_pdtcfC",
        // (extension in CoreGraphics):__C.CGRect.isInfinite.getter : Swift.Bool
        "$sSo6CGRectV12CoreGraphicsE10isInfiniteSbvg",
        // (extension in CoreGraphics):__C.CGRect.midX.getter : CoreGraphics.CGFloat
        "$sSo6CGRectV12CoreGraphicsE4midXAC7CGFloatVvg",
        // (extension in CoreGraphics):__C.CGRect.midY.getter : CoreGraphics.CGFloat
        "$sSo6CGRectV12CoreGraphicsE4midYAC7CGFloatVvg",
        // (extension in CoreGraphics):__C.CGRect.width.getter : CoreGraphics.CGFloat
        "$sSo6CGRectV12CoreGraphicsE5widthAC7CGFloatVvg",
        // (extension in CoreGraphics):__C.CGRect.height.getter : CoreGraphics.CGFloat
        "$sSo6CGRectV12CoreGraphicsE6heightAC7CGFloatVvg",
        // (extension in CoreGraphics):__C.CGRect.isNull.getter : Swift.Bool
        "$sSo6CGRectV12CoreGraphicsE6isNullSbvg",
        // (extension in CoreGraphics):__C.CGRect.contains(__C.CGPoint) -> Swift.Bool
        "$sSo6CGRectV12CoreGraphicsE8containsySbSo7CGPointVF",
        // checked @objc completion handler block implementation for @escaping @callee_unowned @convention(block) @Sendable (@unowned __C.NSError?) -> () with result type ()
        "$sSo7NSErrorCSgIeyBhy_ytTZ_",
        // Swift._bridgeAnyObjectToAny(Swift.AnyObject?) -> Any
        "$ss018_bridgeAnyObjectToB0yypyXlSgF",
        // implicit closure #1 () -> Swift.String in default argument 1 of Swift.precondition(_: @autoclosure () -> Swift.Bool, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$ss12precondition__4file4lineySbyXK_SSyXKs12StaticStringVSutFfA0_SSycfu_",
        // Swift._assertionFailure(_: Swift.StaticString, _: Swift.StaticString, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never
        "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_A2HSus6UInt32VtF",
        // Swift._assertionFailure(_: Swift.StaticString, _: Swift.String, file: Swift.StaticString, line: Swift.UInt, flags: Swift.UInt32) -> Swift.Never
        "$ss17_assertionFailure__4file4line5flagss5NeverOs12StaticStringV_SSAHSus6UInt32VtF",
        // Swift.DefaultStringInterpolation.appendLiteral(Swift.String) -> ()
        "$ss26DefaultStringInterpolationV13appendLiteralyySSF",
        // Swift.DefaultStringInterpolation.init(literalCapacity: Swift.Int, interpolationCount: Swift.Int) -> Swift.DefaultStringInterpolation
        "$ss26DefaultStringInterpolationV15literalCapacity18interpolationCountABSi_SitcfC",
    ]

    // Bridge or transform supplied values with explicit substituted-type restrictions.
    static let transport: Set<String> = [
        // Bridge/append only the verified substituted value or receiver types below.
        "$sSa10FoundationE36_unconditionallyBridgeFromObjectiveCySayxGSo7NSArrayCSgFZ",
        "$sSa2peoiyySayxGz_ABtFZ", "$sSa5countSivg", "$sSayxSicig",
        // (extension in Foundation):Swift.Dictionary._bridgeToObjectiveC() -> __C.NSDictionary
        "$sSD10FoundationE19_bridgeToObjectiveCSo12NSDictionaryCyF",
        // static (extension in Foundation):Swift.Dictionary._unconditionallyBridgeFromObjectiveC(__C.NSDictionary?) -> [A : B]
        "$sSD10FoundationE36_unconditionallyBridgeFromObjectiveCySDyxq_GSo12NSDictionaryCSgFZ",
        // (extension in Foundation):Swift.Array._bridgeToObjectiveC() -> __C.NSArray
        "$sSa10FoundationE19_bridgeToObjectiveCSo7NSArrayCyF",
        // Swift.Optional.map<A, B where A1: Swift.Error, B1: ~Swift.Copyable>((A) throws(A1) -> B1) throws(A1) -> B1?
        "$sSq3mapyqd_0_Sgqd_0_xqd__YKXEqd__YKs5ErrorRd__Ri_d_0_r0_lF",
        // Swift._bridgeAnythingToObjectiveC<A>(A) -> Swift.AnyObject
        "$ss27_bridgeAnythingToObjectiveCyyXlxlF",
    ]

    // Standard collection traversal: only builtin concrete collections may supply the witnesses.
    static let collections: Set<String> = [
        "$sSTsE5first5where7ElementQzSgSbADKXE_tKF",
        "$sSTsE3max2by7ElementQzSgSbAD_ADtKXE_tKF",
        "$sSTsE10compactMapySayqd__Gqd__Sg7ElementQzKXEKlF",
        "$sSmsE6filteryxSb7ElementQzqd__YKXEqd__YKs5ErrorRd__lF", "$sSmsE6filteryxSb7ElementQzKXEKF",
        // Collection.first forwards a stored element; its collection must be builtin.
        "$sSlsE5first7ElementQzSgvg",
        // (extension in Swift):Swift.BidirectionalCollection< where A.Element == Swift.String>.joined(separator: Swift.String) -> Swift.String
        "$sSKsSS7ElementRtzrlE6joined9separatorS2S_tF",
        // (extension in Swift):Swift.Sequence.allSatisfy((A.Element) throws -> Swift.Bool) throws -> Swift.Bool
        "$sSTsE10allSatisfyyS2b7ElementQzKXEKF",
        // (extension in Swift):Swift.Collection.map<A, B where B1: Swift.Error>((A.Element) throws(B1) -> A1) throws(B1) -> [A1]
        "$sSlsE3mapySayqd__Gqd__7ElementQzqd_0_YKXEqd_0_YKs5ErrorRd_0_r0_lF",
        // (extension in Swift):Swift.Collection.isEmpty.getter : Swift.Bool
        "$sSlsE7isEmptySbvg",
        // (extension in Swift):Swift.Collection< where A.Iterator == Swift.IndexingIterator<A>>.makeIterator() -> Swift.IndexingIterator<A>
        "$sSlss16IndexingIteratorVyxG0B0RtzrlE04makeB0ACyF",
        // Swift.IndexingIterator.next() -> A.Element?
        "$ss16IndexingIteratorV4next7ElementQzSgyF",
    ]

    // Value protocols and bridging: all substituted types must have closed builtin value semantics.
    static let values: Set<String> = [
        // These operations invoke protocols; custom substituted conformances remain unproven.
        "$sSSySSxcs25LosslessStringConvertibleRzlufC", "$sSS10describingSSx_tclufC",
        "$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC",
        "$sSy10FoundationE8containsySbqd__SyRd__lF",
        "$sSy10FoundationE32localizedCaseInsensitiveContainsySbqd__SyRd__lF",
        "$sSlsSQ7ElementRpzrlE5split9separator9maxSplits25omittingEmptySubsequencesSay11SubSequenceQzGAB_SiSbtF",
        "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF", "$ss26DefaultStringInterpolationV06appendC0yyxlF",
        "$ss17FixedWidthIntegerPsEyxSgSScfC", "$ss3maxyxx_xtSLRzlF", "$ss3minyxx_xtSLRzlF", "$ss3absyxxSLRzs13SignedNumericRzlF",
        "$s6XCTest14XCTAssertEqual__8accuracy_4file4lineyxyKXK_xyKXKxSSyXKs12StaticStringVSutSFRzlF",
        "$s6XCTest20XCTAssertGreaterThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
        "$s6XCTest17XCTAssertLessThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
        "$s6XCTest24XCTAssertLessThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
        "$s6XCTest27XCTAssertGreaterThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
        // XCTest.XCTAssertEqual<A where A: Swift.Equatable>(_: @autoclosure () throws -> A, _: @autoclosure () throws -> A, _: @autoclosure () -> Swift.String, file: Swift.StaticString, line: Swift.UInt) -> ()
        "$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlF",
        // Swift.Dictionary.subscript.setter : (A) -> B?
        "$sSDyq_Sgxcis",
        // Swift.DefaultStringInterpolation.appendInterpolation<A where A: Swift.CustomStringConvertible, A: Swift.TextOutputStreamable>(A) -> ()
        "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF",
    ]

    static let declarations = primitives.union(transport).union(collections).union(values)
    static let generic = transport.union(collections).union(values)
    /// These SDK bodies can format a caught Error through runtime protocols.
    /// Default-message closures do not evaluate or catch input expressions.
    static let errorFormatting = Set(declarations.filter {
        $0.hasPrefix("$s6XCTest") && ($0.contains("XCTAssert") || $0.contains("XCTUnwrap")) && $0.hasSuffix("F")
    })


    // Printed type names are accepted only alongside the caller's source import,
    // alias and declaration checks. These sets must not grow to arbitrary SDK types.
    static let valueTypes: Set<String> = ["String", "Substring", "Character", "Bool", "Int", "UInt", "Int64", "UInt64", "Int32", "UInt32", "Int16", "UInt16", "Int8", "UInt8", "Float", "Double", "CGFloat", "Never", "StaticString", "Array", "Dictionary", "Set", "Optional", "IndexingIterator", "ReversedCollection", "Range", "ClosedRange", "DefaultStringInterpolation", "XCTWaiter.Result", "XCUIElement.ElementType"]
    static let receiverTypes: Set<String> = ["XCUIApplication", "XCUIElement", "XCTestExpectation", "XCTAttachment", "XCUIScreenshot", "NSPredicate", "XCTNSPredicateExpectation", "Any", "AnyObject"]
    private static let collectionRoots: Set<String> = ["Array", "Dictionary", "String", "Substring", "Set", "Range", "ClosedRange"]

    private struct Nominal {
        var name: String
        var arguments: [Nominal] = []
        func scalar(in names: Set<String>) -> Bool { arguments.isEmpty && names.contains(name) }
    }
    private typealias Types = (names: Set<String>, first: String, parameters: [Nominal])
    private static let integers: Set<String> = ["Int", "UInt", "Int64", "UInt64", "Int32", "UInt32", "Int16", "UInt16", "Int8", "UInt8"]
    private static let floating: Set<String> = ["Float", "Double", "CGFloat"]
    private static let numbers = integers.union(floating)
    private static let comparableScalars = numbers.union(["String", "Substring", "Character"])
    private static let equatableScalars = comparableScalars.union(["Bool", "XCTWaiter.Result", "XCUIElement.ElementType"])
    // These types already have the standard-library printing witnesses. An
    // unconstrained print can prefer TextOutputStreamable over description, so
    // an Int's existing CustomStringConvertible alone is insufficient there.
    private static let textOutputScalars: Set<String> = ["String", "Substring", "Character", "Float", "Double"]
    private static let descriptionScalars = integers.union(textOutputScalars).union(["Bool"])

    /// Keep nesting and argument roles: a flat set of builtin names cannot prove
    /// a conditional conformance (or distinguish Optional<Int> from Int).
    private static func parsedTypes(_ arguments: String) -> Types? {
        guard arguments.utf8.count <= 4096 else { return nil }
        let chars = Array(arguments)
        var index = 0, names = Set<String>()
        func spaces() { while index < chars.count && chars[index] == " " { index += 1 } }
        func take(_ c: Character) -> Bool {
            spaces()
            guard index < chars.count && chars[index] == c else { return false }
            index += 1; return true
        }
        func type(_ depth: Int) -> Nominal? {
            guard depth < 32 else { return nil }
            spaces()
            var result: Nominal
            if take("[") {
                guard let first = type(depth + 1) else { return nil }
                if take(":") {
                    guard let second = type(depth + 1) else { return nil }
                    result = Nominal(name: "Dictionary", arguments: [first, second])
                } else { result = Nominal(name: "Array", arguments: [first]) }
                guard take("]") else { return nil }
            } else {
                let start = index
                while index < chars.count && (chars[index].isLetter || chars[index].isNumber || chars[index] == "_" || chars[index] == ".") { index += 1 }
                guard index > start else { return nil }
                result = Nominal(name: String(chars[start..<index]))
                if take("<") {
                    guard let first = type(depth + 1) else { return nil }
                    result.arguments.append(first)
                    while take(",") {
                        guard let next = type(depth + 1) else { return nil }
                        result.arguments.append(next)
                    }
                    guard take(">") else { return nil }
                }
            }
            names.insert(result.name)
            if take("?") {
                names.insert("Optional")
                result = Nominal(name: "Optional", arguments: [result])
            }
            return result
        }
        guard let first = type(0) else { return nil }
        var parameters = [first]
        while take(",") {
            guard let next = type(0) else { return nil }
            parameters.append(next)
        }
        spaces()
        return index == chars.count ? (names, first.name, parameters) : nil
    }

    // Only the SDK's existing Equatable/Hashable conformances, including their
    // recursively checked conditions. No retroactive conformance is inferred.
    private static func closedEquality(_ type: Nominal) -> Bool {
        if type.scalar(in: equatableScalars) { return true }
        switch type.name {
        case "Optional", "Array", "Set":
            return type.arguments.count == 1 && type.arguments.allSatisfy(closedEquality)
        case "Dictionary":
            return type.arguments.count == 2 && type.arguments.allSatisfy(closedEquality)
        case "Range", "ClosedRange":
            return type.arguments.count == 1 && type.arguments[0].scalar(in: comparableScalars)
        default: return false
        }
    }

    private static func closedBridge(_ type: Nominal) -> Bool {
        let scalars = integers.union(["String", "Bool", "Float", "Double"])
        let objects = receiverTypes.subtracting(["Any", "AnyObject"])
        if type.scalar(in: scalars.union(objects)) { return true }
        switch type.name {
        case "Array": return type.arguments.count == 1 && type.arguments.allSatisfy(closedBridge)
        case "Set": return type.arguments.count == 1 && type.arguments.allSatisfy { closedEquality($0) && closedBridge($0) }
        case "Dictionary": return type.arguments.count == 2 && closedEquality(type.arguments[0]) && type.arguments.allSatisfy(closedBridge)
        default: return false
        }
    }

    private static func valueWitnesses(_ types: [Nominal], symbol: String) -> Bool {
        guard !types.isEmpty else { return false }
        func one(_ names: Set<String>) -> Bool { types.count == 1 && types[0].scalar(in: names) }
        switch symbol {
        case "$sSS10describingSSx_tclufC", "$ss26DefaultStringInterpolationV06appendC0yyxlF",
             "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzs20TextOutputStreamableRzlF":
            return one(textOutputScalars)
        case "$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC",
             "$ss26DefaultStringInterpolationV06appendC0yyxs06CustomB11ConvertibleRzlF":
            return one(descriptionScalars)
        case "$sSSySSxcs25LosslessStringConvertibleRzlufC":
            return one(integers.union(["String", "Bool", "Float", "Double"]))
        case "$ss17FixedWidthIntegerPsEyxSgSScfC": return one(integers)
        case "$ss3absyxxSLRzs13SignedNumericRzlF": return one(numbers.subtracting(integers.filter { $0.hasPrefix("U") }))
        case "$ss3maxyxx_xtSLRzlF", "$ss3minyxx_xtSLRzlF": return one(comparableScalars)
        case "$s6XCTest20XCTAssertGreaterThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
             "$s6XCTest17XCTAssertLessThan___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
             "$s6XCTest24XCTAssertLessThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF",
             "$s6XCTest27XCTAssertGreaterThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF":
            return one(comparableScalars.intersection(textOutputScalars))
        case "$s6XCTest14XCTAssertEqual__8accuracy_4file4lineyxyKXK_xyKXKxSSyXKs12StaticStringVSutSFRzlF": return one(floating.intersection(textOutputScalars))
        case "$sSy10FoundationE8containsySbqd__SyRd__lF", "$sSy10FoundationE32localizedCaseInsensitiveContainsySbqd__SyRd__lF":
            return types.count == 2 && types.allSatisfy { $0.scalar(in: ["String", "Substring"]) }
        case "$sSlsSQ7ElementRpzrlE5split9separator9maxSplits25omittingEmptySubsequencesSay11SubSequenceQzGAB_SiSbtF":
            guard types.count == 1 else { return false }
            let type = types[0]
            return type.scalar(in: ["String", "Substring"]) ||
                (type.name == "Array" && type.arguments.count == 1 && type.arguments.allSatisfy(closedEquality))
        case "$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlF":
            // Failure diagnostics also print the values through runtime protocols.
            return one(equatableScalars.intersection(textOutputScalars))
        case "$sSDyq_Sgxcis": return types.count == 2 && types.allSatisfy(closedEquality)
        default: return false
        }
    }

    static func typeNames(_ arguments: String) -> Set<String>? { parsedTypes(arguments)?.names }

    private static func relevantTypes(_ arguments: String, for symbol: String) -> Types? {
        guard collections.contains(symbol) else { return parsedTypes(arguments) }
        // Collection traversal invokes only the concrete collection's witnesses.
        // Callback result/error substitutions may be closures or project values;
        // their producers remain explicit edges in the caller graph.
        var depth = 0, first = "", previous: Character?
        var dictionary = false
        for c in arguments {
            if c == "," && depth == 0 { break }
            if c == ":" && depth == 1 && first.first == "[" { dictionary = true }
            if c == "<" || c == "[" || c == "(" { depth += 1 }
            if (c == ">" && previous != "-") || c == "]" || c == ")" { depth -= 1 }
            guard depth >= 0 else { return nil }
            first.append(c); previous = c
        }
        first = first.trimmingCharacters(in: .whitespaces)
        guard depth == 0, !first.isEmpty else { return nil }
        let root: String
        if first.first == "[", first.last == "]" { root = dictionary ? "Dictionary" : "Array" }
        else {
            root = String(first.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
            let rest = first.dropFirst(root.count).trimmingCharacters(in: .whitespaces)
            guard rest.isEmpty || (rest.first == "<" && rest.last == ">" && rest.count > 2) else { return nil }
        }
        guard collectionRoots.contains(root) else { return nil }
        if ["Range", "ClosedRange"].contains(root) { return parsedTypes(first) }
        // Stored elements may themselves be closures, existentials, or project
        // values. Standard storage iteration never invokes their conformances.
        return ([root], root, [Nominal(name: root)])
    }

    static func requiredTypeIdentities(_ arguments: String, for symbol: String) -> Set<String>? {
        if symbol == objectBridge && arguments == unreachableNil { return [] }
        guard let types = relevantTypes(arguments, for: symbol) else { return nil }
        if collections.contains(symbol), !["Range", "ClosedRange"].contains(types.first) { return [types.first] }
        return types.names
    }

    static func allows(_ arguments: String, for symbol: String) -> Bool {
        guard generic.contains(symbol) else { return false }
        if symbol == objectBridge && arguments == unreachableNil { return true }
        guard let types = relevantTypes(arguments, for: symbol) else { return false }
        let names = types.names
        if values.contains(symbol) { return valueWitnesses(types.parameters, symbol: symbol) }
        if collections.contains(symbol) {
            guard collectionRoots.contains(types.first) else { return false }
            // Only built-in conformances to the protocol used by this operation.
            if symbol == "$sSmsE6filteryxSb7ElementQzqd__YKXEqd__YKs5ErrorRd__lF" || symbol == "$sSmsE6filteryxSb7ElementQzKXEKF" ||
               symbol == "$sSKsSS7ElementRtzrlE6joined9separatorS2S_tF" {
                return ["Array", "String", "Substring"].contains(types.first)
            }
            if ["Range", "ClosedRange"].contains(types.first) {
                let bound = types.parameters.first?.arguments ?? []
                return bound.count == 1 && bound[0].scalar(in: integers)
            }
            return true
        }
        guard names.isSubset(of: valueTypes.union(receiverTypes)) else { return false }
        // Bridging can invoke a retroactive _ObjectiveCBridgeable witness even
        // for a nominally builtin wrapper such as Optional. Require a known
        // bridging conformance recursively, not just a whitelist of type names.
        if symbol == objectBridge || symbol.contains("BridgeFromObjectiveC") || symbol.contains("bridgeToObjectiveC") {
            return types.parameters.allSatisfy(closedBridge)
        }
        return transport.contains(symbol)
    }
}
