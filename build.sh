#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/MacLiteMonitor.app/Contents/MacOS build/MacLiteMonitor.app/Contents/Resources
for arch in arm64 x86_64; do
    clang -arch "$arch" -mmacosx-version-min=13.0 -c temperature.c -o "build/temperature-$arch.o"
    swiftc -target "$arch-apple-macosx13.0" main.swift "build/temperature-$arch.o" -import-objc-header bridging.h -framework IOKit -framework Cocoa -framework ServiceManagement -O -o "build/MacLiteMonitor-$arch"
done
lipo -create build/MacLiteMonitor-arm64 build/MacLiteMonitor-x86_64 -output build/MacLiteMonitor.app/Contents/MacOS/MacLiteMonitor
cp Info.plist build/MacLiteMonitor.app/Contents/Info.plist
cp LICENSE assets/AppIcon.icns build/MacLiteMonitor.app/Contents/Resources/
codesign --force --deep --sign - build/MacLiteMonitor.app
