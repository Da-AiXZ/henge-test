#!/bin/zsh
# Builds Henge for iOS and writes ~/Desktop/Henge.ipa (or ~/Desktop/Henge.tipa with --trollstore,
# ~/Desktop/Henge-iOS16.tipa with --trollstore-ios16).
# Unsigned build, then signed ad hoc inside out with Henge.entitlements, as Husk's
# package_ipa.sh does: the sideloader (SideStore, AltStore, Impactor) re-signs it
# with the user's own certificate and keeps the entitlements it can.
# --trollstore strips the entitlements TrollStore bans under PPL/TXM.
# --trollstore-ios16 is the same build for an iOS 16 device: there is no TXM
# there, so TrollStore's JIT needs dynamic-codesigning and it is kept.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TROLLSTORE=false
KEEP_DYNAMIC_CODESIGNING=false
case "$1" in
  --trollstore) TROLLSTORE=true ;;
  --trollstore-ios16) TROLLSTORE=true; KEEP_DYNAMIC_CODESIGNING=true ;;
esac
OUT="$HOME/Desktop/Henge.ipa"
[ "$TROLLSTORE" = true ] && OUT="$HOME/Desktop/Henge.tipa"
[ "$KEEP_DYNAMIC_CODESIGNING" = true ] && OUT="$HOME/Desktop/Henge-iOS16.tipa"
[ -n "$HENGE_OUT" ] && OUT="$HENGE_OUT"
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
cd "$IOS"
xcodegen generate >/dev/null
DD="$IOS/build/DerivedData"
mkdir -p "$DD"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
rc=0
REQUIRED=("$APP/Henge" "$APP/henge-jit.js")
# The built-in JIT helper (iOS 26) and StikJIT (17.4) are unusable on iOS 16,
# and their higher minimum OS can stop iOS 16 from launching the bundle.
if [ "$KEEP_DYNAMIC_CODESIGNING" != true ]; then
    REQUIRED+=("$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper"
               "$APP/Frameworks/StikJIT.framework/StikJIT"
               "$APP/Frameworks/StikJIT.framework/Info.plist")
fi
for f in "${REQUIRED[@]}"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

STAGE="$(mktemp -d "$DD/stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
ENT="$STAGE/entitlements.plist"
cp "$IOS/Henge/Henge.entitlements" "$ENT"
# Diagnostics: drop restricted entitlements that a given install cannot hold.
# Python, because plutil/PlistBuddy key paths treat dots specially.
if [ -n "$ENT_STRIP" ]; then
  python3 - "$ENT" "$ENT_STRIP" <<'PY'
import plistlib, sys
path, keys = sys.argv[1], sys.argv[2].split()
with open(path, "rb") as f:
    data = plistlib.load(f)
for key in keys:
    data.pop(key, None)
with open(path, "wb") as f:
    plistlib.dump(data, f)
PY
fi
BANNED_KEYS=("com.apple.private.cs.debugger" "dynamic-codesigning" "com.apple.private.skip-library-validation")
if [ "$TROLLSTORE" = true ]; then
  for k in "${BANNED_KEYS[@]}"; do
    if [ "$KEEP_DYNAMIC_CODESIGNING" = true ] && [ "$k" = "dynamic-codesigning" ]; then continue; fi
    /usr/libexec/PlistBuddy -c "Delete :$k" "$ENT" >/dev/null 2>&1 || true
  done
fi
SAPP="$STAGE/Payload/Henge.app"
# iOS 16 has no use for the built-in JIT helper, and both it (26.0) and StikJIT
# (17.4) declare a newer minimum OS than the app: leaving them in can make the
# system refuse to launch the bundle at all.
if [ "$KEEP_DYNAMIC_CODESIGNING" = true ]; then
  rm -rf "$SAPP/PlugIns/HengeJITHelper.appex" "$SAPP/Frameworks/StikJIT.framework"
  rmdir "$SAPP/PlugIns" 2>/dev/null || true
  rmdir "$SAPP/Frameworks" 2>/dev/null || true
fi
# Apple's boot ROM is fetched on the device (BootROM.swift) and must never ship. An older build folder can still
# hold a copy from when the app bundled it, so it goes, and nothing is packaged if any is left.
rm -f "$SAPP/AVPBooter.vmapple2.bin"
if [ -n "$(find "$STAGE" -iname 'AVPBooter*' -o -iname 'AVPSEPBooter*')" ]; then
  echo "Apple's boot ROM is in the app: not packaging." >&2
  exit 1
fi
sign() { codesign --force --sign - --timestamp=none "$@"; }
if [ -d "$SAPP/Frameworks" ]; then
  for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
fi
if [ -d "$SAPP/PlugIns" ]; then
  for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
fi
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
for k in get-task-allow increased-memory-limit extended-virtual-addressing; do
    if [ -n "$ENT_STRIP" ] && [[ "$ENT_STRIP" == *"$k"* ]]; then continue; fi
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
