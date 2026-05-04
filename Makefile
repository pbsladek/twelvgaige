APP := twelvgaige
VERSION := $(shell awk -F'"' '/version:/ {print $$2; exit}' mix.exs)

ARTIFACT_DIR ?= artifacts
ARTIFACT_SUFFIX ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
NATIVE_RELEASE := twelvgaige_native
BUMP ?= patch
RELEASE_VERSION ?=
ERL_CRASH_DUMP_DIR ?= .crash_dumps
ERL_CRASH_DUMP ?= $(ERL_CRASH_DUMP_DIR)/erl_crash.dump
export ERL_CRASH_DUMP
SQLCIPHER_PREFIX ?= $(shell prefix="$$(brew --prefix sqlcipher 2>/dev/null || true)"; if [ -n "$$prefix" ] && [ -d "$$prefix" ]; then printf "%s" "$$prefix"; fi)
SQLCIPHER_CFLAGS ?= -I$(SQLCIPHER_PREFIX)/include/sqlcipher
SQLCIPHER_LDFLAGS ?= -L$(SQLCIPHER_PREFIX)/lib -lsqlcipher
SQLCIPHER_KEY ?= dev-only-sqlcipher-spike-key
SQLCIPHER_SPIKE_PATH ?= /tmp/$(APP)-sqlcipher-spike-$(ARTIFACT_SUFFIX).db
SQLCIPHER_SMOKE_TMP ?= /tmp/$(APP)-sqlcipher-smoke-$(ARTIFACT_SUFFIX)
SQLCIPHER_STORE_KEY_ENV ?= TWELVGAIGE_SQLCIPHER_SMOKE_KEY
KEYCHAIN_LIVE ?= 0

$(shell mkdir -p "$(ERL_CRASH_DUMP_DIR)")

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
AUTHORING_ROOT ?= docs/traphouse
AUTHORING_TMP ?= /tmp/$(APP)-authoring-$(ARTIFACT_SUFFIX)
AUTHORING_BIN ?= ./$(APP)

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
	@printf "%s\n" "  make authoring-check   Run traphouse authoring docs/drift checks"
	@printf "%s\n" "  make authoring-drift   Run authoring CLI checks against a temp traphouse"
	@printf "%s\n" "  make authoring-docs    Verify authoring docs conventions"
	@printf "%s\n" "  make sqlcipher-spike-system"
	@printf "%s\n" "                         Rebuild exqlite against system SQLCipher and run the spike"
	@printf "%s\n" "  make sqlcipher-escript-smoke-system"
	@printf "%s\n" "                         Run opt-in SQLCipher CLI smoke checks with system SQLCipher"
	@printf "%s\n" "  make burrito-sqlcipher-smoke-system BURRITO_TARGET=$(BURRITO_TARGET)"
	@printf "%s\n" "                         Run opt-in SQLCipher Burrito smoke checks for a host target"
	@printf "%s\n" "  make keychain-smoke-macos KEYCHAIN_LIVE=1"
	@printf "%s\n" "                         Run opt-in live macOS Keychain backend verification"
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
check: format-check compile test authoring-docs

.PHONY: ci
ci: deps format-check compile test test-persistence

.PHONY: authoring-check
authoring-check: authoring-docs authoring-drift

.PHONY: authoring-docs
authoring-docs:
	@test -f docs/authoring.md
	@test -f docs/scaffolds.md
	@test -f docs/patches.md
	@bad="$$(find docs -type f -name '*.md' | awk '/[A-Z]/ {print}')"; \
	if [ -n "$$bad" ]; then \
		printf "%s\n" "docs markdown filenames must be lowercase:" >&2; \
		printf "%s\n" "$$bad" >&2; \
		exit 1; \
	fi

