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

@test "the layered directive and its shorthand are defined" {
    declare -F knit_with_uv_layered
    declare -F @with_uv_layered
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

# ---------- layered mode (M2) ----------

# Install a fake uv that logs each invocation's argv, one "CALL [a] [b] ..." line
# per call, so a test can assert the exact uv command without a real uv or
# network. Each argument is bracketed so specs carrying spaces (a git "pkg @
# url") or brackets (an extra "pkg[x]") are unambiguous.
_stub_uv() {
    cat > "${KNIT_UV_ROOT}/bin/uv" <<EOF
#!/usr/bin/env bash
{ printf 'CALL'; for a in "\$@"; do printf ' [%s]' "\${a}"; done; printf '\n'; } >> "${_UV_LOG}"
EOF
    chmod +x "${KNIT_UV_ROOT}/bin/uv"
}

_write_specs_manifest() {
    # A specs-style pyproject (as knit_uv_specs_to_manifest synthesizes), with a
    # git spec carrying a space and a spec carrying a bracketed extra.
    printf '%s\n' \
        '[project]' \
        'name = "knit-uv-env"' \
        'version = "0.0.0"' \
        'dependencies = [' \
        '    "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git",' \
        '    "pillow[avif]>=11",' \
        ']' > "$1"
}

@test "knit_with_uv_layered records the layered build option" {
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_specs "cifar-cnn"
    knit_with_uv_layered
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:pyenv"
    local -n opts="_KNIT_CMD_${cmd}_envopts_uv"
    [ "${#opts[@]}" -eq 1 ]
    [ "${opts[0]}" = "layered" ]
}

@test "knit_with_uv_layered outside a setup is fatal" {
    run knit_with_uv_layered
    [ "$status" -ne 0 ]
    [[ "$output" == *"setup"* ]]
}

@test "knit_uv_manifest_dependencies extracts each spec, keeping extras" {
    local manifest="${_KNIT_TEST_TMPDIR}/pyproject.toml"
    _write_specs_manifest "${manifest}"
    run knit_uv_manifest_dependencies "${manifest}"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = "cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git" ]
    [ "${lines[1]}" = "pillow[avif]>=11" ]
}

@test "hermetic install (no options) runs uv sync and no venv" {
    _UV_LOG="${_KNIT_TEST_TMPDIR}/uv.log"
    _stub_uv
    local env_dir="${_KNIT_TEST_TMPDIR}/env"
    mkdir -p "${env_dir}"
    local manifest="${_KNIT_TEST_TMPDIR}/pyproject.toml"
    _write_specs_manifest "${manifest}"
    run knit_uv_install_env "${env_dir}" "${manifest}"
    [ "$status" -eq 0 ]
    grep -qF -- '[sync]' "${_UV_LOG}"
    grep -qF -- "[--project] [${env_dir}]" "${_UV_LOG}"
    ! grep -qF -- '[venv]' "${_UV_LOG}"
}

@test "layered install runs uv venv --system-site-packages then uv pip install of the specs" {
    _UV_LOG="${_KNIT_TEST_TMPDIR}/uv.log"
    _stub_uv
    local env_dir="${_KNIT_TEST_TMPDIR}/env"
    mkdir -p "${env_dir}"
    local manifest="${_KNIT_TEST_TMPDIR}/pyproject.toml"
    _write_specs_manifest "${manifest}"
    run knit_uv_install_env "${env_dir}" "${manifest}" layered
    [ "$status" -eq 0 ]
    # The venv is created on the ambient interpreter with inherited site-packages.
    grep -qF -- '[venv] [--system-site-packages] [--python-preference] [only-system]' "${_UV_LOG}"
    grep -qF -- "[${env_dir}/.venv]" "${_UV_LOG}"
    # The specs are installed on top; --no-deps is absent when not recorded.
    grep -qF -- "[pip] [install] [--python] [${env_dir}/.venv/bin/python]" "${_UV_LOG}"
    grep -qF -- '[cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git]' "${_UV_LOG}"
    grep -qF -- '[pillow[avif]>=11]' "${_UV_LOG}"
    ! grep -qF -- '[sync]' "${_UV_LOG}"
    ! grep -qF -- '[--no-deps]' "${_UV_LOG}"
}

