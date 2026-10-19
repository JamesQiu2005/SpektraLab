#!/bin/sh
# sign-library-helper.sh -- run by the app target right after "Embed library
# helper" copies spklib-host into Contents/Helpers.
#
# Code Sign On Copy is not enough on its own, and this was found by looking at
# the copy rather than trusting the checkbox: with the ad-hoc identity Xcode
# copied the SDK's binary byte for byte, and when it does re-sign an embedded
# tool it preserves the original's flags. The SDK's release build is ad-hoc
# *without* the hardened runtime, so a Developer ID build would have carried a
# helper notarisation refuses ("The executable does not have the hardened
# runtime enabled"). Signed here, explicitly, with the app's own identity, the
# hardened runtime and -- for a real identity -- a secure timestamp. The app's
# own signature is made after every build phase, so it seals this one.
#
# `Tools/package.sh` checks the result on the exported app.
set -eu
helper="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/spklib-host"
if [ ! -f "$helper" ]; then
  echo "error: the library helper was not embedded at $helper" >&2
  exit 1
fi
if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ]; then
  exit 0
fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$identity" ] || identity="-"
id="${PRODUCT_BUNDLE_IDENTIFIER:-com.hanze.filmify}.spklib-host"
if [ "$identity" = "-" ]; then
  codesign --force --sign - --options runtime --identifier "$id" "$helper"
else
  codesign --force --sign "$identity" --options runtime --timestamp --identifier "$id" "$helper"
fi
