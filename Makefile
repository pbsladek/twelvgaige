APP := twelvgaige
VERSION := $(shell awk -F'"' '/version:/ {print $$2; exit}' mix.exs)

ARTIFACT_DIR ?= artifacts
ARTIFACT_SUFFIX ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')-$(shell uname -m)
BURRITO_TARGET ?= linux
NATIVE_RELEASE := twelvgaige_native

SMOKE_WORKFLOW_YAML := traphouse/workflows/simple.yaml
SMOKE_WORKFLOW_JSON := traphouse/workflows/simple.json
SMOKE_WORKFLOW_TOML := traphouse/workflows/simple.toml
SMOKE_INPUT := '{}'
SMOKE_BIN ?= ./$(APP)
SMOKE_TMP ?= /tmp/$(APP)-smoke-$(ARTIFACT_SUFFIX)

NATIVE_BIN := _build/prod/rel/$(NATIVE_RELEASE)/bin/$(APP)
NATIVE_TARBALL := _build/prod/$(NATIVE_RELEASE)-$(VERSION).tar.gz

BURRITO_EXT :=
ifeq ($(BURRITO_TARGET),windows)
BURRITO_EXT := .exe
endif
BURRITO_BIN := burrito_out/$(APP)_$(BURRITO_TARGET)$(BURRITO_EXT)

.PHONY: all
all: ci

.PHONY: deps
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

.PHONY: test-persistence
test-persistence:
	MIX_ENV=test mix test --include persistence

.PHONY: ci
ci: deps format-check compile test test-persistence

.PHONY: escript
escript: deps
	mix escript.build

.PHONY: escript-smoke
escript-smoke: escript
	$(MAKE) smoke-shell-formats SMOKE_BIN=./$(APP)

.PHONY: smoke-shell-formats
smoke-shell-formats:
	rm -rf $(SMOKE_TMP)
	mkdir -p $(SMOKE_TMP)
	$(SMOKE_BIN) version
	$(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_YAML)
	$(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_JSON)
	$(SMOKE_BIN) shell validate $(SMOKE_WORKFLOW_TOML)
	$(SMOKE_BIN) shell normalize $(SMOKE_WORKFLOW_TOML) --format json > $(SMOKE_TMP)/normalized.json
	$(SMOKE_BIN) shell validate $(SMOKE_TMP)/normalized.json
	$(SMOKE_BIN) shell convert $(SMOKE_WORKFLOW_YAML) --to toml > $(SMOKE_TMP)/converted.toml
	$(SMOKE_BIN) shell validate $(SMOKE_TMP)/converted.toml
	$(SMOKE_BIN) shell convert $(SMOKE_WORKFLOW_TOML) --to yaml > $(SMOKE_TMP)/converted.yaml
	$(SMOKE_BIN) shell validate $(SMOKE_TMP)/converted.yaml
	$(SMOKE_BIN) round run $(SMOKE_WORKFLOW_YAML) --input $(SMOKE_INPUT)
	$(SMOKE_BIN) round run $(SMOKE_WORKFLOW_JSON) --input $(SMOKE_INPUT)
	$(SMOKE_BIN) round run $(SMOKE_WORKFLOW_TOML) --input $(SMOKE_INPUT)

.PHONY: release
release: deps
	MIX_ENV=prod mix release $(NATIVE_RELEASE) --overwrite

.PHONY: release-smoke
release-smoke: release
	$(MAKE) smoke-shell-formats SMOKE_BIN=$(NATIVE_BIN)
	TWELVGAIGE_STORE_SQLITE=/tmp/$(APP)-native-release-$(ARTIFACT_SUFFIX).sqlite3 $(NATIVE_BIN) round run $(SMOKE_WORKFLOW_TOML) --input $(SMOKE_INPUT)

.PHONY: burrito
burrito: deps
	MIX_ENV=prod BURRITO_TARGET=$(BURRITO_TARGET) mix release $(APP) --overwrite

.PHONY: burrito-smoke
burrito-smoke: burrito burrito-smoke-only

.PHONY: burrito-smoke-only
burrito-smoke-only:
	$(MAKE) smoke-shell-formats SMOKE_BIN=$(BURRITO_BIN) SMOKE_TMP=/tmp/$(APP)-burrito-smoke-$(BURRITO_TARGET)
	TWELVGAIGE_STORE_SQLITE=/tmp/$(APP)-burrito-release-$(BURRITO_TARGET).sqlite3 $(BURRITO_BIN) round run $(SMOKE_WORKFLOW_TOML) --input $(SMOKE_INPUT)

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

.PHONY: clean
clean:
	mix clean
	rm -rf $(ARTIFACT_DIR) burrito_out
