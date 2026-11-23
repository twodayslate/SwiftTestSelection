// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct SourceRegion: Codable, Hashable, Sendable {
    public var path: String
    public var startLine: Int
    public var endLine: Int

    public init(path: String, startLine: Int, endLine: Int) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
    }

    public func intersects(_ other: SourceRegion) -> Bool {
        path == other.path && startLine <= other.endLine && other.startLine <= endLine
    }
}

public struct FunctionNode: Codable, Sendable, Equatable {
    public var id: String
    public var module: String
    public var name: String
    public var regions: [SourceRegion]
    /// Compiler-demangled nominal context, including the original module of an
    /// extended type. Nil is legacy/missing evidence; empty means unsupported.
    public var nominalTypeContext: String? = nil
    /// Modules contributing compiler evidence, independent of display/definition ownership.
    public var captureModules: Set<String>? = nil
    /// Emitting modules for each dynamic declaration. Empty stubs contribute no
    /// witness ownership; nil means legacy or incomplete provenance.
    public var dynamicDeclarationModules: [String: Set<String>]? = nil
    /// Includes function values passed as callbacks, not only immediate calls.
    public var dependencies: Set<String>
    /// Exact SIL function_ref and key-path function edges (including escaped
    /// callbacks), before broad dispatch candidates are added. Nil means legacy
    /// or unknown edge provenance.
    public var compilerReferences: Set<String>? = nil
    /// A bounded SIL proof of an SDK factory with literal empty traits and no
    /// argument producer: "top-level", "member", or "suite". Nil is unproven.
    public var swiftTestingEmptyFactory: String? = nil
    /// Capture-free argument providers passed to a verified SDK factory with a recognized traits array.
    public var swiftTestingDeferredProviderCount: Int? = nil
    /// Capture-free SDK predicates and their positions in the test factory’s traits array.
    var swiftTestingDeferredConditions: SwiftTestingFactoryProof.Conditions? = nil
    /// Unqualified concrete nominal passed as a literal metatype to the SDK factory.
    public var swiftTestingFactoryType: String? = nil
    /// Concrete payloads stored in the traits array passed to a Swift Testing factory.
    /// Matching trait witnesses are possible runtime edges, never proof that
    /// the complete set of runtime conformances was captured.
    public var swiftTestingExistentialTypes: Set<String>? = nil
    /// Direct callees whose results are stored into the SDK traits array.
    public var swiftTestingTraitProducers: Set<String>? = nil
    /// Concrete requirements invoked by every captured string-formatting call.
    /// Nil leaves discovery conservative for erased calls and older captures.
    public var swiftTestingFormattingRequirements: Set<String>? = nil
    /// Factory references that may execute before Swift Testing filters the tests.
    public var swiftTestingDiscoveryReferences: Set<String>? = nil
    /// Full SIL method reference and formal type for every dynamic call.
    /// Nil means legacy or incomplete evidence; display names lose overloads.
    public var dynamicCallSignatures: Set<String>? = nil
    /// Exact shared-field/global references. Nil means missing capture evidence.
    public var stateAccesses: Set<String>? = nil
    /// Metatypes and enum constructors observed in SIL; nil means missing or unrecognized evidence.
    public var receiverTypeOrigins: Set<String>? = nil
    /// Direct generic calls: symbol + tab + substitutions, or a compiler-proven
    /// unreachable literal-nil bridge marker. Nil also predates cast capture.
    public var receiverGenericCalls: Set<String>? = nil
    /// Supported SDK method signatures followed by tab-separated path, line and UTF-8 column.
    /// Unknown locations are retained explicitly; nil denotes an older capture.
    public var dynamicCallSites: Set<String>? = nil
    /// Observed generic XCTest assertion instructions, keyed by symbol and
    /// substitutions. Diagnostic locations only, never a completeness proof.
    public var assertionFormattingSites: Set<String>? = nil
    /// Swift error propagation and opaque throwing callback inputs. Nil means missing evidence.
    public var receiverErrorEffects: Set<String>? = nil
    /// Indirect invocations without a proven nonthrowing predicate signature.
    /// An empty set proves only error propagation, never callback purity or origin.
    /// Nil denotes legacy/missing evidence.
    public var receiverIndirectErrorEffects: Set<String>? = nil
    /// Every instruction has a modeled discovery effect. Direct calls and ARC
    /// still require their own evidence. Missing proof includes older captures.
    var hasModeledDiscoveryInstructions: Bool? = nil
    /// ARC cleanup can run a project deinitializer without a function reference.
    /// Nil means the capture predates lifetime evidence.
    public var mayDestroyValue: Bool? = nil
    public var uncertainties: Set<String>
    public var resolvedDynamicDeclarations: Set<String> = []
    public var dynamicDeclarations: Set<String>

