#!/usr/bin/env bash
#
# Shared helpers for the knit-uv plugin test suite.
#
# The suite needs a knit.sh that does NOT itself register a "uv" environment
# manager. The plugin provides it; sourcing a uv-carrying knit.sh and the plugin
# would register the manager twice (a fatal). The released knit.sh is such a
# build; for local development, build one and point KNIT_SH at it before running
# bats:
#
#     KNIT_SH=/path/to/knit.sh bats tests/

# Source knit.sh (from KNIT_SH) and then the plugin, so a test can call the
# plugin's verbs and knit's public API. Skips the test when KNIT_SH is unusable,
# so the suite degrades gracefully rather than failing cryptically.
knit_uv_test_load() {
    if [[ -z "${KNIT_SH:-}" || ! -r "${KNIT_SH}" ]]; then
        skip "set KNIT_SH to a readable knit.sh build without a uv manager"
    fi
    # shellcheck disable=SC1090
    source "${KNIT_SH}"
    # shellcheck disable=SC1091
    source "${BATS_TEST_DIRNAME}/../plugin.sh"
}

# A throwaway sqlite-backed metadata DB, for tests that register a setup (its
# columns land in the DB) or store provenance metadata.
knit_uv_test_db_setup() {
    command -v sqlite3 >/dev/null 2>&1 || skip "sqlite3 not available"
    _KNIT_SQLITE_EXE="sqlite3"
    KNIT_UV_TEST_DB_DIR="$(mktemp -d)"
    _KNIT_DATABASE="${KNIT_UV_TEST_DB_DIR}/knit.db"
    _KNIT_IS_BOOTSTRAPPED="1"
    _knit_create_metadata_table
}

knit_uv_test_db_teardown() {
    rm -rf "${KNIT_UV_TEST_DB_DIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}
