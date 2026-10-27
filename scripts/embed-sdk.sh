#!/bin/sh
set -eu
sdk_root="${OMT_SDK_ROOT:-${SRCROOT}/Vendor/OMT}"
destination="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/OMT"
mkdir -p "$destination"
for library in libvmx.dylib libomt.dylib; do
    test -f "$sdk_root/lib/$library" || { echo "error: Missing OMT SDK library: $sdk_root/lib/$library" >&2; exit 1; }
    /usr/bin/ditto "$sdk_root/lib/$library" "$destination/$library"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
        identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
        if [ "${identity:--}" = - ]; then
            /usr/bin/codesign --force --sign - --timestamp=none "$destination/$library"
        else
            /usr/bin/codesign --force --sign "$identity" --options runtime --timestamp "$destination/$library"
        fi
    fi
done
notices="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/OMT"
mkdir -p "$notices"
for document in LICENSE.txt provenance.json BUILDING.md PATCHES.md README.md; do
    if [ -f "$sdk_root/$document" ]; then /usr/bin/ditto "$sdk_root/$document" "$notices/$document"; fi
done
