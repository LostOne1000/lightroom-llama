VERSION ?= dev
DIST_DIR := dist
PLUGIN_DIR := lightroom-llama.lrplugin
PACKAGE := $(DIST_DIR)/lightroom-llama-v$(VERSION).zip

.PHONY: test clean package

# Run the Busted unit test suite for plugin modules.
# Delegates to run_tests.sh so test flags are defined in one place.
test:
	./tests/run_tests.sh

# Run tests, create the release ZIP, and verify that the archive is valid.
package: test
	rm -rf "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)"
	zip -r "$(PACKAGE)" "$(PLUGIN_DIR)" \
		-x "*/.DS_Store" \
		   "*/__MACOSX/*" \
		   "*/._*"
	unzip -t "$(PACKAGE)"

# Remove generated test and release artifacts.
clean:
	rm -f tests/spec/*.gc* 2>/dev/null || true
	rm -rf "$(DIST_DIR)"