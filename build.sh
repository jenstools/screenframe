#!/bin/bash
#
# Builds ScreenFrame.app without Xcode (SwiftPM + a hand-assembled bundle + codesign).
#
#   ./build.sh              build .build/ScreenFrame.app
#   ./build.sh --install    also copy it to /Applications
#   ./build.sh --run        build, install and launch
#
# Screen Recording permission is tied to the code signature. If the self-signed
# "Flow App Signing" identity exists it is used, so the grant survives rebuilds; otherwise the
# app is ad-hoc signed and macOS asks again after every build.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ScreenFrame"
BUNDLE_ID="com.jenspolomski.screenframe"
IDENTITY="Flow App Signing"
APP="/Applications/${APP_NAME}.app"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }

bold "Building (release)"
swift build -c release

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

STAGE=".build/${APP_NAME}.app"
rm -rf "$STAGE"
mkdir -p "${STAGE}/Contents/MacOS" "${STAGE}/Contents/Resources"
cp ".build/release/${APP_NAME}" "${STAGE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "${STAGE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${STAGE}/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "${STAGE}/Contents/PkgInfo"

if security find-identity -p codesigning -v | grep -q "\"${IDENTITY}\""; then
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --options runtime \
        --entitlements Resources/ScreenFrame.entitlements "$STAGE"
    info "signed with \"${IDENTITY}\" (stable, permission grants survive rebuilds)"
else
    codesign --force --sign - --identifier "$BUNDLE_ID" --options runtime \
        --entitlements Resources/ScreenFrame.entitlements "$STAGE"
    info "ad-hoc signed (macOS will ask for Screen Recording again after each rebuild)"
fi

if [ "${1:-}" != "--install" ] && [ "${1:-}" != "--run" ]; then
    bold "Done"
    info "run it:     open ${STAGE}"
    info "install it: ./build.sh --install"
    exit 0
fi

bold "Installing to /Applications"
osascript -e "quit app \"${APP_NAME}\"" 2>/dev/null || true
# Wait until it's really gone: copying over a running app leaves the old version running.
for _ in $(seq 1 20); do
    pgrep -f "${APP}/Contents/MacOS/${APP_NAME}" >/dev/null || break
    sleep 0.5
done
if pgrep -f "${APP}/Contents/MacOS/${APP_NAME}" >/dev/null; then
    # Ask it to save and quit (handled by the app even with a dialog open), then wait again.
    pkill -TERM -f "${APP}/Contents/MacOS/${APP_NAME}" || true
    sleep 2
fi
if pgrep -f "${APP}/Contents/MacOS/${APP_NAME}" >/dev/null; then
    info "ScreenFrame is still running (close any open dialog) — not installing over it."
    exit 1
fi
rm -rf "$APP"
cp -R "$STAGE" "$APP"
info "installed ${APP}"

if [ "${1:-}" = "--run" ]; then
    open "$APP"
    info "launched"
fi