.PHONY: authoring-drift
authoring-drift: escript
	rm -rf $(AUTHORING_TMP)
	mkdir -p $(AUTHORING_TMP)
	MIX_ENV=test mix run scripts/authoring_fixture.exs $(AUTHORING_TMP)
	$(AUTHORING_BIN) shell lint $(AUTHORING_TMP)/traphouse/workflows/shell_authoring_review_readonly.yaml --root $(AUTHORING_TMP)/traphouse --strict --format json > $(AUTHORING_TMP)/lint.json
	$(AUTHORING_BIN) shell inventory $(AUTHORING_TMP)/traphouse --root $(AUTHORING_TMP)/traphouse --format json > $(AUTHORING_TMP)/inventory.json
	$(AUTHORING_BIN) shot library verify --root $(AUTHORING_TMP)/traphouse --format json > $(AUTHORING_TMP)/shot-library.json
	$(AUTHORING_BIN) shell scaffold verify --root $(AUTHORING_TMP)/traphouse --format json > $(AUTHORING_TMP)/scaffold-library.json
	$(AUTHORING_BIN) shell author review $(AUTHORING_TMP)/traphouse/workflows/simple.yaml --root $(AUTHORING_TMP)/traphouse --format json > $(AUTHORING_TMP)/author-review.json
	$(AUTHORING_BIN) shell patch inspect $(AUTHORING_TMP)/patch.json --root $(AUTHORING_TMP)/traphouse --format json > $(AUTHORING_TMP)/patch-inspect.json
	$(AUTHORING_BIN) shell patch verify $(AUTHORING_TMP)/patch.json --root $(AUTHORING_TMP)/traphouse --approval $(AUTHORING_TMP)/approval.json --format json > $(AUTHORING_TMP)/patch-verify.json
	$(AUTHORING_BIN) shell patch apply $(AUTHORING_TMP)/patch.json --root $(AUTHORING_TMP)/traphouse --approval $(AUTHORING_TMP)/approval.json --format json > $(AUTHORING_TMP)/patch-apply-dry-run.json

.PHONY: require-sqlcipher
require-sqlcipher:
	@test -n "$(SQLCIPHER_PREFIX)" || { printf "%s\n" "SQLCIPHER_PREFIX is not set and no Homebrew sqlcipher keg was found." >&2; exit 1; }
	@test -f "$(SQLCIPHER_PREFIX)/include/sqlcipher/sqlite3.h" || { printf "%s\n" "missing $(SQLCIPHER_PREFIX)/include/sqlcipher/sqlite3.h" >&2; exit 1; }
	@test -d "$(SQLCIPHER_PREFIX)/lib" || { printf "%s\n" "missing $(SQLCIPHER_PREFIX)/lib" >&2; exit 1; }

.PHONY: sqlcipher-env
sqlcipher-env: require-sqlcipher
	@printf "%s\n" "export EXQLITE_USE_SYSTEM=1"
	@printf "%s\n" "export EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)'"
	@printf "%s\n" "export EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)'"
	@printf "%s\n" "export TWELVGAIGE_SQLCIPHER_SPIKE_KEY='$(SQLCIPHER_KEY)'"

.PHONY: sqlcipher-compile
sqlcipher-compile: require-sqlcipher deps
	EXQLITE_USE_SYSTEM=1 EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)' EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)' mix deps.clean exqlite --build
	EXQLITE_USE_SYSTEM=1 EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)' EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)' mix deps.compile exqlite

.PHONY: sqlcipher-compile-prod
sqlcipher-compile-prod: require-sqlcipher deps
	MIX_ENV=prod EXQLITE_USE_SYSTEM=1 EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)' EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)' mix deps.clean exqlite --build
	MIX_ENV=prod EXQLITE_USE_SYSTEM=1 EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)' EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)' mix deps.compile exqlite

.PHONY: sqlcipher-spike-system
sqlcipher-spike-system: sqlcipher-compile
	rm -f $(SQLCIPHER_SPIKE_PATH) $(SQLCIPHER_SPIKE_PATH)-wal $(SQLCIPHER_SPIKE_PATH)-shm
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_SQLCIPHER_SPIKE_KEY='$(SQLCIPHER_KEY)' mix run -e 'IO.puts(Jason.encode!(elem(Twelvgaige.sqlcipher_spike(path: "$(SQLCIPHER_SPIKE_PATH)"), 1), pretty: true))'

.PHONY: sqlcipher-store-system
sqlcipher-store-system: sqlcipher-compile
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_SQLCIPHER_LIVE=1 TWELVGAIGE_SQLCIPHER_LIVE_KEY='$(SQLCIPHER_KEY)' MIX_ENV=test mix test --include persistence --include sqlcipher_live test/twelvgaige/store/sqlite_encrypted_live_test.exs

.PHONY: sqlcipher-escript-smoke-system
sqlcipher-escript-smoke-system: sqlcipher-compile escript
	$(MAKE) sqlcipher-smoke-commands SMOKE_BIN=./$(APP)

