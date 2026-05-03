APP := twelvgaige
VERSION := $(shell awk -F'"' '/version:/ {print $$2; exit}' mix.exs)

ARTIFACT_DIR ?= artifacts
ARTIFACT_SUFFIX ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
NATIVE_RELEASE := twelvgaige_native
BUMP ?= patch
RELEASE_VERSION ?=

UNAME_S := $(shell uname -s 2>/dev/null || echo unknown)
UNAME_M := $(shell uname -m 2>/dev/null || echo unknown)

ifeq ($(UNAME_S),Darwin)
BURRITO_TARGET ?= macos_silicon
else ifeq ($(UNAME_S),Linux)
ifeq ($(UNAME_M),aarch64)
BURRITO_TARGET ?= linux_arm64
else ifeq ($(UNAME_M),arm64)
BURRITO_TARGET ?= linux_arm64
else
BURRITO_TARGET ?= linux
endif
else
BURRITO_TARGET ?= linux
endif

SMOKE_WORKFLOW_YAML := docs/traphouse/workflows/simple.yaml
SMOKE_WORKFLOW_JSON := docs/traphouse/workflows/simple.json
SMOKE_WORKFLOW_TOML := docs/traphouse/workflows/simple.toml
SMOKE_BIN ?= ./$(APP)
SMOKE_TMP ?= /tmp/$(APP)-smoke-$(ARTIFACT_SUFFIX)
SMOKE_ENV ?=

NATIVE_BIN := _build/prod/rel/$(NATIVE_RELEASE)/bin/$(APP)
NATIVE_TARBALL := _build/prod/$(NATIVE_RELEASE)-$(VERSION).tar.gz

BURRITO_EXT :=
ifeq ($(BURRITO_TARGET),windows)
BURRITO_EXT := .exe
endif
BURRITO_BIN := burrito_out/$(APP)_$(BURRITO_TARGET)$(BURRITO_EXT)
RELEASE_ARGS := $(if $(RELEASE_VERSION),--version $(RELEASE_VERSION),--bump $(BUMP))

.DEFAULT_GOAL := help

.PHONY: help
help:
	@printf "%s\n" "$(APP) $(VERSION)"
	@printf "%s\n" ""
	@printf "%s\n" "Local development:"
	@printf "%s\n" "  make setup             Fetch dependencies"
	@printf "%s\n" "  make check             Format check, compile, unit tests"
	@printf "%s\n" "  make typecheck         Run Dialyzer via Dialyxir"
	@printf "%s\n" "  make test-local        Run default local test suite"
	@printf "%s\n" "  make smoke             Build escript and run CLI smoke checks"
	@printf "%s\n" ""
	@printf "%s\n" "Builds:"
	@printf "%s\n" "  make build             Build escript and native Mix release"
	@printf "%s\n" "  make escript           Build ./$(APP)"
	@printf "%s\n" "  make release           Build native Mix release"
	@printf "%s\n" "  make burrito           Build Burrito executable for BURRITO_TARGET=$(BURRITO_TARGET)"
	@printf "%s\n" ""
	@printf "%s\n" "Release/package:"
	@printf "%s\n" "  make package-local     Build, smoke, and package local escript/native artifacts"
	@printf "%s\n" "  make package-burrito-smoke BURRITO_TARGET=$(BURRITO_TARGET)"
	@printf "%s\n" "  make checksums         Regenerate artifact metadata and SHA256SUMS"
	@printf "%s\n" "  make release-plan      Show next git tag/version without changing files"
	@printf "%s\n" "  make release-tag       Bump version, commit, and create local tag"
	@printf "%s\n" "  make release-github    Run checks, bump version, tag, and push to trigger GitHub release"
	@printf "%s\n" "                         Use BUMP=patch|minor|major or RELEASE_VERSION=X.Y.Z"
	@printf "%s\n" ""
	@printf "%s\n" "Cleaning:"
	@printf "%s\n" "  make clean             Remove build outputs and artifacts"

.PHONY: all
all: ci

.PHONY: setup deps
setup: deps

deps:
	mix deps.get

.PHONY: compile
compile:
	MIX_ENV=test mix compile --warnings-as-errors

.PHONY: format-check
format-check:
	mix format --check-formatted

.PHONY: test
test:
	MIX_ENV=test mix test

.PHONY: test-local
test-local: test

.PHONY: typecheck dialyzer
typecheck: dialyzer

dialyzer:
	MIX_ENV=dev mix dialyzer

.PHONY: test-all
test-all:
	MIX_ENV=test mix test --include integration --include daemon --include persistence --include slow

.PHONY: test-persistence
test-persistence:
	MIX_ENV=test mix test --include persistence

.PHONY: check
check: format-check compile test

.PHONY: ci
ci: deps format-check compile test test-persistence

.PHONY: build
build: escript release

.PHONY: escript
escript: deps
	mix escript.build

.PHONY: smoke
smoke: escript-smoke

.PHONY: escript-smoke
escript-smoke: escript
	$(MAKE) smoke-shell-formats SMOKE_BIN=./$(APP)

.PHONY: smoke-shell-formats
smoke-shell-formats:
	rm -rf $(SMOKE_TMP)
	mkdir -p $(SMOKE_TMP)
	$(SMOKE_ENV) $(SMOKE_BIN) version
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_YAML)
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_JSON)
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_TOML)
	$(SMOKE_ENV) $(SMOKE_BIN) shell normalize $(SMOKE_WORKFLOW_TOML) --format json > $(SMOKE_TMP)/normalized.json
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_TMP)/normalized.json
	$(SMOKE_ENV) $(SMOKE_BIN) shell convert $(SMOKE_WORKFLOW_YAML) --to toml > $(SMOKE_TMP)/converted.toml
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_TMP)/converted.toml
	$(SMOKE_ENV) $(SMOKE_BIN) shell convert $(SMOKE_WORKFLOW_TOML) --to yaml > $(SMOKE_TMP)/converted.yaml
	$(SMOKE_ENV) $(SMOKE_BIN) shell validate $(SMOKE_TMP)/converted.yaml
	$(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_YAML)
	$(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_JSON)
	$(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_TOML)

