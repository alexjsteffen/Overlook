.DEFAULT_GOAL := all
.DELETE_ON_ERROR:

HOST_OS := $(shell uname -s)
ROOT_DIR := $(CURDIR)
LINUX_DIR := $(ROOT_DIR)/Linux
DIST_DIR ?= $(ROOT_DIR)/dist
LINUX_BUILD_DIR ?= $(ROOT_DIR)/build/linux
MACOS_BUILD_DIR ?= $(ROOT_DIR)/build/macos

SWIFT ?= swift
XCODEBUILD ?= xcodebuild
DOCKER ?= docker
DOCKER_IMAGE ?= overlook-linux

VERSION ?= 0.1.1
PACKAGE_RELEASE ?= 1
PACKAGE ?= deb
LINUXDEPLOY ?= linuxdeploy
APPIMAGETOOL ?= appimagetool

LINUX_BINARY := $(LINUX_BUILD_DIR)/release/overlook
MACOS_DERIVED_DATA := $(MACOS_BUILD_DIR)/derived-data
MACOS_APP := $(MACOS_DERIVED_DATA)/Build/Products/Release/Overlook.app
MACOS_ARCHIVE := $(MACOS_BUILD_DIR)/Overlook.xcarchive
MACOS_EXPORT_DIR := $(MACOS_BUILD_DIR)/export
MACOS_EXPORTED_APP := $(MACOS_EXPORT_DIR)/Overlook.app
MACOS_EXPORT_OPTIONS := $(MACOS_BUILD_DIR)/ExportOptions.plist
MACOS_SUBMIT_ZIP := $(MACOS_BUILD_DIR)/Overlook-submit.zip
DOCKER_EXPORT_DIR := $(ROOT_DIR)/build/docker/export

PACKAGE_ENV = ROOT_DIR="$(ROOT_DIR)" BINARY="$(abspath $(LINUX_BINARY))" \
	BUILD_DIR="$(abspath $(LINUX_BUILD_DIR))" DIST_DIR="$(abspath $(DIST_DIR))" \
	VERSION="$(VERSION)" PACKAGE_RELEASE="$(PACKAGE_RELEASE)" \
	LINUXDEPLOY="$(LINUXDEPLOY)" APPIMAGETOOL="$(APPIMAGETOOL)"

.PHONY: all build macos macos-signed macos-notarized linux package \
	pacman deb rpm appimage test docker docker-image docker-test clean help

ifeq ($(HOST_OS),Darwin)
all: macos
else ifeq ($(HOST_OS),Linux)
all: linux
else
all:
	@echo "Unsupported host: $(HOST_OS). Run 'make macos' on macOS or 'make linux' on Linux." >&2
	@exit 1
endif

build: all

# Unsigned local-development bundle. No Apple account or certificate is needed.
macos:
	@test "$(HOST_OS)" = "Darwin" || { echo "macOS targets require macOS and Xcode." >&2; exit 1; }
	$(XCODEBUILD) build \
		-project Overlook.xcodeproj \
		-scheme Overlook \
		-configuration Release \
		-sdk macosx \
		-destination "platform=macOS" \
		-derivedDataPath "$(MACOS_DERIVED_DATA)" \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
		CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
	mkdir -p "$(DIST_DIR)"
	rm -rf "$(DIST_DIR)/Overlook.app"
	ditto "$(MACOS_APP)" "$(DIST_DIR)/Overlook.app"
	ditto -c -k --keepParent "$(DIST_DIR)/Overlook.app" "$(DIST_DIR)/Overlook-macOS.zip"
	@echo "Built $(DIST_DIR)/Overlook.app (unsigned)"

# Archive, Developer ID sign, and export. Requires an installed certificate.
macos-signed:
	@test "$(HOST_OS)" = "Darwin" || { echo "macOS targets require macOS and Xcode." >&2; exit 1; }
	@test -n "$(APPLE_TEAM_ID)" || { echo "Set APPLE_TEAM_ID to your 10-character Apple Team ID." >&2; exit 1; }
	@test -n "$(MACOS_BUNDLE_ID)" || { echo "Set MACOS_BUNDLE_ID, for example com.example.Overlook." >&2; exit 1; }
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" || { echo "No Developer ID Application certificate was found in the login keychain. See README.md." >&2; exit 1; }
	mkdir -p "$(MACOS_BUILD_DIR)" "$(DIST_DIR)"
	rm -rf "$(MACOS_ARCHIVE)" "$(MACOS_EXPORT_DIR)"
	$(XCODEBUILD) archive \
		-project Overlook.xcodeproj \
		-scheme Overlook \
		-configuration Release \
		-destination "generic/platform=macOS" \
		-archivePath "$(MACOS_ARCHIVE)" \
		DEVELOPMENT_TEAM="$(APPLE_TEAM_ID)" \
		PRODUCT_BUNDLE_IDENTIFIER="$(MACOS_BUNDLE_ID)" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="Developer ID Application" \
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
		OTHER_CODE_SIGN_FLAGS="--timestamp"
	cp ExportOptions.plist "$(MACOS_EXPORT_OPTIONS)"
	/usr/libexec/PlistBuddy -c "Set :teamID $(APPLE_TEAM_ID)" "$(MACOS_EXPORT_OPTIONS)"
	$(XCODEBUILD) -exportArchive \
		-archivePath "$(MACOS_ARCHIVE)" \
		-exportPath "$(MACOS_EXPORT_DIR)" \
		-exportOptionsPlist "$(MACOS_EXPORT_OPTIONS)"
	codesign --verify --strict --deep "$(MACOS_EXPORTED_APP)"
	rm -rf "$(DIST_DIR)/Overlook.app"
	ditto "$(MACOS_EXPORTED_APP)" "$(DIST_DIR)/Overlook.app"
	ditto -c -k --keepParent "$(DIST_DIR)/Overlook.app" "$(DIST_DIR)/Overlook-macOS-signed.zip"
	ditto -c -k --keepParent "$(DIST_DIR)/Overlook.app" "$(MACOS_SUBMIT_ZIP)"
	@echo "Built $(DIST_DIR)/Overlook.app (Developer ID signed; not notarized)"

