VERSION ?= dev
DIST_DIR := dist
PLUGIN_DIR := lightroom-llama.lrplugin
PACKAGE := $(DIST_DIR)/lightroom-llama-v$(VERSION).zip

.PHONY: test clean package

# Run the Busted unit test suite for plugin modules.
test:
	./tests/run_tests.sh

# Stage authoritative notices without duplicating them in the source bundle.
# One shell and an exit trap ensure staging files are removed even on failure.
package: test
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)"
	@set -eu; \
	stage=$$(mktemp -d); \
	trap 'rm -rf "$$stage"' EXIT HUP INT TERM; \
	cp -R "$(PLUGIN_DIR)" "$$stage/$(PLUGIN_DIR)"; \
	cp LICENSE THIRD_PARTY_NOTICES.md "$$stage/$(PLUGIN_DIR)/"; \
	(cd "$$stage" && zip -r "$(abspath $(PACKAGE))" "$(PLUGIN_DIR)" \
		-x "*/.DS_Store" "*/__MACOSX/*" "*/._*"); \
	unzip -t "$(PACKAGE)"; \
	for notice in LICENSE THIRD_PARTY_NOTICES.md; do \
		unzip -p "$(PACKAGE)" "$(PLUGIN_DIR)/$$notice" > "$$stage/$$notice"; \
		cmp "$$notice" "$$stage/$$notice"; \
	done

# Remove generated test and release artifacts.
clean:
	rm -f tests/spec/*.gc* 2>/dev/null || true
	rm -rf "$(DIST_DIR)"
