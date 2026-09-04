APP_NAME = SidewinderX6
VERSION = 1.0.0
BUNDLE = build/$(APP_NAME).app
INSTALL_APP = /Applications/$(APP_NAME).app
LAUNCH_AGENT = $(HOME)/Library/LaunchAgents/com.vjh.sidewinder-x6.plist
SWIFTC ?= swiftc
SWIFT_FILES = $(wildcard Sources/*.swift)
FRAMEWORKS = -framework AppKit -framework IOKit -framework CoreFoundation -framework ApplicationServices -framework CoreGraphics
CFLAGS = -O -whole-module-optimization
MIN_OS = 13.0
DIST_DIR = dist/$(APP_NAME)-$(VERSION)
DIST_ZIP = dist/$(APP_NAME)-$(VERSION)-macos.zip

.PHONY: all app dist install uninstall listen clean

all: app

app: $(BUNDLE)/Contents/MacOS/$(APP_NAME)

$(BUNDLE)/Contents/MacOS/$(APP_NAME): $(SWIFT_FILES) Resources/Info.plist Resources/AppIcon.icns
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources build/bin
	$(SWIFTC) $(CFLAGS) -target arm64-apple-macos$(MIN_OS) -o build/bin/$(APP_NAME)-arm64 $(SWIFT_FILES) $(FRAMEWORKS)
	$(SWIFTC) $(CFLAGS) -target x86_64-apple-macos$(MIN_OS) -o build/bin/$(APP_NAME)-x86_64 $(SWIFT_FILES) $(FRAMEWORKS)
	lipo -create -output $@ build/bin/$(APP_NAME)-arm64 build/bin/$(APP_NAME)-x86_64
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Resources/config.example.json $(BUNDLE)/Contents/Resources/config.example.json
	cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	cp Resources/StatusIcon.png Resources/StatusIcon@2x.png Resources/StatusIcon@3x.png $(BUNDLE)/Contents/Resources/
	codesign --force --sign - \
		--identifier com.vjh.sidewinder-x6 \
		--requirements '=designated => identifier "com.vjh.sidewinder-x6"' \
		$(BUNDLE)

dist: app
	rm -rf $(DIST_DIR) $(DIST_ZIP)
	mkdir -p $(DIST_DIR)
	cp -R $(BUNDLE) $(DIST_DIR)/
	cp LaunchAgents/com.vjh.sidewinder-x6.plist $(DIST_DIR)/
	cp scripts/install.command $(DIST_DIR)/
	chmod +x $(DIST_DIR)/install.command
	ditto -c -k --keepParent $(DIST_DIR) $(DIST_ZIP)
	@echo "Wrote $(DIST_ZIP)"
	@lipo -info $(BUNDLE)/Contents/MacOS/$(APP_NAME)

install: app
	mkdir -p "$(HOME)/Library/Application Support/SidewinderX6"
	if [ ! -f "$(HOME)/Library/Application Support/SidewinderX6/config.json" ]; then \
		cp Resources/config.example.json "$(HOME)/Library/Application Support/SidewinderX6/config.json"; \
	fi
	launchctl bootout "gui/$$(id -u)/com.vjh.sidewinder-x6" >/dev/null 2>&1 || true
	killall SidewinderX6 >/dev/null 2>&1 || true
	sleep 1
	rm -rf "$(INSTALL_APP)"
	cp -R "$(BUNDLE)" "$(INSTALL_APP)"
	cp LaunchAgents/com.vjh.sidewinder-x6.plist "$(LAUNCH_AGENT)"
	launchctl bootstrap "gui/$$(id -u)" "$(LAUNCH_AGENT)"
	@echo "Installed $(INSTALL_APP)"
	@echo "Grant Accessibility to Sidewinder X6 in System Settings → Privacy & Security → Accessibility."

uninstall:
	launchctl bootout "gui/$$(id -u)/com.vjh.sidewinder-x6" >/dev/null 2>&1 || true
	rm -f "$(LAUNCH_AGENT)"
	rm -rf "$(INSTALL_APP)"
	@echo "Removed app and LaunchAgent. Config left in ~/Library/Application Support/SidewinderX6"

listen: app
	$(BUNDLE)/Contents/MacOS/$(APP_NAME) --listen

clean:
	rm -rf build dist
