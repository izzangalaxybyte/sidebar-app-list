.PHONY: build app run clean

build:
	swift build

app:
	Scripts/bundle.sh release

run: app
	open build/SidebarAppList.app

clean:
	rm -rf .build build
