ODIN ?= odin
BIN := bin/zclaude
SRC := $(wildcard src/*.odin) src/agent.js
PREFIX ?= $(HOME)/.local
VET := -vet-unused -vet-shadowing

.PHONY: all debug release test integration clean install

all: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	$(ODIN) build src -out:$(BIN) -o:speed $(VET)

debug: $(SRC)
	@mkdir -p bin
	$(ODIN) build src -out:bin/zclaude-debug -debug

# Optimized and stripped. Bounds checks stay on: a bug should stop zclaude, not
# corrupt the session it is driving.
release: $(SRC)
	@mkdir -p bin
	$(ODIN) build src -out:bin/zclaude-release -o:aggressive $(VET)
	strip bin/zclaude-release

# Unit tests share the session globals, so they run on one thread.
test:
	$(ODIN) test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -out:bin/zclaude-test

# Drives real Claude Code sessions on Haiku. Needs a logged-in `claude` and python3.
integration: $(BIN)
	cd .. && bun test --timeout 240000 zclaude/tests

install: release
	install -d $(PREFIX)/bin
	install -m 0755 bin/zclaude-release $(PREFIX)/bin/zclaude

clean:
	rm -rf bin
