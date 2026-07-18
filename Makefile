.PHONY: test clean

# Run the Busted unit test suite for plugin modules.
# Delegates to run_tests.sh (the authoritative runner) so flags are only defined once.
test:
	./tests/run_tests.sh

# Remove generated/test artifacts
clean:
	rm -f tests/spec/*.gc* 2>/dev/null || true
