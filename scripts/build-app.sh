#!/usr/bin/env bash
# Builds MeetingScribe.app into dist/.
#
# Set UNIVERSAL=1 for a two-architecture build (what CI ships); the default is a
# native-arch build, which is much faster for local iteration.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MeetingScribe"
DIST="dist"
APP="${DIST}/${APP_NAME}.app"

mkdir -p "${DIST}"

if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  # Build each slice against its own triple and lipo them together, rather than using
  # `swift build --arch a --arch b`. The multi-arch flag routes SwiftPM through XCBuild,
  # which rejects the package's swiftLanguageMode setting and emits duplicate tasks.
  echo "==> Building (release, universal)"
  BINARY="${DIST}/${APP_NAME}.universal"
  SLICES=""
  for TRIPLE in arm64-apple-macosx x86_64-apple-macosx; do
    echo "    ${TRIPLE}"
    swift build -c release --triple "${TRIPLE}"
    SLICE="$(swift build -c release --triple "${TRIPLE}" --show-bin-path)/${APP_NAME}"
    if [[ ! -f "${SLICE}" ]]; then
      echo "error: ${TRIPLE} slice not found at ${SLICE}" >&2
      exit 1
    fi
    SLICES="${SLICES} ${SLICE}"
  done
  lipo -create -output "${BINARY}" ${SLICES}
  lipo -info "${BINARY}"
else
  echo "==> Building (release)"
  swift build -c release
  BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"
fi

if [[ ! -f "${BINARY}" ]]; then
  echo "error: built binary not found at ${BINARY}" >&2
  exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/${APP_NAME}"
rm -f "${DIST}/${APP_NAME}.universal"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc signature. TCC keys its microphone and screen-recording grants off the code
# signature, so an unsigned bundle would re-prompt (or silently fail) on every launch.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --verbose=1 "${APP}"

echo "==> Built ${APP}"
