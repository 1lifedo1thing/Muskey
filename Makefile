APP := Muskey
BUILD := $(CURDIR)/build
BUNDLE := $(BUILD)/$(APP).app
INSTALL_DIR := /Applications
# A Developer ID signature keeps the System Audio Recording permission across rebuilds. An ad-hoc one resets it.
IDENTITY ?= Developer ID Application: Alin Panaitiu (RDDXV84A73)
MACOS := 26.0
TARGET := arm64-apple-macos$(MACOS)
VENDOR ?= $(CURDIR)/vendor

# Notarization needs the hardened runtime and a secure timestamp. Debug builds skip the timestamp, which needs the network.
TIMESTAMP ?= --timestamp=none
# The flags for testing exist only in builds made with `make` or `make install`, never in a release.
DEV ?= -D MUSKEY_DEV
SIGN = codesign --force --options runtime $(TIMESTAMP) --sign "$(IDENTITY)"

VERSION ?= $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist | sed -E 's/b[0-9]+$$//')
BETA ?=
FULL_VERSION := $(VERSION)$(if $(BETA),b$(BETA))
DELTAS ?= 5

all: $(BUNDLE)

# Essentia finds the key. It is linked statically, built without ffmpeg, yaml or fftw, with Accelerate for the FFT.
ESSENTIA := $(VENDOR)/essentia
ESSENTIA_COMMIT := 66a890f285d0e1988155c12d17a2068e406cdd90
ESSENTIA_LIB := $(ESSENTIA)/build/src/libessentia.a
EIGEN := $(shell brew --prefix eigen)/include/eigen3
CXXFLAGS := -std=c++17 -O2 -target $(TARGET) -I$(ESSENTIA)/src -I$(ESSENTIA)/src/essentia -I$(EIGEN) -DEIGEN_MPL2_ONLY -w

$(ESSENTIA):
	git init -q $@ && git -C $@ fetch -q --depth 1 https://github.com/MTG/essentia.git $(ESSENTIA_COMMIT) && git -C $@ checkout -q FETCH_HEAD

$(ESSENTIA_LIB): | $(ESSENTIA)
	cd $(ESSENTIA) && MACOSX_DEPLOYMENT_TARGET=$(MACOS) python3 waf configure --build-static --lightweight= --fft=ACCELERATE \
		&& MACOSX_DEPLOYMENT_TARGET=$(MACOS) python3 waf -j8

$(BUILD)/obj/ekshim.o: Sources/ekshim.cpp Sources/ekshim.h $(ESSENTIA_LIB)
	@mkdir -p $(@D)
	clang++ $(CXXFLAGS) -c $< -o $@

# Rubber Band 4.0.0 changes the pitch, built from its single-file unit with the vDSP FFT.
RUBBERBAND := $(VENDOR)/rubberband
RBFLAGS := -std=c++17 -O3 -target $(TARGET) -DNDEBUG -I$(RUBBERBAND)

RUBBERBAND_COMMIT := 1d95888bec3ae0a17c0c4af791810d5a63f6bc35

$(RUBBERBAND):
	git init -q $@ && git -C $@ fetch -q --depth 1 https://github.com/breakfastquay/rubberband.git $(RUBBERBAND_COMMIT) && git -C $@ checkout -q FETCH_HEAD

$(BUILD)/obj/rubberband.o: | $(RUBBERBAND)
	@mkdir -p $(@D)
	clang++ $(RBFLAGS) -w -c $(RUBBERBAND)/single/RubberBandSingle.cpp -o $@

$(BUILD)/obj/pitch.o: Sources/pitch.cpp Sources/pitch.h | $(RUBBERBAND)
	@mkdir -p $(@D)
	clang++ $(RBFLAGS) -c $< -o $@