    /// Combine evidence rather than choosing one imported implementation. Missing
    /// optional proof stays missing; an empty body never establishes purity.
    mutating func mergeEvidence(_ other: FunctionNode) {
        if hasModeledDiscoveryInstructions != other.hasModeledDiscoveryInstructions { hasModeledDiscoveryInstructions = nil }
        if mayDestroyValue != other.mayDestroyValue {
            mayDestroyValue = mayDestroyValue == true || other.mayDestroyValue == true ? true : nil
        }
        dependencies.formUnion(other.dependencies)
        uncertainties.formUnion(other.uncertainties)
        dynamicDeclarations.formUnion(other.dynamicDeclarations)
        resolvedDynamicDeclarations.formUnion(other.resolvedDynamicDeclarations)
        captureModules = (captureModules ?? [module]).union(other.captureModules ?? [other.module])
        if var provenance = dynamicDeclarationModules, let incoming = other.dynamicDeclarationModules {
            provenance.merge(incoming) { $0.union($1) }
            dynamicDeclarationModules = provenance
        } else {
            dynamicDeclarationModules = nil
        }
        func union(_ lhs: Set<String>?, _ rhs: Set<String>?) -> Set<String>? {
            guard let lhs, let rhs else { return nil }
            return lhs.union(rhs)
        }
        compilerReferences = union(compilerReferences, other.compilerReferences)
        swiftTestingExistentialTypes = union(swiftTestingExistentialTypes, other.swiftTestingExistentialTypes)
        swiftTestingTraitProducers = union(swiftTestingTraitProducers, other.swiftTestingTraitProducers)
        swiftTestingFormattingRequirements = union(swiftTestingFormattingRequirements, other.swiftTestingFormattingRequirements)
        swiftTestingDiscoveryReferences = union(swiftTestingDiscoveryReferences, other.swiftTestingDiscoveryReferences)
        if swiftTestingFactoryType != other.swiftTestingFactoryType { swiftTestingFactoryType = nil }
        if swiftTestingEmptyFactory != other.swiftTestingEmptyFactory { swiftTestingEmptyFactory = nil }
        if swiftTestingDeferredProviderCount != other.swiftTestingDeferredProviderCount { swiftTestingDeferredProviderCount = nil }
        if swiftTestingDeferredConditions != other.swiftTestingDeferredConditions { swiftTestingDeferredConditions = nil }
        dynamicCallSignatures = union(dynamicCallSignatures, other.dynamicCallSignatures)
        stateAccesses = union(stateAccesses, other.stateAccesses)
        receiverTypeOrigins = union(receiverTypeOrigins, other.receiverTypeOrigins)
        receiverGenericCalls = union(receiverGenericCalls, other.receiverGenericCalls)
        if let sites = other.assertionFormattingSites {
            assertionFormattingSites = (assertionFormattingSites ?? []).union(sites)
        }
        dynamicCallSites = union(dynamicCallSites, other.dynamicCallSites)
        receiverErrorEffects = union(receiverErrorEffects, other.receiverErrorEffects)
        receiverIndirectErrorEffects = union(receiverIndirectErrorEffects, other.receiverIndirectErrorEffects)
    }

    /// SILOwnership gives emitted adapters a persistent per-module identity but
    /// removes conversion-site locations, which are not source declarations.
    /// Keep that provenance separate from location-based change attribution.
    /// Reading the existing identity also preserves uncertainty in older archives.
    var hasProjectRuntimeContext: Bool {
        !regions.isEmpty || id.hasSuffix("@emitted:" + module)
    }

