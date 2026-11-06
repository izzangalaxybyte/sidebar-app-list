.PHONY: build app run pkg release clean

build:
	swift build

app:
	Scripts/bundle.sh release

run: app
	open build/SidebarAppList.app

pkg: app
	Scripts/package.sh

release:
	Scripts/release.sh

clean:
	rm -rf .build build