# whisper.cpp 1.9.5 turns speech into text with a time for each word, on the GPU through Metal. It is linked statically
# with the Metal shaders embedded, so the app needs no extra files next to it. GGML_NATIVE is off because it would tune
# the CPU code for the Mac that builds it, and a newer chip's instructions crash older Apple Silicon. OpenMP is off so
# the app never depends on a Homebrew libomp.
WHISPER := $(VENDOR)/whisper.cpp
WHISPER_COMMIT := d1be6fde11ac6e0407606b4e42fe72d34add8037
WHISPER_BUILD := $(WHISPER)/build
WHISPER_LIB := $(WHISPER_BUILD)/src/libwhisper.a
WHISPER_LIBS := $(WHISPER_LIB) $(addprefix $(WHISPER_BUILD)/ggml/src/,libggml.a libggml-base.a libggml-cpu.a \
	ggml-metal/libggml-metal.a ggml-blas/libggml-blas.a)
WHISPER_INCLUDES := -Xcc -I$(WHISPER)/include -Xcc -I$(WHISPER)/ggml/include

$(WHISPER):
	git init -q $@ && git -C $@ fetch -q --depth 1 https://github.com/ggml-org/whisper.cpp.git $(WHISPER_COMMIT) && git -C $@ checkout -q FETCH_HEAD

$(WHISPER_LIB): | $(WHISPER)
	cmake -S $(WHISPER) -B $(WHISPER_BUILD) -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$(MACOS) -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
		-DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_SERVER=OFF
	cmake --build $(WHISPER_BUILD) --config Release --target whisper -j8

# Sparkle checks for updates. The release archive holds the framework and the appcast tools.
SPARKLE_VERSION := 2.10.1
SPARKLE_SHA256 := 1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE := $(VENDOR)/Sparkle-$(SPARKLE_VERSION)
SPARKLE_FRAMEWORK := $(BUNDLE)/Contents/Frameworks/Sparkle.framework

$(SPARKLE):
	@mkdir -p $(VENDOR)
	curl -fsSL -o $@.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
	echo "$(SPARKLE_SHA256)  $@.tar.xz" | shasum -a 256 -c -
	mkdir -p $@ && tar -xJf $@.tar.xz -C $@ && rm $@.tar.xz

# Reads the song that is playing through the private MediaRemote framework. mediaremoted answers only code signed
# with a com.apple. identifier, so the helper is signed as one.
HELPER := com.apple.controlcenter.Muskey.NowPlaying

