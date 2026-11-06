.PHONY: all build release test run clean app

all: build

build:
	./build.sh

release:
	./build_release.sh

run:
	./script/build_and_run.sh

app:
	./build.sh

test:
	./test.sh

clean:
	rm -rf -- .build build/DerivedData News.app "News Dev.app" NewsHarness.app
