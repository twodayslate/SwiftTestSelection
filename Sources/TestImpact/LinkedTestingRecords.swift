// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import CoreFoundation
import Foundation

/// Inventory the final images, after the linker has selected archive members.
/// Unknown dylibs, image layouts and stripped registration symbols leave
/// discovery open. A source import list cannot establish these facts.
enum LinkedTestingRecords {
    // Version 4 accounts for XCTest case construction and execution before Swift Testing discovery.
    static let inventoryVersion = 4

    struct Assertion: Hashable {
        let method: String
        let sdk: String

        func verified(in graph: DependencyGraph) -> Bool {
            // The source is a single call with a boolean literal. Confirm the SDK
            // overload and the literal autoclosure, including when a project shadows the name.
            let literal = method + "SbyKXEfu_"
            guard graph.functions[method]?.compilerReferences == [sdk, sdk + "fA0_", literal],
                  let closure = graph.functions[literal] else { return false }
            return closure.compilerReferences == [] && closure.hasModeledDiscoveryInstructions == true && closure.mayDestroyValue == false
        }
    }

    struct Inventory: Equatable {
        var records: Set<String> = []
        var assertions: Set<Assertion> = []

        mutating func formUnion(_ other: Self) {
            records.formUnion(other.records)
            assertions.formUnion(other.assertions)
        }
    }

