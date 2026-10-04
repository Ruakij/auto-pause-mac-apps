#!/bin/zsh
# Build "Auto Pause Mac Apps.app". Requires only Xcode Command Line Tools — no Xcode needed.
#   ./build.sh              → native build for this Mac (fast, for development)
#   ./build.sh --universal  → Apple Silicon + Intel universal binary (for release)
set -e
cd "$(dirname "$0")"

UNIVERSAL=0
[[ "$1" == "--universal" ]] && UNIVERSAL=1

# Some Command Line Tools SDKs ship SwiftUI without its macro plugin, so @State fails to
# compile. SDKROOT set by the caller wins; otherwise fall back to the newest installed
# SDK that can compile a @State property.
if [[ -z "$SDKROOT" ]]; then
  PROBE=$(mktemp -d)
  print 'import SwiftUI\nstruct V: View { @State var x = 0; var body: some View { Text("") } }' > "$PROBE/p.swift"
  if ! swiftc -typecheck "$PROBE/p.swift" >/dev/null 2>&1; then
    for sdk in $(ls -d "$(dirname "$(xcrun --show-sdk-path)")"/MacOSX[0-9]*.sdk | sort -rV); do
      if SDKROOT="$sdk" swiftc -typecheck "$PROBE/p.swift" >/dev/null 2>&1; then
        export SDKROOT="$sdk"
        echo "▸ Default SDK cannot compile SwiftUI macros, using $SDKROOT"
        break
      fi
    done
  fi
  rm -rf "$PROBE"
fi

APP="Auto Pause Mac Apps.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if (( UNIVERSAL )); then
  # SwiftPM's --arch needs Xcode's xcbuild, which Command Line Tools don't ship.
  # Cross-compile each slice separately and stitch them with lipo instead.
  BINS=()
  for arch in arm64 x86_64; do
    echo "▸ Building $arch slice..."
    swift build -c release --scratch-path ".build-$arch" --triple "$arch-apple-macosx14.0"
    BINS+=("$(swift build -c release --scratch-path ".build-$arch" --triple "$arch-apple-macosx14.0" --show-bin-path)/AutoPauseMacApps")
  done
  echo "▸ Merging into a universal binary..."
  lipo -create -output "$APP/Contents/MacOS/AutoPauseMacApps" "${BINS[@]}"
else
  echo "▸ Building for $(uname -m)..."
  swift build -c release
  cp "$(swift build -c release --show-bin-path)/AutoPauseMacApps" "$APP/Contents/MacOS/AutoPauseMacApps"
fi

cp Info.plist "$APP/Contents/Info.plist"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with a Developer ID if one is installed, otherwise fall back to ad-hoc.
# A Developer ID certificate requires a paid Apple Developer Program membership;
# without it macOS shows a Gatekeeper warning on first launch, which the Homebrew
# cask and install.sh both avoid by clearing the quarantine attribute.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')

if [[ -n "$IDENTITY" ]]; then
  echo "▸ Signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
  echo "   Signed for distribution. Run ./notarize.sh to notarize."
else
  echo "▸ Signing (ad-hoc — no Developer ID certificate found)..."
  codesign --force --deep --sign - "$APP"
fi

echo "✅ Built $PWD/$APP"
lipo -archs "$APP/Contents/MacOS/AutoPauseMacApps" 2>/dev/null | sed 's/^/   architectures: /'
echo "   Install: cp -r \"Auto Pause Mac Apps.app\" /Applications/"
