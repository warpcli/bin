SHELL := /bin/bash

PROJECT_NAME := $(shell if [ -f PROJECT ]; then sed -n '/^[[:space:]]*[^#\[[:space:]]/p' PROJECT | head -1 | tr -d '[:space:]'; else sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' dub.json | head -1; fi)
PROJECT_VERSION := $(shell if [ -f PROJECT ]; then sed -n '/^[[:space:]]*[^#\[[:space:]]/p' PROJECT | sed -n '2p' | tr -d '[:space:]'; else cat VERSION | tr -d '[:space:]'; fi)
ifeq ($(PROJECT_NAME),)
    $(error Error: could not determine project name from PROJECT or dub.json)
endif

TOP_DIR := $(CURDIR)
DUB := dub
DC ?= ldc2
PREFIX ?= $(HOME)/.local
ARGS ?=
BUILD_TYPE ?= release

HAS_REL := $(shell command -v git-rel 2>/dev/null)
HAS_CLIFF := $(shell command -v git-cliff 2>/dev/null)

$(info ------------------------------------------)
$(info Project: $(PROJECT_NAME) v$(PROJECT_VERSION))
$(info ------------------------------------------)

.PHONY: build b compile c run r install uninstall test t test-all cover check static \
	fmt fmt-check clean changelog verify release help h

build:
	@$(DUB) build --compiler=$(DC) --build=$(BUILD_TYPE)

b: build

compile: clean build

c: compile

run:
	@$(DUB) run --compiler=$(DC) --build=debug -- $(ARGS)

r: run

install: build
	@install -d $(PREFIX)/bin
	@install -m 0755 $(PROJECT_NAME) $(PREFIX)/bin/$(PROJECT_NAME)
	@echo "installed -> $(PREFIX)/bin/$(PROJECT_NAME)"

uninstall:
	@rm -f $(PREFIX)/bin/$(PROJECT_NAME)
	@echo "removed -> $(PREFIX)/bin/$(PROJECT_NAME)"

test:
	@$(DUB) test --compiler=$(DC)

t: test

test-all: test

cover:
	@$(DUB) test --compiler=$(DC) --build=unittest-cov
	@echo "coverage written to *.lst"

check: test

# A static build needs musl static archives for openssl, lzma, bzip2 and zstd.
# The release workflow does this inside an Alpine container; locally you need
# the same packages installed (openssl-libs-static xz-static bzip2-static
# zstd-static zlib-static).
static:
	@$(DUB) upgrade --missing-only >/dev/null 2>&1 || true
	@./scripts/patch-requests-static.sh
	@$(DUB) build --compiler=$(DC) --build=$(BUILD_TYPE) --config=static
	@$(MAKE) --no-print-directory verify-static

# verify-static fails if the built binary still needs a dynamic loader or any
# shared library. Without the check a partially static build looks fine on the
# machine that produced it and breaks everywhere else.
verify-static:
	@if ! command -v readelf >/dev/null 2>&1; then \
		echo "readelf not found; skipping static check"; exit 0; \
	fi
	@if readelf -d $(PROJECT_NAME) 2>/dev/null | grep -q NEEDED; then \
		echo "FAIL: $(PROJECT_NAME) is dynamically linked:"; \
		readelf -d $(PROJECT_NAME) | grep NEEDED; \
		exit 1; \
	fi
	@if readelf -l $(PROJECT_NAME) 2>/dev/null | grep -q INTERP; then \
		echo "FAIL: $(PROJECT_NAME) requests a dynamic loader:"; \
		readelf -l $(PROJECT_NAME) | grep -A1 INTERP; \
		exit 1; \
	fi
	@echo "$(PROJECT_NAME): statically linked, no libc dependency"

# dfmt is the dlang-community formatter, fetched through dub. The `dfmt` in
# some distro repos is an unrelated docstring tool, so it is run via dub.
fmt:
	@for f in $$(find source -name '*.d'); do $(DUB) run -q dfmt -- --inplace "$$f"; done

fmt-check:
	@out=""; \
	for f in $$(find source -name '*.d'); do \
		if ! $(DUB) run -q dfmt -- "$$f" | diff -q - "$$f" >/dev/null; then out="$$out $$f"; fi; \
	done; \
	if [ -n "$$out" ]; then echo "dfmt needed on:$$out"; exit 1; fi; \
	echo "formatting ok"

clean:
	@$(DUB) clean >/dev/null 2>&1 || true
	@rm -f $(PROJECT_NAME) $(PROJECT_NAME)-test-* *.lst

changelog:
	@if [ -z "$(HAS_CLIFF)" ]; then \
		echo "git-cliff is not installed. Please install it first."; \
		exit 1; \
	fi
	@git cliff -o CHANGELOG.md

verify: fmt-check test

release:
	@if [ -z "$(HAS_REL)" ]; then \
		echo "git-rel is not installed. Please install it first."; \
		exit 1; \
	fi
	@if [ -z "$(TYPE)" ]; then \
		echo "Release type not specified. Use 'make release TYPE=[patch|minor|major|M.m.p]'"; \
		exit 1; \
	fi
	@git rel $(TYPE)

help:
	@echo
	@echo "Usage: make [target]"
	@echo
	@echo "Available targets:"
	@echo "  build         Build the binary (./$(PROJECT_NAME))"
	@echo "  compile       Clean and rebuild"
	@echo "  run           Run locally (pass args with ARGS=...)"
	@echo "  install       Install to \$$PREFIX/bin (default ~/.local/bin)"
	@echo "  uninstall     Remove the installed binary"
	@echo "  test          Run the unit tests"
	@echo "  cover         Run tests with coverage"
	@echo "  static        Build fully static (needs musl static libs) and verify"
	@echo "  verify-static Check an existing binary has no libc dependency"
	@echo "  fmt           Format the tree with dfmt"
	@echo "  fmt-check     Fail if anything is unformatted"
	@echo "  clean         Remove build artifacts"
	@echo "  changelog     Regenerate CHANGELOG.md (git-cliff)"
	@echo "  verify        Run the local gate (fmt-check + test)"
	@echo "  release       Release a new version (git-rel)"
	@echo
	@echo "Examples:"
	@echo "  make run ARGS='list -t all'"
	@echo "  make install PREFIX=/usr/local"
	@echo "  make release TYPE=minor"
	@echo

h: help