.PHONY: release
release: deps
	MIX_ENV=prod mix release $(NATIVE_RELEASE) --overwrite

.PHONY: release-smoke
release-smoke: release
	$(MAKE) smoke-shell-formats SMOKE_BIN=$(NATIVE_BIN)
	TWELVGAIGE_STORE_SQLITE=/tmp/$(APP)-native-release-$(ARTIFACT_SUFFIX).sqlite3 $(NATIVE_BIN) round run $(SMOKE_WORKFLOW_TOML)

.PHONY: burrito
burrito: deps
	MIX_ENV=prod BURRITO_TARGET=$(BURRITO_TARGET) mix release $(APP) --overwrite

.PHONY: burrito-smoke
burrito-smoke: burrito burrito-smoke-only

.PHONY: burrito-smoke-only
burrito-smoke-only:
	$(MAKE) smoke-shell-formats SMOKE_BIN=$(BURRITO_BIN) SMOKE_TMP=/tmp/$(APP)-burrito-smoke-$(BURRITO_TARGET) SMOKE_ENV='TWELVGAIGE_INSTALL_DIR=/tmp/$(APP)-burrito-smoke-$(BURRITO_TARGET)/install'
	TWELVGAIGE_INSTALL_DIR=/tmp/$(APP)-burrito-smoke-$(BURRITO_TARGET)/install TWELVGAIGE_STORE_SQLITE=/tmp/$(APP)-burrito-release-$(BURRITO_TARGET).sqlite3 $(BURRITO_BIN) round run $(SMOKE_WORKFLOW_TOML)

.PHONY: package-escript
package-escript: escript-smoke
	mkdir -p $(ARTIFACT_DIR)/escript
	cp $(APP) $(ARTIFACT_DIR)/escript/$(APP)-escript-$(VERSION)-$(ARTIFACT_SUFFIX)

.PHONY: package-release
package-release: release-smoke
	mkdir -p $(ARTIFACT_DIR)/mix-release
	cp $(NATIVE_TARBALL) $(ARTIFACT_DIR)/mix-release/$(NATIVE_RELEASE)-$(VERSION)-$(ARTIFACT_SUFFIX).tar.gz

.PHONY: package-burrito
package-burrito:
	$(MAKE) burrito BURRITO_TARGET=$(BURRITO_TARGET)
	$(MAKE) package-burrito-artifact BURRITO_TARGET=$(BURRITO_TARGET)

.PHONY: package-burrito-smoke
package-burrito-smoke:
	$(MAKE) burrito BURRITO_TARGET=$(BURRITO_TARGET)
	$(MAKE) burrito-smoke-only BURRITO_TARGET=$(BURRITO_TARGET)
	$(MAKE) package-burrito-artifact BURRITO_TARGET=$(BURRITO_TARGET)

.PHONY: package-burrito-artifact
package-burrito-artifact:
	mkdir -p $(ARTIFACT_DIR)/burrito
	cp $(BURRITO_BIN) $(ARTIFACT_DIR)/burrito/$(APP)-burrito-$(VERSION)-$(BURRITO_TARGET)$(BURRITO_EXT)
	$(MAKE) package-checksums

.PHONY: package-metadata
package-metadata:
	mkdir -p $(ARTIFACT_DIR)
	{ \
		printf "app=%s\n" "$(APP)"; \
		printf "version=%s\n" "$(VERSION)"; \
		printf "artifact_suffix=%s\n" "$(ARTIFACT_SUFFIX)"; \
		printf "burrito_target=%s\n" "$(BURRITO_TARGET)"; \
		printf "os=%s\n" "$$(uname -s 2>/dev/null || echo unknown)"; \
		printf "arch=%s\n" "$$(uname -m 2>/dev/null || echo unknown)"; \
		printf "git_sha=%s\n" "$$(git rev-parse --verify HEAD 2>/dev/null || echo unknown)"; \
		printf "elixir_version=%s\n" "$$(elixir -e 'IO.write(System.version())' 2>/dev/null || echo unknown)"; \
		printf "otp_release=%s\n" "$$(erl -noshell -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' 2>/dev/null || echo unknown)"; \
	} > $(ARTIFACT_DIR)/BUILD-METADATA.txt

.PHONY: package-checksums
package-checksums: package-metadata
	rm -f $(ARTIFACT_DIR)/SHA256SUMS
	cd $(ARTIFACT_DIR) && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | while read -r file; do shasum -a 256 "$$file"; done > SHA256SUMS

.PHONY: package
package: package-escript package-release package-checksums

.PHONY: package-local
package-local: package

.PHONY: checksums
checksums: package-checksums

.PHONY: release-plan
release-plan:
	elixir scripts/release.exs $(RELEASE_ARGS) --dry-run

.PHONY: release-tag
release-tag:
	elixir scripts/release.exs $(RELEASE_ARGS)

.PHONY: release-github
release-github: check
	elixir scripts/release.exs $(RELEASE_ARGS) --push

.PHONY: clean
clean:
	mix clean
	rm -rf $(ARTIFACT_DIR) burrito_out
