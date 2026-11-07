# Carrot build entry points.
APP := build/Release/Carrot.app

.PHONY: all project app debug eval test release clean

all: app

project:
	xcodegen generate

app: project
	xcodebuild -project Carrot.xcodeproj -scheme Carrot -configuration Release \
	  -derivedDataPath build/DerivedData build
	@mkdir -p build/Release && rm -rf $(APP) && cp -R build/DerivedData/Build/Products/Release/Carrot.app $(APP)
	@echo "Built $(APP)"

debug: project
	xcodebuild -project Carrot.xcodeproj -scheme Carrot -configuration Debug \
	  -derivedDataPath build/DerivedData build

eval:
	cd CarrotKit && swift build -c release --product carrot-eval

test:
	cd CarrotKit && swift test

release: project
	scripts/release.sh

clean:
	rm -rf build CarrotKit/.build Carrot.xcodeproj
