#!/bin/sh
# Builds build/Apple Calendar Helper.app. Set SIGN_IDENTITY to use your own
# certificate; the default is an ad-hoc signature.
set -eu
cd "$(dirname "$0")"
APP="build/Apple Calendar Helper.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift RRule.swift Commands.swift -o "$APP/Contents/MacOS/calendar-helper"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "built $APP"
