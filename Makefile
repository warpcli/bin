SHELL := /bin/bash

PROJECT_NAME := $(shell if [ -f PROJECT ]; then sed -n '/^[[:space:]]*[^#\[[:space:]]/p' PROJECT | head -1 | tr -d '[:space:]'; else basename "$$(sed -n 's/^module[[:space:]]*//p' go.mod)"; fi)
PROJECT_VERSION := $(shell if [ -f PROJECT ]; then sed -n '/^[[:space:]]*[^#\[[:space:]]/p' PROJECT | sed -n '2p' | tr -d '[:space:]'; else sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' src/main.go | head -1; fi)
ifeq ($(PROJECT_NAME),)
    $(error Error: could not determine project name from PROJECT or go.mod)
endif

TOP_DIR := $(CURDIR)
GO := go
PREFIX ?= $(HOME)/.local
ARGS ?=

# bin is pure Go, so cgo buys it nothing and costs portability. With cgo enabled
# the net package links the system resolver, and the binary picks up a hard
# dependency on the build host's libc — on Nix that is an absolute /nix/store
# path, so the result only runs on the machine that built it. Disabling cgo
# produces a fully static binary with no libc dependency at all (neither glibc
# nor musl), which is also what .github/workflows/release.yml builds.
# Override with `make build CGO_ENABLED=1` if you ever genuinely need cgo.
CGO_ENABLED ?= 0
export CGO_ENABLED

GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)
BUILD_DATE := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS := -s -w \
	-X main.version=$(PROJECT_VERSION) \
	-X main.commit=$(GIT_COMMIT) \
	-X main.date=$(BUILD_DATE) \
	-X main.builtBy=make

HAS_REL := $(shell command -v git-rel 2>/dev/null)
HAS_CLIFF := $(shell command -v git-cliff 2>/dev/null)

$(info ------------------------------------------)
$(info Project: $(PROJECT_NAME) v$(PROJECT_VERSION))
$(info ------------------------------------------)

.PHONY: build b compile c run r install uninstall test t test-all cover check static vet fmt fmt-check tidy clean changelog verify release help h

build:
	@$(GO) build -trimpath -ldflags "$(LDFLAGS)" -o $(PROJECT_NAME) ./src

b: build

compile:
	@$(GO) clean
	@$(MAKE) build

c: compile

run:
	@$(GO) run ./src $(ARGS)

r: run

install: build
	@install -d $(PREFIX)/bin
	@install -m 0755 $(PROJECT_NAME) $(PREFIX)/bin/$(PROJECT_NAME)
	@echo "installed -> $(PREFIX)/bin/$(PROJECT_NAME)"

uninstall:
	@rm -f $(PREFIX)/bin/$(PROJECT_NAME)
	@echo "removed -> $(PREFIX)/bin/$(PROJECT_NAME)"

test:
	@$(GO) test ./...

t: test

test-all:
	@$(GO) test -race -count=1 ./...

cover:
	@$(GO) test -coverprofile=coverage.out ./...
	@$(GO) tool cover -func=coverage.out

check: vet

# static verifies the built binary has no dynamic library dependencies. A Go
# binary that accidentally links libc still runs fine on the build host, so the
# regression is invisible without an explicit check.
static: build
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

vet:
	@$(GO) vet ./...

fmt:
	@gofmt -w .
	@$(GO) mod tidy

fmt-check:
	@out="$$(gofmt -l .)"; \
	if [ -n "$$out" ]; then echo "gofmt needed on:"; echo "$$out"; exit 1; fi

tidy:
	@$(GO) mod tidy

clean:
	@$(GO) clean
	@rm -f $(PROJECT_NAME) coverage.out

changelog:
	@if [ -z "$(HAS_CLIFF)" ]; then \
		echo "git-cliff is not installed. Please install it first."; \
		exit 1; \
	fi
	@git cliff -o CHANGELOG.md

verify: fmt-check vet test static

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
	@echo "  build        Build the binary (./$(PROJECT_NAME))"
	@echo "  compile      Clean and rebuild"
	@echo "  run          Run locally (pass args with ARGS=...)"
	@echo "  install      Install to \$$PREFIX/bin (default ~/.local/bin)"
	@echo "  uninstall    Remove the installed binary"
	@echo "  test         Run all tests"
	@echo "  test-all     Run tests with the race detector"
	@echo "  cover        Run tests and print coverage"
	@echo "  vet          Run go vet"
	@echo "  static       Verify the binary has no libc dependency"
	@echo "  fmt          Format the tree and tidy modules"
	@echo "  fmt-check    Fail if anything is unformatted"
	@echo "  tidy         Tidy go.mod/go.sum"
	@echo "  clean        Remove build artifacts"
	@echo "  changelog    Regenerate CHANGELOG.md (git-cliff)"
	@echo "  verify       Run the full local gate (fmt-check + vet + test + static)"
	@echo "  release      Release a new version (git-rel)"
	@echo
	@echo "Examples:"
	@echo "  make run ARGS='list -t all'"
	@echo "  make install PREFIX=/usr/local"
	@echo "  make release TYPE=minor"
	@echo

h: help