# Notarize and staple the app produced by macos-signed.
macos-notarized: macos-signed
	@test -n "$(APPLE_API_KEY_PATH)" || { echo "Set APPLE_API_KEY_PATH to your App Store Connect API .p8 file." >&2; exit 1; }
	@test -f "$(APPLE_API_KEY_PATH)" || { echo "API key not found: $(APPLE_API_KEY_PATH)" >&2; exit 1; }
	@test -n "$(APPLE_API_KEY_ID)" || { echo "Set APPLE_API_KEY_ID to the API key's 10-character Key ID." >&2; exit 1; }
	@test -n "$(APPLE_API_ISSUER_ID)" || { echo "Set APPLE_API_ISSUER_ID to the App Store Connect API Issuer UUID." >&2; exit 1; }
	xcrun notarytool submit "$(MACOS_SUBMIT_ZIP)" \
		--key "$(APPLE_API_KEY_PATH)" \
		--key-id "$(APPLE_API_KEY_ID)" \
		--issuer "$(APPLE_API_ISSUER_ID)" \
		--wait
	xcrun stapler staple "$(DIST_DIR)/Overlook.app"
	xcrun stapler validate "$(DIST_DIR)/Overlook.app"
	codesign --verify --strict --deep "$(DIST_DIR)/Overlook.app"
	spctl --assess --verbose=4 --type execute "$(DIST_DIR)/Overlook.app"
	ditto -c -k --keepParent "$(DIST_DIR)/Overlook.app" "$(DIST_DIR)/Overlook-macOS.zip"
	@echo "Built $(DIST_DIR)/Overlook-macOS.zip (signed, notarized, and stapled)"

# A native Linux executable with the Swift runtime linked in. GTK/WebKit and
# GStreamer remain system dependencies; see Linux/README.md.
linux:
	@test "$(HOST_OS)" = "Linux" || { echo "Linux targets require Linux." >&2; exit 1; }
	$(SWIFT) build --package-path "$(LINUX_DIR)" \
		--scratch-path "$(LINUX_BUILD_DIR)" -c release --static-swift-stdlib
	mkdir -p "$(DIST_DIR)"
	install -Dm755 "$(LINUX_BINARY)" "$(DIST_DIR)/overlook"
	@echo "Built $(DIST_DIR)/overlook"

# Select one package with PACKAGE=pacman, deb, rpm, or appimage.
package: linux
	$(PACKAGE_ENV) "$(LINUX_DIR)/packaging/build-package.sh" "$(PACKAGE)"

pacman deb rpm appimage: linux
	$(PACKAGE_ENV) "$(LINUX_DIR)/packaging/build-package.sh" "$@"

test:
	$(SWIFT) test --package-path "$(LINUX_DIR)" --scratch-path "$(LINUX_BUILD_DIR)"

# Compile and test in the root Dockerfile, then export only the executable.
docker:
	@command -v "$(DOCKER)" >/dev/null 2>&1 || { echo "Docker is required for this target." >&2; exit 1; }
	rm -rf "$(DOCKER_EXPORT_DIR)"
	$(DOCKER) build --target export --output "type=local,dest=$(DOCKER_EXPORT_DIR)" .
	mkdir -p "$(DIST_DIR)"
	install -m 755 "$(DOCKER_EXPORT_DIR)/overlook" "$(DIST_DIR)/overlook"
	@echo "Built $(DIST_DIR)/overlook with Docker"

docker-image:
	$(DOCKER) build --target test -t "$(DOCKER_IMAGE)" .

docker-test: docker-image
	$(DOCKER) run --rm "$(DOCKER_IMAGE)"

clean:
	@target="$(abspath $(DIST_DIR))"; \
	case "$$target" in \
		"$(ROOT_DIR)"/*) ;; \
		*) echo "Refusing to remove DIST_DIR outside the repository: $$target" >&2; exit 1 ;; \
	esac; \
	rm -rf "$(ROOT_DIR)/build" "$$target"

help:
	@printf '%s\n' \
		'Overlook build targets:' \
		'  make / make build       Build Overlook.app on macOS or overlook on Linux' \
		'  make macos              Build an unsigned macOS app and zip in dist/' \
		'  make macos-signed       Build a Developer ID signed app (requires APPLE_TEAM_ID and MACOS_BUNDLE_ID)' \
		'  make macos-notarized    Sign, notarize, and staple (also requires App Store Connect API values)' \
		'  make linux              Build the native Linux executable in dist/overlook' \
		'  make package PACKAGE=X  Build X = pacman, deb, rpm, or appimage' \
		'  make pacman|deb|rpm|appimage  Direct aliases for the package formats' \
		'  make docker             Compile/test in Docker and export dist/overlook' \
		'  make docker-test        Build the Docker test image and run its native smoke test' \
		'  make test               Run the Linux Swift tests natively' \
		'  make clean              Remove build/ and dist/' \
		'' \
		'Package overrides: VERSION=$(VERSION), PACKAGE_RELEASE=$(PACKAGE_RELEASE), DIST_DIR=$(DIST_DIR)' \
		'AppImage tools: LINUXDEPLOY=$(LINUXDEPLOY), APPIMAGETOOL=$(APPIMAGETOOL)'
