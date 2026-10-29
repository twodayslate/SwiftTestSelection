// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A static SDK method reference does not prove the receiver's runtime class.
/// Factories and setup may supply an imported subclass with effectful overrides.
/// Check the consumer dependency closure, including lifecycle roots, before
/// granting an SDK effect contract. This does not impose purity on test setup.
struct SDKReceiverOrigins {
    // One immutable graph per instance. Shared helper chains often have the
    // same consumer roots; cache both successful and failed closure checks.
    private struct Proof { var blocker: String? }
    private var results: [Set<String>: Proof] = [:]
    private var effects = ExternalHelperEffects()
    // Public immutable constants from the SDK's gesture, keyboard and content-size headers.
    // Exact names only: a similarly named project global is not an SDK contract.
    private static let sdkConstants: Set<String> = {
        var result = Set(["Default", "Fast", "Slow"].map { "global:XCUIGestureVelocity" + $0 })
        let keys = ["Delete", "Return", "Enter", "Tab", "Space", "Escape", "UpArrow", "DownArrow", "LeftArrow", "RightArrow",
            "ForwardDelete", "Home", "End", "PageUp", "PageDown", "Clear", "Help", "CapsLock", "Shift", "Control", "Option", "Command",
            "RightShift", "RightControl", "RightOption", "RightCommand"]
        result.formUnion(keys.map { "global:XCUIKeyboardKey" + $0 })
        result.formUnion((1...19).map { "global:XCUIKeyboardKeyF" + String($0) })
        let sizes = ["Unspecified", "ExtraSmall", "Small", "Medium", "Large", "ExtraLarge", "ExtraExtraLarge", "ExtraExtraExtraLarge",
            "AccessibilityMedium", "AccessibilityLarge", "AccessibilityExtraLarge", "AccessibilityExtraExtraLarge", "AccessibilityExtraExtraExtraLarge"]
        result.formUnion(sizes.map { "global:UIContentSizeCategory" + $0 })
        return result
    }()