$(BUILD)/obj/$(HELPER): Helper/*.swift
	@mkdir -p $(@D)
	swiftc -O -target $(TARGET) Helper/*.swift -o $@

# Plays the songs that Muskey opens, as an app of its own, so that Now Playing and Muskey's taps hear it like any player.
PLAYER := Muskey Player
PLAYER_APP := $(BUNDLE)/Contents/Helpers/$(PLAYER).app

$(BUILD)/obj/player: Player/*.swift
	@mkdir -p $(@D)
	swiftc -O -target $(TARGET) Player/*.swift -o $@

$(BUILD)/obj/Assets.car: muskey.icon/icon.json muskey.icon/Assets/*
	@mkdir -p $(@D)
	xcrun actool muskey.icon --compile $(@D) --app-icon muskey --platform macosx --target-device mac \
		--minimum-deployment-target $(MACOS) --output-partial-info-plist $(@D)/icon.plist >/dev/null

$(BUNDLE): Sources/*.swift Sources/*.h Info.plist $(BUILD)/obj/ekshim.o $(BUILD)/obj/pitch.o $(BUILD)/obj/rubberband.o \
		$(BUILD)/obj/$(HELPER) $(BUILD)/obj/player Player/Info.plist $(BUILD)/obj/Assets.car $(WHISPER_LIB) | $(SPARKLE)
	rm -rf $@
	mkdir -p $@/Contents/MacOS $@/Contents/Helpers $@/Contents/Frameworks $@/Contents/Resources
	swiftc -O -target $(TARGET) $(DEV) -parse-as-library -import-objc-header Sources/bridge.h $(WHISPER_INCLUDES) -F $(SPARKLE) \
		Sources/*.swift $(BUILD)/obj/ekshim.o $(BUILD)/obj/pitch.o $(BUILD)/obj/rubberband.o $(ESSENTIA_LIB) $(WHISPER_LIBS) \
		-lc++ -framework Accelerate -framework Metal -framework MetalKit -framework Foundation -framework Sparkle \
		-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
		-o $@/Contents/MacOS/$(APP)
	cp Info.plist $@/Contents/Info.plist
	cp $(BUILD)/obj/Assets.car $(BUILD)/obj/muskey.icns $@/Contents/Resources/
	ditto $(SPARKLE)/Sparkle.framework $(SPARKLE_FRAMEWORK)
	# The XPC services are only for sandboxed apps.
	rm -rf $(SPARKLE_FRAMEWORK)/XPCServices $(SPARKLE_FRAMEWORK)/Versions/B/XPCServices
	$(SIGN) $(SPARKLE_FRAMEWORK)/Versions/B/Autoupdate
	$(SIGN) $(SPARKLE_FRAMEWORK)/Versions/B/Updater.app
	$(SIGN) $(SPARKLE_FRAMEWORK)
	cp $(BUILD)/obj/$(HELPER) $@/Contents/Helpers/
	$(SIGN) --identifier com.apple.controlcenter.Muskey $@/Contents/Helpers/$(HELPER)
	mkdir -p "$(PLAYER_APP)/Contents/MacOS" "$(PLAYER_APP)/Contents/Resources"
	cp $(BUILD)/obj/player "$(PLAYER_APP)/Contents/MacOS/$(PLAYER)"
	sed "s/1\.0\.1/$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)/" Player/Info.plist > "$(PLAYER_APP)/Contents/Info.plist"
	cp $(BUILD)/obj/Assets.car $(BUILD)/obj/muskey.icns "$(PLAYER_APP)/Contents/Resources/"
	$(SIGN) "$(PLAYER_APP)"
	$(SIGN) $@

install: $(BUNDLE)
	killall "$(APP)" || true
	rm -rf "$(INSTALL_DIR)/$(APP).app"
	ditto $(BUNDLE) "$(INSTALL_DIR)/$(APP).app"
	open "$(INSTALL_DIR)/$(APP).app"

clean:
	rm -rf $(BUILD)

# Release

RELEASE_CSS_URL := https://files.lowtechguys.com/release.css
RELEASE_CSS = $(RELEASE_CSS_URL)?v=$(shell curl -fsS $(RELEASE_CSS_URL) | md5 -q | cut -c1-8)
GENERATE_APPCAST := $(SPARKLE)/bin/generate_appcast
# The update signing key comes from 1Password on stdin, so generate_appcast never waits on a keychain prompt.
SPARKLE_KEY ?= Scripts/op-env.sh op read -n "op://Agent/Sparkle ed25519 update key/credential"
APPCAST_FLAGS := --ed-key-file - --maximum-versions 10 --link "https://lowtechguys.com/muskey" \
	--full-release-notes-url "https://files.lowtechguys.com/muskey/changelog.html" \
	--release-notes-url-prefix https://files.lowtechguys.com/ReleaseNotes/ \
	--download-url-prefix "https://files.lowtechguys.com/releases/"
UPLOAD_SSH := ssh -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
UPLOAD_RSYNC := rsync -a --partial-dir=.rsync-partial -e "$(UPLOAD_SSH)"

setversion:
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(FULL_VERSION)" -c "Set :CFBundleVersion $(FULL_VERSION)" Info.plist

# The release targets run on the author's Mac: make-app notarizes and staples the app, then makes, notarizes and staples the DMG.
build: SHELL := fish
build: setversion
	rm -rf $(BUILD)
	$(MAKE) $(BUNDLE) TIMESTAMP=--timestamp DEV=
	rm -rf /tmp/apps/$(APP).app
	mkdir -p /tmp/apps Releases
	ditto $(BUNDLE) /tmp/apps/$(APP).app
	make-app --dmg --version $(FULL_VERSION) /tmp/apps/$(APP).app
	cp /tmp/apps/$(APP)-$(FULL_VERSION).dmg Releases/

CHANGELOG.md: $(wildcard ReleaseNotes/*.md)
	tail -n +1 $$(ls ReleaseNotes/*.md | egrep '/[0-9]+(\.[0-9]+)*\.md$$' | sort -Vr) \
		| sed -E 's|==> ReleaseNotes/(.+)\.md <==|# \1\n\n**[Download $(APP) \1 →](https://files.lowtechguys.com/releases/$(APP)-\1.dmg)**|' > $@

Releases/changelog.html: CHANGELOG.md
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="$(APP) Changelog" --css "$(RELEASE_CSS)" $<

Releases/$(APP)-%.html: ReleaseNotes/$(VERSION).md
	pandoc -f gfm --section-divs -o $@ --standalone --metadata title="$(APP) $(FULL_VERSION) - Release Notes" --css "$(RELEASE_CSS)" $<

appcast: Releases/$(APP)-$(FULL_VERSION).html Releases/changelog.html | $(SPARKLE)
	rm -f Releases/$(APP).dmg Releases/$(APP)$(FULL_VERSION)*.delta
ifneq (, $(BETA))
	$(SPARKLE_KEY) | $(GENERATE_APPCAST) $(APPCAST_FLAGS) --channel beta --maximum-deltas 0 -o Releases/appcast.xml Releases
else
	rm -f Releases/$(APP)-*b*.dmg Releases/$(APP)*b*.delta
	$(SPARKLE_KEY) | $(GENERATE_APPCAST) $(APPCAST_FLAGS) --maximum-deltas $(DELTAS) -o Releases/appcast.xml Releases
	cp Releases/$(APP)-$(FULL_VERSION).dmg Releases/$(APP).dmg
endif

# The appcast goes up last, so it never points at a file that isn't there yet.
upload:
	$(UPLOAD_RSYNC) --progress $(filter-out Releases/$(APP).dmg,$(wildcard Releases/*.dmg)) $(wildcard Releases/*.delta) hetzner:/static/lowtechguys/releases/
	$(UPLOAD_RSYNC) -vz Releases/$(APP)-*.html hetzner:/static/lowtechguys/ReleaseNotes/
ifeq (, $(BETA))
	$(UPLOAD_SSH) hetzner 'cd /static/lowtechguys/releases && ln -f $(APP)-$(VERSION).dmg .$(APP).dmg && mv -f .$(APP).dmg $(APP).dmg'
endif
	$(UPLOAD_RSYNC) -vz Releases/appcast.xml Releases/changelog.html hetzner:/static/lowtechguys/muskey/
	cfcli -d lowtechguys.com purge

release:
	gh release create v$(VERSION) -F ReleaseNotes/$(VERSION).md "Releases/$(APP)-$(VERSION).dmg#$(APP).dmg"
	git fetch --tags

.PHONY: all install clean setversion build appcast upload release stems-model winds-model

# The Core ML models behind the stems. Each prints the size and the SHA-256 of its zip, which go into ModelDownload.
# stems-model: BS-Roformer-SW, from its checkpoint and YAML config.
# winds-model: the woodwind and brass heads of MVSep's 53-stem BS-RoFormer, which find the winds in the song and play as one Winds stem.
STEMS_VENV := $(BUILD)/stems-venv
$(STEMS_VENV)/bin/python:
	python3 -m venv $(STEMS_VENV) && $(STEMS_VENV)/bin/pip install -q torch==2.7.1 coremltools==9.0 pyyaml numpy
stems-model: $(STEMS_VENV)/bin/python
	@test -n "$(CKPT)" -a -n "$(YAML)" || (echo "usage: make stems-model CKPT=BS-Roformer-SW.ckpt YAML=BS-Roformer-SW.yaml" && exit 1)
	cd Scripts/stems-model && $(STEMS_VENV)/bin/python convert.py "$(abspath $(CKPT))" "$(abspath $(YAML))" $(BUILD)/stems-model BSRoformerSW
winds-model: $(STEMS_VENV)/bin/python
	@test -n "$(CKPT)" -a -n "$(YAML)" || (echo "usage: make winds-model CKPT=mvsep_mega_model_bs_roformer_53_stems_v1.ckpt YAML=mvsep_mega_model_bs_roformer_53_stems.yaml" && exit 1)
	cd Scripts/stems-model && $(STEMS_VENV)/bin/python convert.py "$(abspath $(CKPT))" "$(abspath $(YAML))" $(BUILD)/stems-model BSRoformerWinds woodwind,brass
