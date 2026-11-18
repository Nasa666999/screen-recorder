APP := build/Screen Recorder.app
SOURCES := $(wildcard Sources/*.swift)
SDK := $(shell xcrun --show-sdk-path)
SIGN_IDENTITY ?= Screen Recorder Local Development
MODEL_PYTHON ?= /usr/bin/python3

.PHONY: build check-signing model icon desktop-shortcut format clean
build: check-signing Resources/AppIcon.icns model
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -sdk "$(SDK)" -module-cache-path .build/module-cache $(SOURCES) -o "$(APP)/Contents/MacOS/ScreenRecorder"
	rm -rf "$(APP)/Contents/Resources"
	mkdir -p "$(APP)/Contents/Resources"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	ditto .build/LaMa.mlmodelc "$(APP)/Contents/Resources/LaMa.mlmodelc"
	ditto .build/LocalLaMa.mlmodelc "$(APP)/Contents/Resources/LocalLaMa.mlmodelc"
	ditto Resources/ThirdParty "$(APP)/Contents/Resources/ThirdParty"
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier com.nasa666999.screen-recorder "$(APP)"
	touch "$(APP)"

check-signing:
	/bin/bash Scripts/check-signing.sh "$(SIGN_IDENTITY)"

model:
	/bin/bash Scripts/prepare-lama.sh "$(MODEL_PYTHON)"

icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Scripts/generate-icon.swift
	mkdir -p .build
	xcrun swiftc -module-cache-path .build/module-cache Scripts/generate-icon.swift -o .build/generate-icon
	.build/generate-icon Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns

desktop-shortcut: build
	ln -s "$(CURDIR)/$(APP)" "$(HOME)/Desktop/Screen Recorder.app"

format:
	xcrun swift-format format --in-place $(SOURCES) Scripts/generate-icon.swift Scripts/compile-lama.swift

clean:
	rm -rf build .build
