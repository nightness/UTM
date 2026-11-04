#!/bin/bash
#
# Builds, signs and packages the unofficial "UTM for Intel Macs" release (see README_INTEL.md).
#
# Run from anywhere on an Apple silicon or Intel Mac with Xcode, Homebrew (meson, ninja, pkg-config,
# python3) and a Developer ID Application certificate. Steps (STEPS="..." to run a subset):
#
#   deps      stage UTM's CI sysroot for macOS x86_64 if there is none, then rebuild QEMU and DXMT into
#             it from patches/sources (our QEMU and DXMT forks) with build_dependencies.sh -u
#   app       xcodebuild archive, x86_64 only, with our bundle prefix and team
#   sign      Developer ID signature with hardened runtime on every nested binary, inside out
#   dmg       signed DMG
#   notarize  notarize and staple the app and the DMG (needs a notarytool keychain profile)
#
# Environment:
#   SIGN_IDENTITY   codesign identity (default: Developer ID Application: Joshua Guyette (WT957SC7MJ))
#   TEAM_ID         team for the application group (default: WT957SC7MJ)
#   BUNDLE_PREFIX   bundle identifier prefix (default: com.nightness). TEAM_ID.BUNDLE_PREFIX.UTM is the
#                   application group, and virglrenderer's shared memory names start with it: it
#                   must be at most 28 characters, or every 3D context fails
#   NOTARY_PROFILE  notarytool keychain profile (default: notary)
#   OUTPUT          output directory (default: <repo>/out-intel)
#   SYSROOT_RUN     utmapp/UTM Actions run id to take the Sysroot-macos-x86_64 artifact from
#                   (default: the newest successful Build run on main that has one)
#
set -euo pipefail

BASEDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BASEDIR"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Joshua Guyette (WT957SC7MJ)}"
TEAM_ID="${TEAM_ID:-WT957SC7MJ}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.nightness}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
OUTPUT="${OUTPUT:-$BASEDIR/out-intel}"
STEPS="${STEPS:-deps app sign dmg notarize}"
APP_GROUP="$TEAM_ID.$BUNDLE_PREFIX.UTM"
if [ ${#APP_GROUP} -gt 28 ]; then
    echo "Application group $APP_GROUP is ${#APP_GROUP} characters; at most 28 fit in a shared memory name" >&2
    exit 1
fi
SYSROOT="sysroot-macOS-x86_64"
VERSION="$(sed -n 's/^MARKETING_VERSION = //p' Build.xcconfig)"
ARCHIVE="$OUTPUT/UTM.xcarchive"
APP="$OUTPUT/UTM.app"
DMG="$OUTPUT/UTM-$VERSION.dmg"
ENTITLEMENTS="$OUTPUT/entitlements"

GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'
say () { echo "${GREEN}==> $*${NC}"; }
die () { echo "${RED}error: $*${NC}" >&2; exit 1; }

has_step () { [[ " $STEPS " == *" $1 "* ]]; }

mkdir -p "$OUTPUT"

stage_sysroot () {
    command -v gh >/dev/null || die "no $SYSROOT; install gh to fetch UTM's CI sysroot, or build one with scripts/build_dependencies.sh -p macos -a x86_64"
    local run="${SYSROOT_RUN:-}"
    if [ -z "$run" ]; then
        for id in $(gh run list -R utmapp/UTM -w Build -b main -s success -L 20 --json databaseId -q '.[].databaseId'); do
            if gh api "repos/utmapp/UTM/actions/runs/$id/artifacts" -q '.artifacts[].name' | grep -qx 'Sysroot-macos-x86_64'; then
                run=$id
                break
            fi
        done
    fi
    [ -n "$run" ] || die "no Sysroot-macos-x86_64 artifact found; set SYSROOT_RUN or build with scripts/build_dependencies.sh -p macos -a x86_64"
    say "Staging Sysroot-macos-x86_64 from utmapp/UTM run $run"
    local tmp="$OUTPUT/sysroot-download"
    rm -rf "$tmp"
    gh run download "$run" -R utmapp/UTM -n Sysroot-macos-x86_64 -D "$tmp"
    tar -xzf "$tmp/sysroot.tgz" -C "$BASEDIR"
    rm -rf "$tmp"
}

step_deps () {
    [ -d "$SYSROOT/Frameworks" ] || stage_sysroot
    # QEMU's configure needs tomllib (Python >= 3.11); macOS's python3 is older
    if [ -z "${PYTHON:-}" ]; then
        export PYTHON="$(brew --prefix)/bin/python3"
    fi
    say "Rebuilding QEMU and DXMT into $SYSROOT"
    ./scripts/build_dependencies.sh -p macos -a x86_64 -u qemu,dxmt
    # the QEMU build tree is about 1.6 GB and only needed for incremental rebuilds
    if [ -z "${KEEP_BUILD:-}" ]; then
        rm -rf build-macOS-x86_64/qemu/build build-macOS-x86_64/dxmt.git/utm_build
    fi
}

step_app () {
    say "Archiving UTM $VERSION for x86_64"
    rm -rf "$ARCHIVE"
    xcodebuild archive -archivePath "$ARCHIVE" -scheme macOS -destination generic/platform=macOS \
        -configuration Release -skipPackagePluginValidation -skipMacroValidation \
        ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
        PRODUCT_BUNDLE_PREFIX="$BUNDLE_PREFIX" TeamIdentifierPrefix="$TEAM_ID."
    rm -rf "$APP"
    ditto "$ARCHIVE/Products/Applications/UTM.app" "$APP"
    [ -x "$APP/Contents/XPCServices/QEMUHelper.xpc/Contents/MacOS/QEMURenderServer.app/Contents/MacOS/QEMURenderServer" ] || die "render server missing from the app"
    [ -d "$APP/Contents/Frameworks/qemu-x86_64-softmmu.framework" ] || die "QEMU frameworks missing from the app"
    rm -rf "$ARCHIVE"
}

# Release entitlements without the ones only an Apple provisioning profile can grant
# (com.apple.vm.networking, com.apple.vm.device-access, com.apple.developer.*): a Developer ID app
# that claims them without a profile is killed at launch. vmnet (shared/bridged networking) and USB
# accessory access are therefore unavailable; emulated (SLiRP) networking works.
make_entitlements () {
    rm -rf "$ENTITLEMENTS"
    mkdir -p "$ENTITLEMENTS"
    cp Platform/macOS/macOS.entitlements "$ENTITLEMENTS/utm.plist"
    cp QEMUHelper/QEMUHelper.entitlements "$ENTITLEMENTS/helper.plist"
    cp QEMULauncher/QEMULauncher.entitlements "$ENTITLEMENTS/launcher.plist"
    cp QEMURenderServer/QEMURenderServer.entitlements "$ENTITLEMENTS/renderer.plist"
    cp utmctl/utmctl.entitlements "$ENTITLEMENTS/cli.plist"
    local f key
    for f in "$ENTITLEMENTS"/*.plist; do
        for key in com.apple.vm.networking com.apple.vm.device-access com.apple.developer.accessory-access.usb; do
            /usr/libexec/PlistBuddy -c "Delete :$key" "$f" 2>/dev/null || true
        done
        if /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups:0" "$f" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $TEAM_ID.$BUNDLE_PREFIX.UTM" "$f"
        fi
    done
    sed -i '' "s/\$(PRODUCT_BUNDLE_PREFIX:default=com.utmapp)/$BUNDLE_PREFIX/g" "$ENTITLEMENTS/cli.plist"
}

csign () {
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$@"
}

step_sign () {
    [ -d "$APP" ] || die "no $APP, run the app step"
    make_entitlements
    local helper="$APP/Contents/XPCServices/QEMUHelper.xpc"
    say "Signing frameworks"
    find "$APP/Contents/Frameworks" -maxdepth 1 -name '*.framework' -print0 | xargs -0 -n 8 -P 8 \
        codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY"
    # any loose Mach-O outside the bundles above
    find "$APP/Contents/Frameworks" "$APP/Contents/Resources" -type f \( -name '*.dylib' -o -perm +111 \) \
        -not -path '*.framework/*' -print0 | while IFS= read -r -d '' f; do
        if file -b "$f" | grep -q Mach-O; then
            csign "$f"
        fi
    done
    say "Signing helpers"
    csign --entitlements "$ENTITLEMENTS/launcher.plist" "$helper/Contents/MacOS/QEMULauncher.app"
    csign --entitlements "$ENTITLEMENTS/renderer.plist" "$helper/Contents/MacOS/QEMURenderServer.app"
    csign --entitlements "$ENTITLEMENTS/helper.plist" "$helper"
    csign --entitlements "$ENTITLEMENTS/cli.plist" "$APP/Contents/MacOS/utmctl"
    say "Signing UTM.app"
    csign --entitlements "$ENTITLEMENTS/utm.plist" "$APP"
    say "Verifying"
    codesign --verify --deep --strict --verbose=2 "$APP"
    spctl -a -t exec -vv "$APP" || echo "${RED}spctl rejects the app until it is notarized${NC}"
}

step_dmg () {
    [ -d "$APP" ] || die "no $APP"
    say "Creating $DMG"
    local stage="$OUTPUT/dmg"
    rm -rf "$stage" "$DMG"
    mkdir -p "$stage"
    ditto "$APP" "$stage/UTM.app"
    ln -s /Applications "$stage/Applications"
    cp README_INTEL.md "$stage/README (Intel build).md"
    hdiutil create -fs HFS+ -srcfolder "$stage" -volname "UTM $VERSION" -format UDZO "$DMG"
    rm -rf "$stage"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
}

step_notarize () {
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "${RED}No notarytool profile '$NOTARY_PROFILE'. Create it with:${NC}"
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple id> --team-id $TEAM_ID --password <app-specific password>"
        echo "then run: STEPS=\"notarize\" $0"
        return 1
    fi
    say "Notarizing UTM.app"
    local zip="$OUTPUT/UTM-notarize.zip"
    ditto -c -k --keepParent "$APP" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$zip"
    xcrun stapler staple "$APP"
    # rebuild the DMG around the stapled app, then notarize the DMG itself
    step_dmg
    say "Notarizing $DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl -a -t exec -vv "$APP"
    spctl -a -t open --context context:primary-signature -vv "$DMG"
}

has_step deps && step_deps
has_step app && step_app
has_step sign && step_sign
has_step dmg && step_dmg
has_step notarize && step_notarize
say "Done: $APP $DMG"
