APP := build/Screen Recorder.app
SOURCES := $(wildcard Sources/*.swift)
SDK := $(shell xcrun --show-sdk-path)
SIGN_IDENTITY ?= -

.PHONY: build icon desktop-shortcut format clean
build: Resources/AppIcon.icns
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -sdk "$(SDK)" -module-cache-path .build/module-cache $(SOURCES) -o "$(APP)/Contents/MacOS/ScreenRecorder"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.nasa666999.screen-recorder "$(APP)"
	touch "$(APP)"

icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Scripts/generate-icon.swift
	mkdir -p .build
	xcrun swiftc -module-cache-path .build/module-cache Scripts/generate-icon.swift -o .build/generate-icon
	.build/generate-icon Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

desktop-shortcut: build
	ln -s "$(CURDIR)/$(APP)" "$(HOME)/Desktop/Screen Recorder.app"

format:
	xcrun swift-format format --in-place $(SOURCES) Scripts/generate-icon.swift

clean:
	rm -rf build .build