.PHONY: burrito-sqlcipher-smoke-system
burrito-sqlcipher-smoke-system: sqlcipher-compile-prod
	EXQLITE_USE_SYSTEM=1 EXQLITE_SYSTEM_CFLAGS='$(SQLCIPHER_CFLAGS)' EXQLITE_SYSTEM_LDFLAGS='$(SQLCIPHER_LDFLAGS)' MIX_ENV=prod BURRITO_TARGET=$(BURRITO_TARGET) mix release $(APP) --overwrite
	$(MAKE) sqlcipher-smoke-commands SMOKE_BIN=$(BURRITO_BIN) SQLCIPHER_SMOKE_TMP=/tmp/$(APP)-burrito-sqlcipher-smoke-$(BURRITO_TARGET) SMOKE_ENV='TWELVGAIGE_INSTALL_DIR=/tmp/$(APP)-burrito-sqlcipher-smoke-$(BURRITO_TARGET)/install'

.PHONY: sqlcipher-smoke-commands
sqlcipher-smoke-commands: require-sqlcipher
	rm -rf $(SQLCIPHER_SMOKE_TMP)
	mkdir -p $(SQLCIPHER_SMOKE_TMP)
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_SQLCIPHER_SPIKE_KEY='$(SQLCIPHER_KEY)' $(SMOKE_ENV) $(SMOKE_BIN) crypto sqlcipher-spike --path $(SQLCIPHER_SMOKE_TMP)/probe.db --format json > $(SQLCIPHER_SMOKE_TMP)/probe.json
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_STORE_SQLITE=$(SQLCIPHER_SMOKE_TMP)/plain.db $(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_TOML)
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_STORE_SQLITE=$(SQLCIPHER_SMOKE_TMP)/plain.db $(SMOKE_ENV) $(SMOKE_BIN) store backup $(SQLCIPHER_SMOKE_TMP)/plain-backup.db --allow-plaintext-export --format json > $(SQLCIPHER_SMOKE_TMP)/plain-backup.json
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' $(SQLCIPHER_STORE_KEY_ENV)='$(SQLCIPHER_KEY)' $(SMOKE_ENV) $(SMOKE_BIN) store migrate-sqlcipher --source $(SQLCIPHER_SMOKE_TMP)/plain.db --destination $(SQLCIPHER_SMOKE_TMP)/encrypted.db --key-env $(SQLCIPHER_STORE_KEY_ENV) --format json > $(SQLCIPHER_SMOKE_TMP)/migration.json
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_STORE_SQLCIPHER=$(SQLCIPHER_SMOKE_TMP)/encrypted.db TWELVGAIGE_STORE_SQLCIPHER_KEY='$(SQLCIPHER_KEY)' $(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_TOML)
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_STORE_SQLCIPHER=$(SQLCIPHER_SMOKE_TMP)/encrypted.db TWELVGAIGE_STORE_SQLCIPHER_KEY='$(SQLCIPHER_KEY)' $(SMOKE_ENV) $(SMOKE_BIN) store backup $(SQLCIPHER_SMOKE_TMP)/encrypted-backup.db --format json > $(SQLCIPHER_SMOKE_TMP)/encrypted-backup.json
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' $(SMOKE_ENV) $(SMOKE_BIN) store restore $(SQLCIPHER_SMOKE_TMP)/encrypted-backup.db $(SQLCIPHER_SMOKE_TMP)/encrypted-restored.db --format json > $(SQLCIPHER_SMOKE_TMP)/encrypted-restore.json
	DYLD_FALLBACK_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(DYLD_FALLBACK_LIBRARY_PATH)' LD_LIBRARY_PATH='$(SQLCIPHER_PREFIX)/lib:$(LD_LIBRARY_PATH)' TWELVGAIGE_STORE_SQLCIPHER=$(SQLCIPHER_SMOKE_TMP)/encrypted-restored.db TWELVGAIGE_STORE_SQLCIPHER_KEY='$(SQLCIPHER_KEY)' $(SMOKE_ENV) $(SMOKE_BIN) round run $(SMOKE_WORKFLOW_TOML)

.PHONY: keychain-smoke-macos
keychain-smoke-macos:
	@test "$$(uname -s)" = "Darwin" || { printf "%s\n" "keychain-smoke-macos requires macOS." >&2; exit 1; }
	@test "$(KEYCHAIN_LIVE)" = "1" || { printf "%s\n" "set KEYCHAIN_LIVE=1 to create and delete a temporary Twelvgaige Keychain item." >&2; exit 1; }
	TWELVGAIGE_KEYCHAIN_LIVE=1 MIX_ENV=test mix test --include keychain_live test/twelvgaige/crypto/macos_keychain_live_test.exs

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
	TWELVGAIGE_SQLCIPHER_SPIKE_KEY=smoke $(SMOKE_ENV) $(SMOKE_BIN) crypto sqlcipher-spike --path $(SMOKE_TMP)/sqlcipher-spike.db --format json > $(SMOKE_TMP)/sqlcipher-spike.json
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
