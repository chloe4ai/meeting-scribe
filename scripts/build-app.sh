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

# Plain string, not an array: macOS still ships bash 3.2, where expanding an empty
# array under `set -u` is an error.
ARCH_FLAGS=""
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS="--arch arm64 --arch x86_64"
fi

echo "==> Building (release)"
swift build -c release ${ARCH_FLAGS}

BINARY="$(swift build -c release ${ARCH_FLAGS} --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BINARY}" ]]; then
  echo "error: built binary not found at ${BINARY}" >&2
  exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BINARY}" "${APP}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc signature. TCC keys its microphone and screen-recording grants off the code
# signature, so an unsigned bundle would re-prompt (or silently fail) on every launch.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --verbose=1 "${APP}"

echo "==> Built ${APP}"
