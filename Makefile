PREFIX ?= $(HOME)/.local
BIN_DIR = $(PREFIX)/bin

.PHONY: build test release install universal uninstall clean

build:
	swift build

test:
	swift test

release:
	swift build -c release --disable-sandbox

install: release
	mkdir -p "$(BIN_DIR)"
	cp "$$(swift build -c release --show-bin-path)/xcbrief" "$(BIN_DIR)/xcbrief"
	@echo "Installed $(BIN_DIR)/xcbrief"

# arm64 + x86_64 binary that can be copied to another Mac.
universal:
	swift build -c release --arch arm64 --arch x86_64 --disable-sandbox
	@echo "Built .build/apple/Products/Release/xcbrief"

uninstall:
	rm -f "$(BIN_DIR)/xcbrief"

clean:
	rm -rf .build
