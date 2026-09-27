SCRATCH_PATH ?= $(HOME)/.swiftbuild/News

.PHONY: all build release test run clean app

all: build

build:
	@mkdir -p $(SCRATCH_PATH)
	swift build --scratch-path $(SCRATCH_PATH)

release:
	@mkdir -p $(SCRATCH_PATH)
	swift build -c release --scratch-path $(SCRATCH_PATH)

run:
	./script/build_and_run.sh

app:
	./build.sh

test:
	./test.sh

clean:
	rm -rf $(SCRATCH_PATH) .build