    static func capture(testRun: URL?, products: URL, plainCases: [String: [XCTestDiscoveryCase]] = [:]) -> [String: Inventory]? {
        let run: URL
        if let testRun { run = testRun }
        else {
            let runs = try? FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "xctestrun" }
            guard runs?.count == 1, let first = runs?.first else { return nil }
            run = first
        }
        guard let data = try? Data(contentsOf: run),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let configurations = plist["TestConfigurations"] as? [[String: Any]], !configurations.isEmpty else { return nil }
        let root = run.deletingLastPathComponent()
        func product(_ path: String) -> URL? {
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, !parts[1].split(separator: "/").contains("..") else { return nil }
            guard parts[0] == "__TESTROOT__" else { return nil }
            return root.appendingPathComponent(String(parts[1]))
        }
        // A test target runs its bundle in its own host process. Repeated plan
        // configurations may load different images for the same target.
        var inspected: [String: [URL: Inventory]] = [:]
        func processRecords(_ target: [String: Any], name: String) -> Inventory? {
            for key in ["TestingEnvironmentVariables", "EnvironmentVariables"] {
                if let environment = target[key] as? [String: String], let injection = environment["DYLD_INSERT_LIBRARIES"],
                   injection.split(separator: ":").contains(where: {
                       !$0.hasPrefix("/usr/lib/") && !$0.hasPrefix("__SIMRUNTIMEROOT__/usr/lib/")
                   }) { return nil }
            }
            // Application startup can load plug-ins before discovery. The host's
            // static load commands cannot establish which registrations will run.
            if let path = target["TestHostPath"] as? String, !platformTestAgents.contains(path) { return nil }
            guard target["IsAppHostedTestBundle"] as? Bool != true, target["UseDestinationArtifacts"] as? Bool != true,
                  let path = target["TestBundlePath"] as? String, let bundle = product(path),
                  let image = executableWithoutPrincipalClass(in: bundle) else { return nil }
            if let cached = inspected[name]?[image] { return cached }
            guard let symbols = recordsInImage(image, plainCases: plainCases[name] ?? []) else { return nil }
            inspected[name, default: [:]][image] = symbols
            return symbols
        }
        var recordsByTarget: [String: Inventory] = [:], incomplete = Set<String>()
        for configuration in configurations {
            if let enabled = configuration["IsEnabled"] as? NSNumber,
               CFGetTypeID(enabled) == CFBooleanGetTypeID(), !enabled.boolValue { continue }
            guard let targets = configuration["TestTargets"] as? [[String: Any]], !targets.isEmpty else { return nil }
            for target in targets {
                guard let name = target["BlueprintName"] as? String, !name.isEmpty else { return nil }
                guard !incomplete.contains(name) else { continue }
                if let records = processRecords(target, name: name) { recordsByTarget[name, default: Inventory()].formUnion(records) }
                else {
                    incomplete.insert(name)
                    recordsByTarget.removeValue(forKey: name)
                }
            }
        }
        return recordsByTarget
    }

    private static func executableWithoutPrincipalClass(in bundle: URL) -> URL? {
        guard let image = Bundle(url: bundle)?.executableURL else { return nil }
        let directory = image.deletingLastPathComponent()
        let metadataDirectory: URL
        if directory.path == bundle.path {
            metadataDirectory = bundle
        } else if directory.path == bundle.appendingPathComponent("Contents/MacOS").path {
            metadataDirectory = bundle.appendingPathComponent("Contents")
        } else { return nil }
        // xctest instantiates the principal class before discovery. Check the raw
        // destination variants as well as the metadata visible on the capture host.
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: metadataDirectory.path),
              files.contains("Info.plist") else { return nil }
        for file in files where file == "Info.plist" || (file.hasPrefix("Info-") && file.hasSuffix(".plist")) {
            guard let data = try? Data(contentsOf: metadataDirectory.appendingPathComponent(file)),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                  info["CFBundleExecutable"] as? String == image.lastPathComponent,
                  !info.keys.contains(where: { $0 == "NSPrincipalClass" || $0.hasPrefix("NSPrincipalClass-") || $0.hasPrefix("NSPrincipalClass~") })
            else { return nil }
        }
        return image
    }

    private static let platformTestAgents = Set(["MacOSX", "iPhoneSimulator", "AppleTVSimulator",
        "WatchSimulator", "XRSimulator"].map { "__PLATFORMS__/\($0).platform/Developer/Library/Xcode/Agents/xctest" })

    private static let testingLibraries = Set(["Testing", "XCTest"].flatMap {
        ["@rpath/\($0).framework/\($0)", "@rpath/\($0).framework/Versions/A/\($0)"]
    } + ["@rpath/libXCTestSwiftSupport.dylib"])

    static func recordsInImage(_ image: URL, plainCases: [XCTestDiscoveryCase] = []) -> Inventory? {
        let directory = image.deletingLastPathComponent()
        // Support the 64-bit little-endian thin image ABI. Do not silently
        // inspect only the host slice of a universal test product.
        guard let file = try? FileHandle(forReadingFrom: image) else { return nil }
        defer { try? file.close() }
        guard (try? file.read(upToCount: 4)) == Data([0xcf, 0xfa, 0xed, 0xfe]),
              let loads = try? CommandRunner.run("xcrun", ["otool", "-L", image.path], at: directory).text,
              let layout = try? CommandRunner.run("xcrun", ["otool", "-l", image.path], at: directory).text,
              layout.contains("cmd LC_SEGMENT_64") else { return nil }
        let lines = loads.split(separator: "\n")
        guard lines.first == Substring(image.path + ":"), lines.count > 1 else { return nil }
        for line in lines.dropFirst() {
            guard let end = line.range(of: " (compatibility version ") else { return nil }
            let path = line[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/System/Library/") || path.hasPrefix("/usr/lib/") ||
                    testingLibraries.contains(path) else { return nil }
        }

        let fields = layout.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace) }
        // A bundle initializer or Objective-C +load method can load another
        // image before the platform agent begins Swift Testing discovery.
        var classCount: UInt64 = 0
        for (index, field) in fields.enumerated() {
            if field == ["cmd", "LC_ROUTINES_64"] || field == ["sectname", "__objc_nlclslist"] ||
                field == ["sectname", "__objc_nlcatlist"] { return nil }
            // A category can replace a framework discovery hook on an existing class.
            if field.first == "sectname", field.last?.hasPrefix("__objc_catlist") == true { return nil }
            if field.first == "sectname", field.last?.hasPrefix("__objc_classlist") == true {
                guard field.last == "__objc_classlist" else { return nil }
                guard classCount == 0, index + 3 < fields.count, let size = hexField(fields[index + 3], name: "size"),
                      size % 8 == 0 else { return nil }
                classCount = size / 8
            }
            // Mach-O section type (low byte): S_MOD_INIT_FUNC_POINTERS or S_INIT_FUNC_OFFSETS.
            if let flags = hexField(field, name: "flags"), [0x09, 0x16].contains(flags & 0xff) { return nil }
        }
        var inventory = Inventory()
        if classCount > 0 {
            guard let metadata = try? CommandRunner.run("xcrun", ["otool", "-ov", image.path], at: directory).text,
                  verifiedClasses(in: metadata, count: classCount, plainCases: plainCases, inventory: &inventory) else { return nil }
        }
        let sections = fields.indices.filter { fields[$0] == ["sectname", "__swift5_tests"] }
        if sections.isEmpty { return inventory }
        guard sections.count == 1, let index = sections.first, index + 3 < fields.count,
              fields[index + 1].count == 2, fields[index + 1][0] == "segname",
              let start = hexField(fields[index + 2], name: "addr"),
              let size = hexField(fields[index + 3], name: "size"), size % 32 == 0,
              let symbols = try? CommandRunner.run("xcrun", ["nm", "-n", "-s", String(fields[index + 1][1]),
                "__swift5_tests", image.path], at: directory).text else { return nil }
        for line in symbols.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[2].hasPrefix("_$s"), let address = UInt64(parts[0], radix: 16),
                  address >= start, address - start == UInt64(inventory.records.count) * 32,
                  inventory.records.insert(String(parts[2].dropFirst())).inserted else { return nil }
        }
        // Each SDK record has two UInt32 fields and three pointer-sized fields.
        // Checking the section extent detects missing symbols even if nm succeeds.
        return UInt64(inventory.records.count) == size / 32 ? inventory : nil
    }

    // XCTest calls class hooks and constructs case instances while discovering suites.
    // Inspect every linked class, including archive members without project sources.
    private static func verifiedClasses(in metadata: String, count: UInt64, plainCases: [XCTestDiscoveryCase], inventory: inout Inventory) -> Bool {
        let sections = metadata.components(separatedBy: "\nContents of ").filter {
            $0.prefix(while: { $0 != "\n" }).hasSuffix(",__objc_classlist) section")
        }
        guard sections.count == 1 else { return false }
        let lines = sections[0].split(separator: "\n").dropFirst()
        let classes = lines.split(whereSeparator: { $0.first?.isHexDigit == true })
        guard classes.count == count else { return false }
        let evidence = Dictionary(grouping: plainCases, by: \.runtimeName)
        return classes.allSatisfy { record in
            let sides = record.split(separator: "Meta Class")
            guard sides.count == 2 else { return false }
            let metaclass = sides[1].map { $0.split(whereSeparator: \.isWhitespace) }
            guard metaclass.filter({ $0.first == "baseMethods" }) == [["baseMethods", "0x0"]] else { return false }

            let instance = sides[0].map { $0.split(whereSeparator: \.isWhitespace) }
            guard let parent = instance.first(where: { $0.first == "superclass" }),
                  parent.count == 3, parent[1] == "0x0" else { return false }
            switch parent[2] {
            case "_OBJC_CLASS_$_NSObject", "_OBJC_CLASS_$__TtCs12_SwiftObject":
                return true
            case "_OBJC_CLASS_$_XCTestCase":
                // Even a synthesized init can run arbitrary stored-property initializers.
                // Only accept a linked Swift case whose source proves default construction.
                let header = instance.prefix { $0.first != "baseMethods" }
                guard let name = header.first(where: { $0.first == "name" }), name.count == 3,
                      instance.contains(["ivars", "0x0"]) else { return false }
                guard header.contains(where: { $0.first == "data" && $0.suffix(2) == ["Swift", "class"] }),
                      let candidates = evidence[String(name[2])], candidates.count == 1, let source = candidates.first,
                      let methods = instance.firstIndex(where: { $0.first == "baseMethods" }),
                      let end = instance[methods...].firstIndex(where: { $0.first == "baseProtocols" }),
                      let assertions = source.linkedAssertions(in: instance[methods..<end]) else { return false }
                inventory.assertions.formUnion(assertions)
                return true
            default:
                return false
            }
        }
    }

    private static func hexField(_ fields: [Substring], name: Substring) -> UInt64? {
        guard fields.count == 2, fields[0] == name, fields[1].hasPrefix("0x") else { return nil }
        return UInt64(fields[1].dropFirst(2), radix: 16)
    }
}
