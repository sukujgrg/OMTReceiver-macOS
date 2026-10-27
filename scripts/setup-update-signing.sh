#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# This preserves the app's existing key; never export or rotate it here.
tool="build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$tool" ]]; then
    xcodebuild -resolvePackageDependencies -project OMTReceiver.xcodeproj -scheme OMTReceiver -derivedDataPath build/DerivedData
fi
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' OMTReceiver/Resources/Info.plist 2>/dev/null || true)"
if [[ -n "$expected_key" ]]; then
    public_key="$("$tool" --account com.suku.OMTReceiver-macOS -p)" || {
        echo 'Import the existing OMTReceiver Sparkle key into this Mac’s Keychain; do not generate a replacement.' >&2
        exit 1
    }
else
    "$tool" --account com.suku.OMTReceiver-macOS
    public_key="$("$tool" --account com.suku.OMTReceiver-macOS -p)"
fi
python3 - "$public_key" <<'PY'
import plistlib, sys
from pathlib import Path
path=Path('OMTReceiver/Resources/Info.plist')
value=plistlib.loads(path.read_bytes())
public_key=sys.argv[1].strip()
existing=value.get('SUPublicEDKey', '')
if existing and existing != public_key:
    raise SystemExit('The Keychain key differs from the app public key. Import the existing signing key on this Mac; do not replace the app key or create a new release identity.')
if not existing:
    value['SUPublicEDKey']=public_key
    path.write_bytes(plistlib.dumps(value))
print('Sparkle public key matches the app. Private key remains in Keychain.')
PY
