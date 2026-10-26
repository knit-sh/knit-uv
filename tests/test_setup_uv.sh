#!/usr/bin/env bats

# Tests of the uv environment-manager integration: that uv is registered as a
# manager (so knit_with_uv_env / knit_with_uv_specs are generated and a uv setup
# declares the __uv_manifest__ / __uv_lock__ columns), and that the uv verbs
# (knit_uv_activation, knit_uv_specs_to_manifest) and the generic setup
# callbacks produce the expected output. The generic knit environment-manager
# directive/callback behaviour itself is covered by knit.

load helper

setup() {
    knit_uv_test_load
    knit_uv_test_db_setup

    _KNIT_TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${_KNIT_TEST_TMPDIR}/.knit"
    # Point the uv root at an existing directory so a setup before-callback's
    # on-demand provisioning would be a no-op.
    KNIT_UV_ROOT="${_KNIT_PREFIX}/uv"
    mkdir -p "${KNIT_UV_ROOT}/bin"
    _test_setup_fn() { :; }
}

teardown() {
    rm -rf "${_KNIT_TEST_TMPDIR}"
    unset KNIT_SETUP_PREFIX
    knit_uv_test_db_teardown
}

# ---------- uv is registered as an environment manager ----------

@test "uv is registered as an environment manager" {
    _knit_env_is_registered "uv"
    [ "${_KNIT_ENV_uv_manifest}" = "pyproject.toml" ]
    [ "${_KNIT_ENV_uv_lockfile}" = "uv.lock" ]
}

@test "the uv setup directives are generated" {
    declare -F knit_with_uv_env
    declare -F knit_with_uv_specs
}

@test "the uv setup shorthands are generated" {
    # uv is a plugin (loaded after src/shorthand.sh), so its shorthands are
    # registered by knit_env_done, not the source-time generator.
    declare -F @with_uv_env
    declare -F @with_uv_specs
}

@test "a uv setup declares __uv_manifest__ and __uv_lock__ columns" {
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_env "pyproject.toml"
    knit_done
    local names
    names=$(sqlite3 "${_KNIT_DATABASE}" "PRAGMA table_info('setup:pyenv');" \
        | cut -d'|' -f2 | tr '\n' ',')
    [[ "${names}" == *__uv_manifest__* ]]
    [[ "${names}" == *__uv_lock__* ]]
}

@test "knit_with_uv_env flags the uv manager required" {
    _KNIT_ENV_uv_required=""
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_env "pyproject.toml"
    knit_done
    [ -n "${_KNIT_ENV_uv_required}" ]
}

@test "knit_with_uv_env records a --help note mentioning uv" {
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_env "pyproject.toml"
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "pyenv" "--help")
    [[ "${result}" == *"uv environment"* ]]
}

# ---------- uv verbs ----------

@test "knit_uv_activation prints the venv activate source line" {
    run knit_uv_activation "/some/env-dir"
    [ "$status" -eq 0 ]
    [[ "$output" == *"source /some/env-dir/.venv/bin/activate"* ]]
}

@test "knit_uv_specs_to_manifest synthesizes a pyproject.toml with the given specs" {
    run knit_uv_specs_to_manifest "numpy>=2" "scipy"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[project]"* ]]
    # No Python floor is pinned, so the dependencies dictate the interpreter.
    [[ "$output" != *"requires-python"* ]]
    [[ "$output" == *"dependencies = ["* ]]
    [[ "$output" == *'"numpy>=2",'* ]]
    [[ "$output" == *'"scipy",'* ]]
}

# ---------- uv setup end-to-end (generic callback + uv verbs) ----------

@test "a uv setup's after callback appends the venv re-activation to .activate.sh" {
    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    mkdir -p "${KNIT_SETUP_PREFIX}/uv-env"
    printf 'export ORIG=1\n' > "${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_env_setup_after_cb "uv"
    grep -q "ORIG=1" "${KNIT_SETUP_PREFIX}/.activate.sh"
    grep -q "uv-env/.venv/bin/activate" "${KNIT_SETUP_PREFIX}/.activate.sh"
}

@test "a uv setup's after callback captures pyproject.toml/uv.lock provenance" {
    command -v gzip >/dev/null 2>&1 || skip "gzip not available"
    command -v base64 >/dev/null 2>&1 || skip "base64 not available"
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_env "pyproject.toml"
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:pyenv"
    declare -gA "_KNIT_CMD_${cmd}_output_value=()"
    _KNIT_EXECUTING_COMMAND=("${cmd}")

    export KNIT_SETUP_PREFIX="${_KNIT_TEST_TMPDIR}/prefix"
    local env_dir="${KNIT_SETUP_PREFIX}/uv-env"
    mkdir -p "${env_dir}"
    printf 'MANIFEST' > "${env_dir}/pyproject.toml"
    printf 'LOCKDATA' > "${env_dir}/uv.lock"
    touch "${KNIT_SETUP_PREFIX}/.activate.sh"
    _knit_env_setup_after_cb "uv"

    local -n _out_ref="_KNIT_CMD_${cmd}_output_value"
    [ "$(printf '%s' "${_out_ref[__uv_manifest__]}" | base64 -d | gunzip)" = "MANIFEST" ]
    [ "$(printf '%s' "${_out_ref[__uv_lock__]}" | base64 -d | gunzip)" = "LOCKDATA" ]
}
