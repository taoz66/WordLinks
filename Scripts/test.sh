#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOCAL_TOOLS="$ROOT/build/AppleDeveloperTools/CommandLineTools"
DEFAULT_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

# Use native `swift test` when the system Xcode already includes macOS 26+ SDK
# and no hybrid toolchain override is requested.
if [[ -d "$DEFAULT_SDK/System/Library/Frameworks/FoundationModels.framework" ]] && \
   [[ -z "${WORDLINKS_USE_HYBRID_TEST:-}" ]]; then
    if [[ "$#" -gt 0 ]]; then
        exec swift test --filter "$1"
    else
        exec swift test
    fi
fi

if [[ ! -d "$LOCAL_TOOLS/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework" ]]; then
    printf 'Running tests requires Xcode 26+ SDK or %s.\n' "$LOCAL_TOOLS" >&2
    exit 1
fi

TASK_XCODE="${WORDLINKS_TEST_DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
TASK_SDK="$LOCAL_TOOLS/SDKs/MacOSX.sdk"
TASK_XCTEST="$TASK_XCODE/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest"
TASK_FRAMEWORKS="$TASK_XCODE/Platforms/MacOSX.platform/Developer/Library/Frameworks"
TASK_PRIVATE_FRAMEWORKS="$TASK_XCODE/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
TASK_LIBRARIES="$TASK_XCODE/Platforms/MacOSX.platform/Developer/usr/lib"

env DEVELOPER_DIR="$TASK_XCODE" SDKROOT="$TASK_SDK" \
    "$LOCAL_TOOLS/usr/bin/swift" build --build-system native --sdk "$TASK_SDK" --build-tests

TASK_BIN_DIR="$(env DEVELOPER_DIR="$TASK_XCODE" SDKROOT="$TASK_SDK" \
    "$LOCAL_TOOLS/usr/bin/swift" build --build-system native --sdk "$TASK_SDK" --show-bin-path)"
BUNDLE="$TASK_BIN_DIR/ReadingToolDailyPackageTests.xctest"

run_xctest() {
    env DEVELOPER_DIR="$TASK_XCODE" \
        DYLD_FRAMEWORK_PATH="$TASK_FRAMEWORKS:$TASK_PRIVATE_FRAMEWORKS" \
        DYLD_LIBRARY_PATH="$TASK_LIBRARIES" \
        "$TASK_XCTEST" "$@" "$BUNDLE"
}

if [[ "$#" -eq 0 ]]; then
    run_xctest
    exit 0
fi

typeset -a ALL_TEST_CLASSES
for file in "$ROOT"/Tests/ReadingToolDailyTests/*Tests.swift(N); do
    ALL_TEST_CLASSES+=("${${file:t}%.swift}")
done

typeset -a TARGETS
for arg in "$@"; do
    for part in ${(s:|:)arg}; do
        for item in ${(s:,:)part}; do
            [[ -z "$item" ]] && continue
            if [[ "$item" == *.* || "$item" == */* ]]; then
                qualified="$item"
                [[ "$qualified" != *.* ]] && qualified="ReadingToolDailyTests.$qualified"
                TARGETS+=("$qualified")
            elif (( ${ALL_TEST_CLASSES[(Ie)$item]} )); then
                TARGETS+=("ReadingToolDailyTests.$item")
            else
                typeset -a matched
                matched=()
                for cls in "${ALL_TEST_CLASSES[@]}"; do
                    if [[ "$cls" == *"$item"* ]]; then
                        matched+=("ReadingToolDailyTests.$cls")
                    fi
                done
                if [[ "${#matched[@]}" -eq 0 ]]; then
                    printf 'No test class matched filter: %s\n' "$item" >&2
                    exit 1
                fi
                TARGETS+=("${matched[@]}")
            fi
        done
    done
done

typeset -U TARGETS
for target in "${TARGETS[@]}"; do
    run_xctest -XCTest "$target"
done
