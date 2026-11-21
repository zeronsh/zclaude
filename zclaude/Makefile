ODIN ?= odin
BIN := bin/zclaude
SRC := $(wildcard src/*.odin) src/agent.js

.PHONY: all debug test integration clean install

all: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	$(ODIN) build src -out:$(BIN) -o:speed -vet-unused -vet-shadowing

debug: $(SRC)
	@mkdir -p bin
	$(ODIN) build src -out:bin/zclaude-debug -debug

# Unit tests share the session globals, so they run on one thread.
test:
	$(ODIN) test src -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -out:bin/zclaude-test

# Drives real Claude Code sessions on Haiku. Needs a logged-in `claude`.
integration: $(BIN)
	cd .. && bun test --timeout 240000 zclaude/tests

install: $(BIN)
	install -m 0755 $(BIN) $(or $(PREFIX),$(HOME)/.local)/bin/zclaude

clean:
	rm -rf bin
