# Foreword build entry points.
APP := build/Release/Foreword.app

.PHONY: all project app debug eval test release clean

all: app

project:
	xcodegen generate

app: project
	xcodebuild -project Foreword.xcodeproj -scheme Foreword -configuration Release \
	  -derivedDataPath build/DerivedData build
	@mkdir -p build/Release && rm -rf $(APP) && cp -R build/DerivedData/Build/Products/Release/Foreword.app $(APP)
	@echo "Built $(APP)"

debug: project
	xcodebuild -project Foreword.xcodeproj -scheme Foreword -configuration Debug \
	  -derivedDataPath build/DerivedData build

eval:
	cd ForewordKit && swift build -c release --product foreword-eval

test:
	cd ForewordKit && swift test

release: project
	scripts/release.sh

clean:
	rm -rf build ForewordKit/.build Foreword.xcodeproj
