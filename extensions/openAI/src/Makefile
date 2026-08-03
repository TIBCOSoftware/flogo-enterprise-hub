# Makefile for the openAI Flogo extension activities.
#
# Quick start:
#   cp .env.example .env       # fill in OPENAI key + vector-store id
#   make test                  # all activities, unit tests only
#   make test-int              # all activities, including integration tests
#   make test-pkg PKG=imageCreate   # one package only
#
# Individual `cd activity/<name> && go test -v` still works exactly as
# before — the per-package .env (if present) still wins because each
# activity's loadEnvFile() now searches upward only when no local .env is
# found.

GO         ?= go
ACTIVITIES ?= ./activity/...
PKG        ?=

# Pass extra args through, e.g.:  make test ARGS="-count=1 -run Validate"
ARGS       ?=

.PHONY: help test test-verbose test-int test-int-verbose test-pkg \
        build vet fmt tidy clean list-pkgs env-check

help:
	@echo "Targets:"
	@echo "  test              Run all activity unit tests (RUN_INTEGRATION ignored)"
	@echo "  test-verbose      Same as 'test' with -v"
	@echo "  test-int          Run all activity tests including integration (RUN_INTEGRATION=1)"
	@echo "  test-int-verbose  Same as 'test-int' with -v"
	@echo "  test-pkg PKG=name Run tests for one activity, e.g. PKG=imageCreate"
	@echo "  build             go build ./activity/..."
	@echo "  vet               go vet ./activity/..."
	@echo "  fmt               gofmt -w on activity/"
	@echo "  tidy              go mod tidy"
	@echo "  list-pkgs         Show the activity packages discovered"
	@echo "  env-check         Print whether a .env is visible to the tests"

test:
	$(GO) test $(ARGS) $(ACTIVITIES)

test-verbose:
	$(GO) test -v $(ARGS) $(ACTIVITIES)

test-int:
	RUN_INTEGRATION=1 $(GO) test -count=1 $(ARGS) $(ACTIVITIES)

test-int-verbose:
	RUN_INTEGRATION=1 $(GO) test -v -count=1 $(ARGS) $(ACTIVITIES)

test-pkg:
ifndef PKG
	$(error "Usage: make test-pkg PKG=<activity-dir>  (e.g. PKG=imageCreate)")
endif
	$(GO) test -v $(ARGS) ./activity/$(PKG)

build:
	$(GO) build $(ACTIVITIES)

vet:
	$(GO) vet $(ACTIVITIES)

fmt:
	gofmt -w activity

tidy:
	$(GO) mod tidy

list-pkgs:
	@$(GO) list $(ACTIVITIES)

env-check:
	@if [ -f .env ]; then \
		echo "Shared .env found at $$(pwd)/.env"; \
	else \
		echo "No shared .env at $$(pwd)/.env (copy .env.example to .env)"; \
	fi
	@for d in activity/*/; do \
		if [ -f "$$d/.env" ]; then \
			echo "Per-package override: $$d/.env"; \
		fi; \
	done

clean:
	$(GO) clean $(ACTIVITIES)
