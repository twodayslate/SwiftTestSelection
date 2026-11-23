// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import CoreFoundation
import Foundation

/// Inventory the final images, after the linker has selected archive members.
/// Unknown dylibs, image layouts and stripped registration symbols leave
/// discovery open. A source import list cannot establish these facts.
enum LinkedTestingRecords {
    static func capture(testRun: URL?, products: URL) -> [String: Set<String>]? {
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
        var inspected: [URL: Set<String>] = [:], opaqueImages = Set<URL>()
        func records(in image: URL) -> Set<String>? {
            if let cached = inspected[image] { return cached }
            guard !opaqueImages.contains(image), let symbols = recordsInImage(image) else {
                opaqueImages.insert(image)
                return nil
            }
            inspected[image] = symbols
            return symbols
        }
        func processRecords(_ target: [String: Any]) -> Set<String>? {
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
                  let image = Bundle(url: bundle)?.executableURL else { return nil }
            return records(in: image)
        }
        var recordsByTarget: [String: Set<String>] = [:], incomplete = Set<String>()
        for configuration in configurations {
            if let enabled = configuration["IsEnabled"] as? NSNumber,
               CFGetTypeID(enabled) == CFBooleanGetTypeID(), !enabled.boolValue { continue }
            guard let targets = configuration["TestTargets"] as? [[String: Any]], !targets.isEmpty else { return nil }
            for target in targets {
                guard let name = target["BlueprintName"] as? String, !name.isEmpty else { return nil }
                guard !incomplete.contains(name) else { continue }
                if let records = processRecords(target) { recordsByTarget[name, default: []].formUnion(records) }
                else {
                    incomplete.insert(name)
                    recordsByTarget.removeValue(forKey: name)
                }
            }
        }
        return recordsByTarget
    }

    private static let platformTestAgents = Set(["MacOSX", "iPhoneSimulator", "AppleTVSimulator",
        "WatchSimulator", "XRSimulator"].map { "__PLATFORMS__/\($0).platform/Developer/Library/Xcode/Agents/xctest" })

    private static let testingLibraries = Set(["Testing", "XCTest"].flatMap {
        ["@rpath/\($0).framework/\($0)", "@rpath/\($0).framework/Versions/A/\($0)"]
    } + ["@rpath/libXCTestSwiftSupport.dylib"])

    static func recordsInImage(_ image: URL) -> Set<String>? {
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
        for field in fields {
            if field == ["cmd", "LC_ROUTINES_64"] || field == ["sectname", "__objc_nlclslist"] ||
                field == ["sectname", "__objc_nlcatlist"] { return nil }
            // Mach-O section type (low byte): S_MOD_INIT_FUNC_POINTERS or S_INIT_FUNC_OFFSETS.
            if let flags = hexField(field, name: "flags"), [0x09, 0x16].contains(flags & 0xff) { return nil }
        }
        let sections = fields.indices.filter { fields[$0] == ["sectname", "__swift5_tests"] }
        if sections.isEmpty { return [] }
        guard sections.count == 1, let index = sections.first, index + 3 < fields.count,
              fields[index + 1].count == 2, fields[index + 1][0] == "segname",
              let start = hexField(fields[index + 2], name: "addr"),
              let size = hexField(fields[index + 3], name: "size"), size % 32 == 0,
              let symbols = try? CommandRunner.run("xcrun", ["nm", "-n", "-s", String(fields[index + 1][1]),
                "__swift5_tests", image.path], at: directory).text else { return nil }
        var result = Set<String>()
        for line in symbols.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[2].hasPrefix("_$s"), let address = UInt64(parts[0], radix: 16),
                  address >= start, address - start == UInt64(result.count) * 32,
                  result.insert(String(parts[2].dropFirst())).inserted else { return nil }
        }
        // Each SDK record has two UInt32 fields and three pointer-sized fields.
        // Checking the section extent detects missing symbols even if nm succeeds.
        return UInt64(result.count) == size / 32 ? result : nil
    }

    private static func hexField(_ fields: [Substring], name: Substring) -> UInt64? {
        guard fields.count == 2, fields[0] == name, fields[1].hasPrefix("0x") else { return nil }
        return UInt64(fields[1].dropFirst(2), radix: 16)
    }
}