@test "layered install fails when the manifest declares no dependencies" {
    _UV_LOG="${_KNIT_TEST_TMPDIR}/uv.log"
    _stub_uv
    local env_dir="${_KNIT_TEST_TMPDIR}/env"
    mkdir -p "${env_dir}"
    local manifest="${_KNIT_TEST_TMPDIR}/pyproject.toml"
    printf '%s\n' '[project]' 'name = "x"' 'version = "0"' 'dependencies = [' ']' \
        > "${manifest}"
    run knit_uv_install_env "${env_dir}" "${manifest}" layered
    [ "$status" -ne 0 ]
    [[ "$output" == *"no dependencies"* ]]
}

# ---------- --no-deps (M3) ----------

@test "the no-deps directive and its shorthand are defined" {
    declare -F knit_with_uv_no_deps
    declare -F @with_uv_no_deps
}

@test "knit_with_uv_no_deps records the no-deps build option" {
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_specs "cifar-cnn"
    knit_with_uv_layered
    knit_with_uv_no_deps
    knit_done
    local cmd
    _knit_command_mangle cmd "setup:pyenv"
    local -n opts="_KNIT_CMD_${cmd}_envopts_uv"
    [ "${#opts[@]}" -eq 2 ]
    [ "${opts[0]}" = "layered" ]
    [ "${opts[1]}" = "no-deps" ]
}

@test "layered install with the no-deps option passes --no-deps to uv pip install" {
    _UV_LOG="${_KNIT_TEST_TMPDIR}/uv.log"
    _stub_uv
    local env_dir="${_KNIT_TEST_TMPDIR}/env"
    mkdir -p "${env_dir}"
    local manifest="${_KNIT_TEST_TMPDIR}/pyproject.toml"
    _write_specs_manifest "${manifest}"
    run knit_uv_install_env "${env_dir}" "${manifest}" layered no-deps
    [ "$status" -eq 0 ]
    # --no-deps sits between the --python target and the first spec.
    grep -qF -- "[pip] [install] [--python] [${env_dir}/.venv/bin/python] [--no-deps]" "${_UV_LOG}"
    grep -qF -- '[cifar-cnn @ git+https://github.com/knit-sh/image-classifier-example.git]' "${_UV_LOG}"
}

# ---------- validation + help (M4) ----------

@test "layered with a complete manifest is fatal (manifest declared first)" {
    _reg() {
        knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
        knit_with_uv_env "pyproject.toml"
        knit_with_uv_layered
        knit_done
    }
    run _reg
    [ "$status" -ne 0 ]
    [[ "$output" == *"layered"* ]]
    [[ "$output" == *"knit_with_uv_specs"* ]]
}

@test "layered with a complete manifest is fatal regardless of directive order" {
    _reg() {
        knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
        knit_with_uv_layered
        knit_with_uv_env "pyproject.toml"
        knit_done
    }
    run _reg
    [ "$status" -ne 0 ]
    [[ "$output" == *"knit_with_uv_specs"* ]]
}

@test "layered with specs is accepted (no conflict)" {
    _reg() {
        knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
        knit_with_uv_specs "cifar-cnn"
        knit_with_uv_layered
        knit_done
    }
    run _reg
    [ "$status" -eq 0 ]
}

@test "a layered uv setup notes the layered environment in --help" {
    knit_register_setup "pyenv" "_test_setup_fn" "Build the Python env."
    knit_with_uv_specs "cifar-cnn"
    knit_with_uv_layered
    knit_done
    local result
    result=$(_knit_invoke_command "setup" "pyenv" "--help")
    [[ "${result}" == *"layered"* ]]
}