    mutating func proves(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> Bool {
        blocker(tests: tests, current: current, graph: graph) == nil
    }

    mutating func blocker(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> String? {
        if let cached = results[tests] { return cached.blocker }
        let result = inspect(tests: tests, current: current, graph: graph)
        results[tests] = Proof(blocker: result)
        return result
    }

    private mutating func inspect(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> String? {
        let sources = Dictionary(grouping: current.sources.map { (String($0.key.prefix { $0 != ":" }), $0.value) }, by: { $0.0 })
        let physicalModules = Set(sources.filter { !$0.value.isEmpty && $0.value.allSatisfy { $0.1.receiverPhysicalLocations == true } }.keys)
        func units(_ node: FunctionNode) -> [SourceUnit] {
            node.regions.flatMap { region -> [SourceUnit] in
                let source = current.sources[node.module + ":" + region.path]?.units ?? []
                let candidates = source.filter {
                    $0.kind != "import" && $0.region.startLine <= region.startLine && $0.region.endLine >= region.endLine
                }
                guard let size = candidates.map({ $0.region.endLine - $0.region.startLine }).min() else {
                    // Synthesized bodies can span a header and several member
                    // declarations (field initializers or raw-value enum cases).
                    // Audit the union of all overlapping syntax: every source
                    // use still has to satisfy the compiled overload contract.
                    return source.filter { $0.kind != "import" &&
                        $0.region.startLine <= region.endLine && $0.region.endLine >= region.startLine }
                }
                return candidates.filter { $0.region.endLine - $0.region.startLine == size }
            }
        }
        func finalTestClass(_ owner: String, module: String) -> Bool {
            let snapshots = (sources[module] ?? []).map { $0.1 }
            let declarations = snapshots.flatMap(\.units).filter { $0.kind == "type" && $0.scope == owner }
            let finality = snapshots.compactMap { $0.classFinality?[owner] }
            return declarations.count == 1 && !finality.isEmpty && finality.allSatisfy { $0 } &&
                PrivateTestHelperIsolation.safeHierarchy(owner, module: module, sources: snapshots)
        }
        func metatypeBlocker(_ node: FunctionNode, owners: [SourceUnit]) -> String? {
            guard let origins = node.receiverTypeOrigins, node.receiverGenericCalls != nil else { return "Missing or unrecognized receiver type evidence; recapture sealed SIL" }
            if !origins.isEmpty, owners.contains(where: { $0.receiverImportsSupported == false }) {
                let imports = Set(owners.flatMap { $0.receiverUnsupportedImports ?? [] }).sorted()
                return "Receiver type identities are unproven with unsupported source imports" +
                    (imports.isEmpty ? " (missing import details; refresh source evidence)" : ": " + imports.joined(separator: ", "))
            }
            let sdkLiterals = SDKReceiverContracts.literalTypes
            func localValueType(_ name: String) -> Bool {
                // A captured value type cannot be an SDK receiver subclass. Do
                // not let a local SDK namesake authenticate a printed signature.
                guard !sdkLiterals.contains(name) else { return false }
                let declarations = (sources[node.module] ?? []).flatMap { $0.1.units }.filter {
                    $0.kind == "type" && $0.scope == name
                }
                return declarations.count == 1 && declarations[0].receiverValueType == true &&
                    (sources[node.module] ?? []).allSatisfy { $0.1.typeAliases != nil &&
                        !$0.1.typeAliases!.contains(where: { $0.split(separator: ".").last.map(String.init) == name }) }
            }
            for origin in origins.sorted() {
                if origin.hasPrefix("cast:") {
                    let target = String(origin.dropFirst(5))
                    guard let names = SDKReceiverContracts.typeNames(target), names.isSubset(of: SDKReceiverContracts.valueTypes),
                          !owners.isEmpty, owners.allSatisfy({ $0.receiverImportsSupported == true }),
                          (sources[node.module] ?? []).allSatisfy({ snapshot in
                              let roots = Set(names.map { String($0.split(separator: ".")[0]) })
                              return snapshot.1.typeAliases != nil && !snapshot.1.typeAliases!.contains(where: { roots.contains(SDKTestHelperSyntax.canonicalName(String($0.split(separator: ".").last ?? ""))) }) &&
                                  !snapshot.1.units.contains(where: { $0.kind == "type" && roots.contains(SDKTestHelperSyntax.canonicalName(String($0.scope.split(separator: ".").last ?? ""))) })
                          }) else { return "Unproven receiver cast: " + target }
                    continue
                }
                // Swift enum cases can be formed without calling a constructor.
                // A foreign @objc enum named Int must not acquire Swift.Int's
                // argument identity merely because SIL prints the same name.
                if origin.hasPrefix("enum:") {
                    let enumOwner: String
                    if ["enum:Optional.some", "enum:Optional.none"].contains(origin) { enumOwner = "Optional" }
                    else if ["enum:XCTWaiter.Result.completed", "enum:XCTWaiter.Result.timedOut", "enum:XCTWaiter.Result.incorrectOrder", "enum:XCTWaiter.Result.invertedFulfillment", "enum:XCTWaiter.Result.interrupted"].contains(origin) { enumOwner = "XCTWaiter" }
                    else if ["enum:XCTAttachment.Lifetime.keepAlways", "enum:XCTAttachment.Lifetime.deleteOnSuccess"].contains(origin) { enumOwner = "XCTAttachment" }
                    else if ["enum:UIDeviceOrientation.unknown", "enum:UIDeviceOrientation.portrait", "enum:UIDeviceOrientation.portraitUpsideDown", "enum:UIDeviceOrientation.landscapeLeft", "enum:UIDeviceOrientation.landscapeRight", "enum:UIDeviceOrientation.faceUp", "enum:UIDeviceOrientation.faceDown"].contains(origin) { enumOwner = "UIDeviceOrientation" }
                    else if ["enum:XCUIApplication.State.unknown", "enum:XCUIApplication.State.notRunning", "enum:XCUIApplication.State.runningBackgroundSuspended", "enum:XCUIApplication.State.runningBackground", "enum:XCUIApplication.State.runningForeground"].contains(origin) { enumOwner = "XCUIApplication" }
                    else if origin.hasPrefix("enum:XCUIElement.ElementType.") { enumOwner = "XCUIElement" }
                    else {
                        let type = origin.dropFirst("enum:".count).split(separator: ".").dropLast().joined(separator: ".")
                        guard localValueType(type), !owners.isEmpty, owners.allSatisfy({ $0.receiverImportsSupported == true }) else {
                            return "Unproven enum argument identity: " + origin
                        }
                        continue
                    }
                    guard !owners.isEmpty, owners.allSatisfy({ $0.receiverImportsSupported == true }),
                          (sources[node.module] ?? []).allSatisfy({ $0.1.typeAliases != nil &&
                            !$0.1.typeAliases!.contains(where: { $0.split(separator: ".").last.map(String.init) == enumOwner }) &&
                            !$0.1.units.contains(where: { $0.kind == "type" && $0.scope.split(separator: ".").last.map(String.init) == enumOwner }) }) else {
                        return "Unproven enum argument identity: " + origin
                    }
                    continue
                }
                let parts = origin.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return "Unproven dynamic metatype: " + origin }
                let type = parts[1]
                if !owners.isEmpty, owners.allSatisfy({ $0.receiverImportsSupported == true }),
                   finalTestClass(type, module: node.module) { continue }
                var names = Set(type.split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "." }.map(String.init))
                names.formUnion(names.compactMap { $0.split(separator: ".").first.map(String.init) })
                let sdkNames = names.intersection(sdkLiterals)
                guard parts[0] == "literal" || (parts[0] == "input" && localValueType(type)),
                      !names.isEmpty, names.subtracting(sdkLiterals).allSatisfy(localValueType), !owners.isEmpty,
                      owners.allSatisfy({ $0.receiverImportsSupported == true }),
                      (sources[node.module] ?? []).allSatisfy({ $0.1.helperNamesUnshadowed == true && $0.1.typeAliases != nil &&
                          !$0.1.typeAliases!.contains(where: { $0.split(separator: ".").last.map(String.init).map(SDKTestHelperSyntax.canonicalName).map(names.contains) == true }) &&
                          !$0.1.units.contains(where: { $0.kind == "type" && $0.scope.split(separator: ".").last.map(String.init).map(SDKTestHelperSyntax.canonicalName).map(sdkNames.contains) == true }) }) else {
                    return "Unproven receiver metatype: " + origin
                }
            }
            return nil
        }
        func stateBlocker(_ node: FunctionNode) -> String? {
            if node.uncertainties.contains("Raw pointer operation") { return "Raw pointer operation" }
            guard !node.uncertainties.isDisjoint(with: ["Shared state access", "Global state access"]) || node.stateAccesses?.isEmpty == false else { return nil }
            guard let accesses = node.stateAccesses, !accesses.isEmpty else { return "Missing shared-state access evidence; recapture sealed SIL" }
            let snapshots = (sources[node.module] ?? []).map { $0.1 }
            for access in accesses.sorted() {
                // Exact SDK constants, never arbitrary scalar-looking globals.
                if Self.sdkConstants.contains(access) { continue }
                guard access.hasPrefix("field:"), !snapshots.isEmpty,
                      snapshots.allSatisfy({ $0.literalStoredProperties != nil && $0.typeAliases != nil &&
                          !$0.typeAliases!.contains(where: { $0.split(separator: ".").last == "StringLiteralType" }) }) else { return "Unproven shared receiver storage: " + access }
                let field = SDKTestHelperSyntax.canonicalName(String(access.dropFirst(6)))
                let proofs = snapshots.compactMap { $0.literalStoredProperties![field] }
                if !proofs.isEmpty, proofs.allSatisfy({ $0 }) { continue }
                let booleans = snapshots.compactMap { $0.booleanStoredProperties?[field] }
                guard snapshots.allSatisfy({ $0.booleanStoredProperties != nil && $0.booleanLiteralNamesUnshadowed == true }),
                      !booleans.isEmpty, booleans.allSatisfy({ $0 }) else { return "Unproven shared receiver storage: " + access }
            }
            return nil
        }
        // Test binding includes ancestor allocation thunks as lifecycle roots.
        // A final concrete test is allocated once; ancestor initializer bodies
        // run on that instance, not on an arbitrary ancestor metatype. Omit only
        // those synthetic roots, keeping their bodies and any actual call edges.
        // An explicitly invoked ancestor allocator is still visited normally.
        func roots(_ test: String) -> Set<String> {
            let roots = graph.tests[test] ?? []
            let parts = test.split(separator: "/").map(String.init)
            guard parts.count >= 3, let module = current.modules[parts[0]] else { return roots }
            let snapshots = (sources[module] ?? []).map { $0.1 }
            let concrete = parts[1]
            let declarations = snapshots.flatMap(\.units).filter { $0.kind == "type" && $0.scope == concrete }
            let finality = snapshots.compactMap { $0.classFinality?[concrete] }
            guard declarations.count == 1, !finality.isEmpty, finality.allSatisfy({ $0 }),
                  PrivateTestHelperIsolation.safeHierarchy(concrete, module: module, sources: snapshots) else { return roots }
            let classes = Dictionary(grouping: snapshots.flatMap { ($0.helperSafeClasses ?? [:]).map { ($0.key, $0.value) } }, by: { $0.0 })
            var ancestors = Set<String>(), owner = concrete
            while let parents = classes[module + "." + owner], parents.count == 1 {
                let parent = parents[0].1
                guard ancestors.insert(parent).inserted else { break }
                owner = parent
            }
            return roots.filter { id in
                guard let node = graph.functions[id], node.module == module,
                      let owner = ancestors.first(where: { node.name.hasPrefix($0 + ".__allocating_init(") }) else { return true }
                let initializer = node.name.replacingOccurrences(of: owner + ".__allocating_init(", with: owner + ".init(")
                return !roots.contains { graph.functions[$0]?.module == module && graph.functions[$0]?.name == initializer }
            }
        }
        // Check all explicit input producers conservatively: the graph retains
        // escaped callbacks but does not assign them individual SDK argument roles.
        // Cache successful checks within this immutable receiver proof.
        var nonthrowingProducers = Set<String>()
        func errorEvidenceDetail(_ node: FunctionNode) -> String {
            if node.uncertainties.contains("Indirect function invocation"), node.receiverIndirectErrorEffects == nil {
                return "; missing indirect-call error evidence; regenerate the graph from sealed SIL"
            }
            let reasons = (node.receiverErrorEffects ?? []).union(node.receiverIndirectErrorEffects ?? []).sorted()
            return reasons.isEmpty ? "" : "; " + reasons.prefix(2).joined(separator: "; ")
        }
        func errorFormattingBlocker(_ inputs: Set<String>) -> String? {
            var pending = inputs, visited = Set<String>()
            while !pending.isEmpty {
                let batch = pending.subtracting(visited).subtracting(nonthrowingProducers)
                pending = []
                visited.formUnion(batch)
                let sdk = effects.sdkReceiverDeclarations(batch)
                for id in batch.subtracting(sdk).sorted() {
                    guard let node = graph.functions[id], let errors = node.receiverErrorEffects,
                          let direct = node.compilerReferences else {
                        return "Missing error-flow evidence for XCTest input producer " + id + "; regenerate the graph from sealed SIL"
                    }
                    guard errors.isEmpty, (!node.uncertainties.contains("Indirect function invocation") || node.receiverIndirectErrorEffects?.isEmpty == true) else {
                        return "Unproven XCTest error formatting from input producer " + node.module + "." + node.name + errorEvidenceDetail(node)
                    }
                    // A Swift throw from any dynamic/indirect call must propagate
                    // through this body to reach the SDK's catch. Explicit callees
                    // also cover callback bodies handed to known SDK operations.
                    pending.formUnion(direct)
                }
            }
            nonthrowingProducers.formUnion(visited)
            return nil
        }
        var pending = Set(tests.flatMap { roots($0) }), visited = Set<String>()
        var external = Set<String>()
        while !pending.isEmpty {
            let batch = pending.subtracting(visited)
            pending = []
            visited.formUnion(batch)
            // SDK implementations are trusted primitives. Expanding their
            // generic protocol dispatch invents unrelated producer paths; their
            // explicit callback references already remain in the calling body.
            let sdk = effects.sdkReceiverDeclarations(batch)
            for id in batch.subtracting(sdk).sorted() {
                guard let node = graph.functions[id] else { external.insert(id); continue }
                let owned = node.id.hasSuffix("@emitted:" + node.module) || node.regions.contains {
                    current.sources[node.module + ":" + $0.path] != nil
                }
                guard owned else { external.insert(id); continue }
                // SIL locations may point at another physical source file. Never
                // authenticate a body through that file's imports, labels or types
                // unless the entire module's source inventory has physical locations.
                guard physicalModules.contains(node.module) else {
                    return "Source locations are remapped or lack physical-location evidence in module " + node.module + "; refresh source evidence"
                }
                let owners = units(node)
                if let reason = metatypeBlocker(node, owners: owners) { return "\(reason) in \(node.module).\(node.name)" }
                if let reason = stateBlocker(node) { return "\(reason) in \(node.module).\(node.name)" }
                // A saved project body with missing provenance is not an opaque
                // external leaf, even if its declaration has a void result.
                guard let direct = node.compilerReferences else { return "Missing compiler references for \(node.module).\(node.name)" }
                if !direct.isDisjoint(with: SDKReceiverContracts.errorFormatting) {
                    guard let errors = node.receiverErrorEffects else {
                        return "Missing XCTest error-flow evidence; regenerate the graph from sealed SIL"
                    }
                    guard !errors.contains("throwing callback parameter"),
                          (!node.uncertainties.contains("Indirect function invocation") || node.receiverIndirectErrorEffects?.isEmpty == true) else {
                        return "Unproven XCTest error formatting from an opaque callback in " + node.module + "." + node.name + errorEvidenceDetail(node)
                    }
                    if let reason = errorFormattingBlocker(direct) { return reason }
                }
                var checked = node
                // A final source-bound XCTest class has no descendant override.
                // The generic dispatch graph may carry a broad warning caused by
                // unrelated constructors whose ancestry is unknown. Clear only
                // that exact warning on this class's allocating initializer;
                // missing callees and every other uncertainty remain checked.
                for uncertainty in node.uncertainties where uncertainty.hasPrefix("Unresolved project dispatch: ") && uncertainty.hasSuffix(".init (incomplete override ancestry)") {
                    let owner = String(uncertainty.dropFirst("Unresolved project dispatch: ".count).dropLast(".init (incomplete override ancestry)".count))
                    let snapshots = (sources[node.module] ?? []).map { $0.1 }
                    let declarations = snapshots.flatMap(\.units).filter { $0.kind == "type" && $0.scope == owner }
                    let finality = snapshots.compactMap { $0.classFinality?[owner] }
                    if node.name.hasPrefix(owner + ".__allocating_init("), declarations.count == 1,
                       !finality.isEmpty, finality.allSatisfy({ $0 }),
                       node.resolvedDynamicDeclarations.contains(owner + ".init"),
                       PrivateTestHelperIsolation.safeHierarchy(owner, module: node.module, sources: snapshots) {
                        checked.uncertainties.remove(uncertainty)
                    }
                }
                var shapes: [String: Set<[String]>]?
                if !owners.isEmpty, owners.allSatisfy({ $0.receiverCallShapes != nil && $0.receiverImportsSupported == true }) {
                    shapes = [:]
                    for owner in owners {
                        for (name, calls) in owner.receiverCallShapes! { shapes![name, default: []].formUnion(calls) }
                    }
                }
                let generic = direct.intersection(SDKReceiverContracts.generic)
                if !generic.isEmpty {
                    guard let calls = node.receiverGenericCalls else { return "Missing generic receiver-call evidence; recapture sealed SIL" }
                    for symbol in generic.sorted() {
                        let arguments = calls.filter { $0.hasPrefix(symbol + "\t") }.map { String($0.dropFirst(symbol.count + 1)) }
                        guard !arguments.isEmpty, arguments.allSatisfy({ SDKReceiverContracts.allows($0, for: symbol) }),
                              !owners.isEmpty, owners.allSatisfy({ $0.receiverImportsSupported == true }),
                              arguments.allSatisfy({ argument in
                                  guard let names = SDKReceiverContracts.requiredTypeIdentities(argument, for: symbol) else { return false }
                                  let roots = Set(names.map { String($0.split(separator: ".")[0]) })
                                  return (sources[node.module] ?? []).allSatisfy {
                                      $0.1.typeAliases != nil && !$0.1.typeAliases!.contains(where: { roots.contains(SDKTestHelperSyntax.canonicalName(String($0.split(separator: ".").last ?? ""))) }) &&
                                      !$0.1.units.contains(where: { $0.kind == "type" && roots.contains(SDKTestHelperSyntax.canonicalName(String($0.scope.split(separator: ".").last ?? ""))) })
                                  }
                              }) else { return "Unproven generic receiver contract for " + symbol + " with substitutions " + arguments.sorted().joined(separator: "; ") }
                    }
                }
                var paired: [String: Set<[String]>] = [:]
                if let sites = node.dynamicCallSites, !owners.isEmpty,
                   owners.allSatisfy({ $0.receiverCallSites != nil && $0.receiverImportsSupported == true }) {
                    for call in node.dynamicCallSignatures ?? [] {
                        guard let declaration = call.split(separator: " ").dropFirst().first?.split(separator: "!").first,
                              ExternalHelperEffects.tracksReceiverCallSite(String(declaration)) else { continue }
                        let prefix = call + "\t"
                        let points = sites.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                        var labels = Set<[String]>()
                        var complete = !points.isEmpty
                        let name = call.split(separator: " ").dropFirst().first?.split(separator: "!").first?.split(separator: ".").last.map(String.init)
                        for point in points {
                            let matches = Set(owners.compactMap { $0.receiverCallSites?[point] })
                            guard matches.count == 1, let match = matches.first, match.first == name else { complete = false; break }
                            labels.insert(Array(match.dropFirst()))
                        }
                        if complete { paired[call] = labels }
                    }
                }
                switch ExternalHelperEffects.receiverProof(checked, sourceCallShapes: shapes, pairedCallShapes: paired) {
                case let .success(producers): pending.formUnion(direct.union(producers))
                case let .failure(error): return "\(error) in \(node.module).\(node.name)"
                }
            }
        }
        let unresolved = effects.unprovenReceiverOrigins(external).sorted()
        guard unresolved.isEmpty else {
            return "Missing implementation or SDK origin contract for external producer(s): " + unresolved.prefix(8).joined(separator: ", ") +
                (unresolved.count > 8 ? " (and \(unresolved.count - 8) more)" : "")
        }
        return nil
    }

}
