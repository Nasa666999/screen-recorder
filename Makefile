APP := build/Screen Recorder.app
SOURCES := $(wildcard Sources/*.swift)
SDK := $(shell xcrun --show-sdk-path)

.PHONY: build format clean
build:
	mkdir -p "$(APP)/Contents/MacOS"
	xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 -sdk "$(SDK)" -module-cache-path .build/module-cache $(SOURCES) -o "$(APP)/Contents/MacOS/ScreenRecorder"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - --identifier com.nasa666999.screen-recorder "$(APP)"

format:
	xcrun swift-format format --in-place $(SOURCES)

clean:
	rm -rf build .build