    var hasOpaqueRuntimeDependency: Bool {
        uncertainties.contains {
            // Imported implementations can call project code even without local
            // debug locations. Known ownership does not close that runtime edge.
            $0.hasPrefix("Imported conformance:") || (hasProjectRuntimeContext || id == SwiftTestingDiscoveryRoots.sharedDiscoveryID) &&
            ($0 == SwiftTestingDiscoveryRoots.unresolvedEffects || $0 == "Indirect function invocation" || $0 == "Raw pointer operation" ||
             $0 == "Global state access" || $0.hasPrefix("Unresolved project dispatch:"))
        }
    }

    public init(
        id: String, module: String, name: String, regions: [SourceRegion] = [],
        dependencies: Set<String> = [], uncertainties: Set<String> = [],
        dynamicDeclarations: Set<String> = []
    ) {
        self.id = id
        self.module = module
        self.name = name
        self.regions = regions
        self.dependencies = dependencies
        self.uncertainties = uncertainties
        self.dynamicDeclarations = dynamicDeclarations
    }
}

public struct DependencyGraph: Codable, Sendable {
    public var schemaVersion = 1
    public var toolchain: String
    public var functions: [String: FunctionNode]
    /// SwiftPM test identifier -> one or more compiler function symbols.
    public var tests: [String: Set<String>]
    public var diagnostics: [String]
    public var testDiagnostics: [String: [String]] = [:]
    /// Module-qualified XCTest class and method to inherited or overriding vtable implementations.
    public var testVTableEntries: [String: Set<String>]? = nil
    /// Runtime witnesses keyed by the suite factory that constructs their trait.
    public var swiftTestingSuiteWitnesses: [String: Set<String>]? = nil
    /// Complete factory inventories independently reached from compiled test registrations.
    public var swiftTestingRegisteredFactories: [String: Set<String>]? = nil
    /// The linked images and captured test registration records agree.
    public var swiftTestingLinkedRecordsVerified: Bool? = nil
    /// Compiler-authenticated class identities from the matching built modules.
    public var compilerClassIdentities: [String: CompilerClassIdentity]? = nil
    /// Imports injected by compiler options, including binary modules absent
    /// from project inventories. Each captured module has an entry, even when
    /// empty. Nil or a missing module entry denotes absent compiler-option proof.
    public var compilerImplicitImports: [String: Set<String>]? = nil

    public init(
        toolchain: String = "", functions: [String: FunctionNode] = [:],
        tests: [String: Set<String>] = [:], diagnostics: [String] = []
    ) {
        self.toolchain = toolchain
        self.functions = functions
        self.tests = tests
        self.diagnostics = diagnostics
    }

    public func dependencyPath(from roots: Set<String>, to destinations: Set<String>) -> [String]? {
        guard !roots.isEmpty, !destinations.isEmpty else { return nil }
        var queue = roots.sorted()
        var visited = roots
        var parents: [String: String] = [:]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            if destinations.contains(current) {
                var path = [current]
                var cursor = current
                while let parent = parents[cursor] {
                    path.append(parent)
                    cursor = parent
                }
                return path.reversed()
            }
            for dependency in (functions[current]?.dependencies ?? []).sorted() {
                if visited.insert(dependency).inserted {
                    parents[dependency] = current
                    queue.append(dependency)
                }
            }
        }
        return nil
    }

    public func dot() -> String {
        func quote(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let roots = tests.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        var lines = ["digraph TestImpact {", "  rankdir=LR;"]
        for node in functions.values.sorted(by: { $0.id < $1.id }) {
            let shape = roots.contains(node.id) ? "box" : "ellipse"
            lines.append("  \(quote(node.id)) [label=\(quote(node.module + "." + node.name)), shape=\(shape)];")
            for dependency in node.dependencies.sorted() where functions[dependency] != nil {
                lines.append("  \(quote(node.id)) -> \(quote(dependency));")
            }
        }
        return (lines + ["}"]).joined(separator: "\n") + "\n"
    }
}

// Centralized regular-expression support for the compiler's textual formats.
// Unknown formats are handled by diagnostics/fallback, not guessed as no impact.
enum Pattern {
    static func groups(_ expression: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: expression),
              let result = groups(regex, in: text) else {
            return nil
        }
        return result
    }

    static func groups(_ regex: NSRegularExpression, in text: String) -> [String]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
