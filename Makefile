.PHONY: build release app run clean install lint

APP := dist/Matrix.app

build:
	swift build

release:
	swift build -c release

app:
	bash scripts/build_app.sh

universal:
	UNIVERSAL=1 bash scripts/build_app.sh

run: app
	open $(APP)

install: app
	rm -rf /Applications/Matrix.app
	cp -R $(APP) /Applications/
	open /Applications/Matrix.app

clean:
	rm -rf .build dist

lint:
	@echo "swift-format 可选，未安装则跳过"
	@which swift-format >/dev/null 2>&1 && swift-format lint -r Sources || true
