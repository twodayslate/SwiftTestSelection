# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Resource-bearing package, hostless tests, hosted tests and embedded extensions."""
import copy
import importlib.util
import json
import pathlib
import plistlib
import xml.etree.ElementTree as ET


def generate(destination):
    destination = pathlib.Path(destination)
    spec = importlib.util.spec_from_file_location('transitive', pathlib.Path(__file__).resolve().parents[1] / 'XcodeTransitive/generate.py')
    transitive = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(transitive)
    transitive.generate(destination)
    package = destination / 'LocalCore/Package.swift'
    package.write_text(package.read_text().replace('.target(name: "LocalCore")', '.target(name: "LocalCore", resources: [.process("Resources")])'))
    (destination / 'LocalCore/Sources/LocalCore/Empty.swift').write_text('')
    (destination / 'LocalCore/Sources/LocalCore/Excluded.swift').write_text('#if os(Linux)\npublic func linuxOnly() {}\n#endif\n')
    resource = destination / 'LocalCore/Sources/LocalCore/Resources/value.txt'
    resource.parent.mkdir()
    resource.write_text('Resource fixture\n')
    (destination / 'LocalCore/Sources/LocalCore/Runtime.swift').write_text('''import Foundation
private var visits = 0
public func runtimeValue() -> String {
    visits += 1
    let callback = { UUID().uuidString + String(Date().timeIntervalSince1970) }
    return callback() + String(UserDefaults.standard.bool(forKey: "fixture"))
}
public func resourceValue() -> String { Bundle.module.bundleURL.lastPathComponent }
''')
    hosted = destination / 'UnitTests/ProductionTests.swift'
    hosted.write_text(hosted.read_text().replace('    func testSharing()', '    func testHostedRuntime() { XCTAssertFalse(runtimeValue().isEmpty) }\n    func testSharing()'))
    file = destination / 'CoreTests/ValueTests.swift'
    file.parent.mkdir()
    file.write_text('''import XCTest
import LocalCore
final class ValueTests: XCTestCase {
    func testValue() { XCTAssertEqual(packageValue(), 42) }
    func testRuntime() { XCTAssertFalse(runtimeValue().isEmpty) }
    func testResource() { XCTAssertTrue(resourceValue().contains("LocalCore")) }
}
''')
    path = destination / 'ImpactDemo.xcodeproj/project.pbxproj'
    project = plistlib.loads(path.read_bytes()); objects = project['objects']
    def add(isa, **fields):
        key = f'{0x2000 + len(objects):024X}'
        objects[key] = dict(isa=isa, **fields)
        return key
    def old(number): return objects[f'{number:024X}']
    source = add('PBXFileReference', lastKnownFileType='sourcecode.swift', path='CoreTests/ValueTests.swift', sourceTree='<group>')
    old(1)['children'].append(source)
    product = add('PBXFileReference', explicitFileType='wrapper.cfbundle', path='CoreTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
    old(2)['children'].append(product)
    package_product = add('XCSwiftPackageProductDependency', productName='LocalCore')
    sources = add('PBXSourcesBuildPhase', buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0, files=[add('PBXBuildFile', fileRef=source)])
    frameworks = add('PBXFrameworksBuildPhase', buildActionMask=2147483647, runOnlyForDeploymentPostprocessing=0, files=[add('PBXBuildFile', productRef=package_product)])
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='org.example.ImpactDemo.CoreTests',
                    GENERATE_INFOPLIST_FILE='YES', CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual', TEST_HOST='', BUNDLE_LOADER='')
    config = add('XCBuildConfiguration', name='Debug', buildSettings=settings)
    configs = add('XCConfigurationList', buildConfigurations=[config], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
    target = add('PBXNativeTarget', name='CoreTests', productName='CoreTests', productReference=product,
                 productType='com.apple.product-type.bundle.unit-test', buildConfigurationList=configs,
                 buildPhases=[sources, frameworks], buildRules=[], dependencies=[], packageProductDependencies=[package_product])
    old(0x20)['targets'].append(target)
    path.write_bytes(plistlib.dumps(project))
    scheme = destination / 'ImpactDemo.xcodeproj/xcshareddata/xcschemes/ImpactDemo.xcscheme'
    xml = ET.parse(scheme)
    entry = copy.deepcopy(xml.find('./BuildAction/BuildActionEntries/BuildActionEntry'))
    entry.find('BuildableReference').attrib.update(BlueprintIdentifier=target, BlueprintName='CoreTests', BuildableName='CoreTests.xctest')
    xml.find('./BuildAction/BuildActionEntries').append(entry)
    xml.write(scheme, encoding='UTF-8', xml_declaration=True)
    plan = destination / 'AllTests.xctestplan'
    data = json.loads(plan.read_text())
    data['testTargets'].append(dict(target=dict(containerPath='container:ImpactDemo.xcodeproj', identifier=target, name='CoreTests')))
    plan.write_text(json.dumps(data, indent=2))
    policy = destination / '.swift-test-selection.json'
    data = json.loads(policy.read_text())
    data.update(runtimeDependencyPolicy='declared', sourceLocationPolicy='diagnosticLineColumn', testRuntimeBoundaries=[
        dict(target='CoreTests', modules=['CoreTests', 'LocalCore'], rationale='Hostless fixture executes LocalCore and test code only; no application or extension loading.')])
    policy.write_text(json.dumps(data, indent=2))
