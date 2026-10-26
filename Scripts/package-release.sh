#!/bin/bash
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# Build a universal macOS CLI. No signing credentials or Rosetta are needed to build.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
version=${1:-dev-$(git rev-parse --short HEAD)}
if [[ ! "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 1
fi
if [[ $(uname -s) != Darwin ]]; then
    echo "Packaging requires macOS with Xcode selected by xcode-select." >&2
    exit 1
fi

build_dir="$root/.build/binary-release"
output_dir="$root/.build/distribution/$version"
mkdir -p "$output_dir"
stage=$(mktemp -d "${TMPDIR:-/tmp}/swift-test-impact-release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/package/bin" "$stage/package/licenses" "$stage/package/Scripts/Experimental"

for architecture in arm64 x86_64; do
    options=(--scratch-path "$build_dir" --configuration release
        --triple "$architecture-apple-macosx13.0" --product swift-test-impact)
    swift build "${options[@]}"
    bin_dir=$(swift build "${options[@]}" --show-bin-path)
    cp "$bin_dir/swift-test-impact" "$stage/$architecture"
done

binary="$stage/package/bin/swift-test-impact"
xcrun lipo -create "$stage/arm64" "$stage/x86_64" -output "$binary"
xcrun lipo "$binary" -verify_arch arm64 x86_64
xcrun strip -S "$binary"
# Ad-hoc signing preserves Apple Silicon execution after lipo/strip. It is not
# Developer ID signing or notarization and requires no secrets on the runner.
codesign --force --sign - "$binary"
codesign --verify --strict "$binary"

# SwiftSyntax/SwiftParser must be linked into the executable, not loaded from
# the build machine. System libraries and Apple's Swift runtime are expected.
while IFS= read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/Library/*) ;;
        *) echo "Unexpected runtime dependency: $dependency" >&2; exit 1 ;;
    esac
done < <(otool -L "$binary" | awk '/compatibility version/ {print $1}')

cp LICENSE "$stage/package/LICENSE"
cp Scripts/capture-build.py "$stage/package/Scripts/"
cp Scripts/Experimental/prepare_sil_capture.py Scripts/Experimental/capture_swiftc.py \
    Scripts/Experimental/capture_inputs.py "$stage/package/Scripts/Experimental/"
cp "$build_dir/checkouts/swift-syntax/LICENSE.txt" "$stage/package/licenses/swift-syntax-LICENSE.txt"
if [[ -f "$build_dir/checkouts/swift-syntax/NOTICE.txt" ]]; then
    cp "$build_dir/checkouts/swift-syntax/NOTICE.txt" "$stage/package/licenses/swift-syntax-NOTICE.txt"
fi
commit=$(git rev-parse HEAD)
syntax_commit=$(git -C "$build_dir/checkouts/swift-syntax" rev-parse HEAD)
{
    printf 'SwiftTestSelection %s\nCommit: %s\n' "$version" "$commit"
    printf 'Source: https://github.com/twodayslate/SwiftTestSelection/tree/%s\n' "$commit"
    printf 'SwiftSyntax source: https://github.com/swiftlang/swift-syntax/tree/%s\n' "$syntax_commit"
    printf 'Platform: macOS 13+, arm64 and x86_64\n\n'
    xcodebuild -version
    swift --version
} > "$stage/package/BUILD-INFO.txt"

archive="swift-test-impact-$version-macos-universal.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$output_dir/$archive" -C "$stage/package" .
(
    cd "$output_dir"
    shasum -a 256 "$archive" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

# Exercise exactly what customers download, outside the checkout/build tree.
mkdir "$stage/extracted"
tar -xzf "$output_dir/$archive" -C "$stage/extracted"
(
    cd "$stage/extracted"
    ./bin/swift-test-impact --help > /dev/null
    if /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
        /usr/bin/arch -x86_64 ./bin/swift-test-impact --help > /dev/null
    else
        echo "Intel slice built and verified; execution requires Intel macOS or Rosetta."
    fi
)
python3 Scripts/integration_test.py --tool "$stage/extracted/bin/swift-test-impact"
python3 Scripts/release_distribution_test.py --distribution "$stage/extracted"
printf '\nRelease files: %s\n' "$output_dir"
