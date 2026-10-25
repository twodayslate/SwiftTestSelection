# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Extend XcodeUITests with a local package and two implicitly built extensions.

The scheme deliberately lists only the app and tests. Xcode's scheme settings
omit the local package and extensions, although build-for-testing compiles them.
"""
import json
import pathlib
import plistlib
import shutil


def generate(destination):
    destination = pathlib.Path(destination)
    shutil.copytree(pathlib.Path(__file__).resolve().parents[1] / 'XcodeUITests', destination)
    project_path = destination / 'ImpactDemo.xcodeproj/project.pbxproj'
    project = plistlib.loads(project_path.read_bytes())
    objects = project['objects']
    def existing(number):
        return objects[f'{number:024X}']
    def add(isa, **fields):
        key = f'{0x100 + len(objects):024X}'
        objects[key] = dict(isa=isa, **fields)
        return key
    def source(path, phases):
        ref = add('PBXFileReference', lastKnownFileType='sourcecode.swift', path=path, sourceTree='<group>')
        existing(1)['children'].append(ref)
        for phase in phases:
            objects[phase]['files'].append(add('PBXBuildFile', fileRef=ref))
    def phase(isa, **fields):
        return add(isa, buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0, **fields)
    def write(path, text):
        file = destination / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
    package = add('XCLocalSwiftPackageReference', relativePath='LocalCore')
    existing(0x20)['packageReferences'] = [package]
    for target, frameworks in [(0xD, 0xB), (0x1F, 0x1D)]:
        product = add('XCSwiftPackageProductDependency', productName='LocalCore')
        existing(target)['packageProductDependencies'] = [product]
        existing(frameworks)['files'].append(add('PBXBuildFile', productRef=product))
    write('LocalCore/Package.swift', '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LocalCore", platforms: [.iOS(.v16)],
    products: [.library(name: "LocalCore", targets: ["LocalCore"])],
    targets: [.target(name: "LocalCore")])
''')
    write('LocalCore/Sources/LocalCore/Value.swift', 'public func packageValue() -> Int { 40 + 2 }\n')
    write('Shared/ExtensionValue.swift', '''protocol ExtensionValue { func value() -> Int }
struct ConcreteExtensionValue: ExtensionValue {
    func value() -> Int { 20 + 2 }
}
func extensionValue() -> Int { ConcreteExtensionValue().value() }
''')
    embed = phase('PBXCopyFilesBuildPhase', dstPath='', dstSubfolderSpec=13, name='Embed App Extensions')
    existing(0xD)['buildPhases'].append(embed)
    for name, point in [('ShareExtension', 'com.apple.share-services'), ('ActionExtension', 'com.apple.ui-services')]:
        product = add('PBXFileReference', explicitFileType='wrapper.app-extension', includeInIndex=0,
                      path=f'{name}.appex', sourceTree='BUILT_PRODUCTS_DIR')
        existing(2)['children'].append(product)
        settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER=f'org.example.SwiftTestSelection.ImpactDemo.{name}',
                        INFOPLIST_FILE=f'{name}/Info.plist', CODE_SIGN_IDENTITY='-', CODE_SIGN_STYLE='Manual',
                        SKIP_INSTALL='YES', APPLICATION_EXTENSION_API_ONLY='YES', SWIFT_EMIT_LOC_STRINGS='NO')
        config = add('XCBuildConfiguration', name='Debug', buildSettings=settings)
        configs = add('XCConfigurationList', buildConfigurations=[config], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug')
        sources = phase('PBXSourcesBuildPhase')
        frameworks = phase('PBXFrameworksBuildPhase')
        resources = phase('PBXResourcesBuildPhase')
        target = add('PBXNativeTarget', buildConfigurationList=configs, buildPhases=[sources, frameworks, resources],
                     buildRules=[], dependencies=[], name=name, productName=name, productReference=product,
                     productType='com.apple.product-type.app-extension')
        existing(0x20)['targets'].append(target)
        proxy = add('PBXContainerItemProxy', containerPortal=f'{0x20:024X}', proxyType=1, remoteGlobalIDString=target, remoteInfo=name)
        existing(0xD)['dependencies'].append(add('PBXTargetDependency', target=target, targetProxy=proxy))
        objects[embed]['files'].append(add('PBXBuildFile', fileRef=product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}))
        source(f'{name}/Controller.swift', [sources])
        source('Shared/ExtensionValue.swift', [sources])
        write(f'{name}/Controller.swift', 'import UIKit\nfinal class Controller: UIViewController {\n    override func viewDidLoad() { super.viewDidLoad(); title = String(extensionValue()) }\n}\n')
        info = dict(CFBundleDisplayName=name, CFBundleIdentifier='$(PRODUCT_BUNDLE_IDENTIFIER)', CFBundleName='$(PRODUCT_NAME)',
                    CFBundleExecutable='$(EXECUTABLE_NAME)', CFBundlePackageType='XPC!', CFBundleVersion='1', CFBundleShortVersionString='1.0',
                    NSExtension=dict(NSExtensionPointIdentifier=point, NSExtensionPrincipalClass='$(PRODUCT_MODULE_NAME).Controller',
                                     NSExtensionAttributes=dict(NSExtensionActivationRule='TRUEPREDICATE')))
        write(f'{name}/Info.plist', plistlib.dumps(info).decode())
    # The same physical source is compiled in both extensions and the unit target.
    source('Shared/ExtensionValue.swift', [f'{0x1C:024X}'])
    unit = destination / 'UnitTests/ProductionTests.swift'
    unit.write_text(unit.read_text().replace('import XCTest', 'import XCTest\nimport LocalCore').replace(
        '    func testSharing()', '    func testPackage() { XCTAssertEqual(packageValue(), 42) }\n    func testExtension() { XCTAssertEqual(extensionValue(), 22) }\n    func testSharing()'))
    # Exercise compiler dependencies from the app into the package too.
    source('App/PackageBridge.swift', [f'{0xA:024X}'])
    write('App/PackageBridge.swift', 'import LocalCore\nfunc appPackageValue() -> Int { packageValue() }\n')
    # UI inventory remains enabled; explicit feature maps cover the process boundary.
    mappings = json.loads((destination / '.swift-test-selection.json').read_text())
    mappings['ignoredDocumentation'] = ['README.md']
    mappings['features'] += [dict(name='package', sources=['LocalCore/Sources/LocalCore/**'], tests=['CheckoutUITests/SharingUITests/testShareSheet()']),
                             dict(name='extensions', sources=['Shared/**', 'ShareExtension/**', 'ActionExtension/**'], tests=['CheckoutUITests/NotesUITests/testNotes()'])]
    (destination / '.swift-test-selection.json').write_text(json.dumps(mappings, indent=2))
    project_path.write_bytes(plistlib.dumps(project))
