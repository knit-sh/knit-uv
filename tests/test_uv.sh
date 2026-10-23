#!/usr/bin/env bats

# Unit tests for the knit-uv plugin's verbs (plugin.sh): latest-release
# resolution, host-triple asset selection, provisioning provenance, the install
# verb, the activation/specs verbs, and the "knit uv" wrapper. The network seam
# and the uv binary are stubbed, so the suite is offline and deterministic.

load helper

setup() {
    knit_uv_test_load

    __TEST_TMPDIR="$(mktemp -d)"
    _KNIT_PREFIX="${__TEST_TMPDIR}/fake-knit"
    mkdir -p "${_KNIT_PREFIX}"
    KNIT_UV_ROOT="${_KNIT_PREFIX}/uv"
    # The provisioning helpers assume a bootstrapped experiment (metadata store).
    _KNIT_IS_BOOTSTRAPPED="1"
}

teardown() {
    rm -rf "${__TEST_TMPDIR}"
    _KNIT_IS_BOOTSTRAPPED=""
}

# ---------- knit_uv_latest_release ----------

@test "latest release resolves the tag from the GitHub releases/latest API" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{"tag_name":"0.5.0"}'; }
    knit_jq() { jq "$@"; }

    run knit_uv_latest_release
    [ "$status" -eq 0 ]
    [ "$output" = "0.5.0" ]
}

@test "latest release is fatal when the API returns no release" {
    command -v jq >/dev/null 2>&1 || skip "jq not available"
    curl() { printf '%s' '{}'; }
    knit_jq() { jq "$@"; }

    run knit_uv_latest_release
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not resolve"* ]]
}

# ---------- knit_uv_asset_name ----------

_stub_uname() {
    # Globals (not locals): the stubbed uname runs after this helper returns, so
    # the values must outlive its scope.
    __STUB_OS="$1"
    __STUB_ARCH="$2"
    uname() { case "$1" in -s) printf '%s' "${__STUB_OS}" ;; -m) printf '%s' "${__STUB_ARCH}" ;; esac; }
}

@test "asset_name maps Linux x86_64 to the gnu tarball" {
    _stub_uname Linux x86_64
    run knit_uv_asset_name
    [ "$output" = "uv-x86_64-unknown-linux-gnu.tar.gz" ]
}

@test "asset_name maps Linux aarch64 to the gnu tarball" {
    _stub_uname Linux aarch64
    run knit_uv_asset_name
    [ "$output" = "uv-aarch64-unknown-linux-gnu.tar.gz" ]
}

@test "asset_name maps macOS arm64 to the aarch64 darwin tarball" {
    _stub_uname Darwin arm64
    run knit_uv_asset_name
    [ "$output" = "uv-aarch64-apple-darwin.tar.gz" ]
}

@test "asset_name maps macOS x86_64 to the darwin tarball" {
    _stub_uname Darwin x86_64
    run knit_uv_asset_name
    [ "$output" = "uv-x86_64-apple-darwin.tar.gz" ]
}

@test "asset_name is fatal on an unsupported architecture" {
    _stub_uname Linux riscv64
    run knit_uv_asset_name
    [ "$status" -ne 0 ]
    [[ "$output" == *"No prebuilt uv binary"* ]]
}

@test "asset_name is fatal on an unsupported OS" {
    _stub_uname Windows x86_64
    run knit_uv_asset_name
    [ "$status" -ne 0 ]
    [[ "$output" == *"No prebuilt uv binary"* ]]
}

# ---------- knit_uv_provision (provenance + latest resolution) ----------

# Stub the download/extract seam and capture the metadata that gets stored.
_stub_provisioning() {
    knit_uv_asset_name() { printf 'uv-fake.tar.gz'; }
    # knit_github_download_asset <sha_out> <org> <repo> <tag> <asset> <dest>.
    knit_github_download_asset() { local -n __sha=$1; __sha="deadbeefsha"; }
    # Skip the real tar extraction (no tarball was actually downloaded).
    knit_framed_run() { return 0; }
    METALOG="${__TEST_TMPDIR}/meta"
    : > "${METALOG}"
    knit() {
        [[ "$1 $2" == "metadata store" ]] || return 0
        shift 2
        local key="" val=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --key)   key="$2"; shift 2 ;;
                --value) val="$2"; shift 2 ;;
                *)       shift ;;
            esac
        done
        printf '%s=%s\n' "${key}" "${val}" >> "${METALOG}"
    }
}

@test "provision resolves the latest release when the ref is empty" {
    _stub_provisioning
    knit_uv_latest_release() { printf '0.9.9'; }

    knit_uv_provision ""

    grep -q "__uv_ref__=0.9.9" "${METALOG}"
    grep -q "__uv_sha256__=deadbeefsha" "${METALOG}"
}

@test "provision uses an explicit ref and skips latest resolution" {
    _stub_provisioning
    knit_uv_latest_release() { printf 'SHOULD_NOT_BE_CALLED'; }

    knit_uv_provision "0.4.0"

    grep -q "__uv_ref__=0.4.0" "${METALOG}"
    ! grep -q "SHOULD_NOT_BE_CALLED" "${METALOG}"
}

# ---------- knit_uv_install_env ----------

# A fake uv binary that echoes its argv and the uv-cache env vars, then exits
# with a controllable status.
_fake_uv() {
    local code="${1:-0}"
    mkdir -p "${KNIT_UV_ROOT}/bin"
    cat > "${KNIT_UV_ROOT}/bin/uv" <<EOF
#!/usr/bin/env bash
printf 'uv:%s\n' "\$*"
printf 'PYDIR:%s\n' "\${UV_PYTHON_INSTALL_DIR}"
printf 'CACHE:%s\n' "\${UV_CACHE_DIR}"
printf 'PREF:%s\n' "\${UV_PYTHON_PREFERENCE}"
exit ${code}
EOF
    chmod +x "${KNIT_UV_ROOT}/bin/uv"
}

@test "install copies the manifest in and runs uv sync with the cache under .knit" {
    _fake_uv 0
    local env_dir="${__TEST_TMPDIR}/uv-env"
    local manifest="${__TEST_TMPDIR}/pyproject.toml"
    printf 'MANIFEST' > "${manifest}"

    run knit_uv_install_env "${env_dir}" "${manifest}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"uv:sync --project ${env_dir}"* ]]
    [[ "$output" == *"PYDIR:${KNIT_UV_ROOT}/python"* ]]
    [[ "$output" == *"CACHE:${KNIT_UV_ROOT}/cache"* ]]
    # Always builds on a uv-managed interpreter, never the host Python.
    [[ "$output" == *"PREF:only-managed"* ]]
    [ -f "${env_dir}/pyproject.toml" ]
    [ "$(cat "${env_dir}/pyproject.toml")" = "MANIFEST" ]
}

@test "install returns non-zero (not fatal) when uv sync fails" {
    _fake_uv 7
    local env_dir="${__TEST_TMPDIR}/uv-env"
    local manifest="${__TEST_TMPDIR}/pyproject.toml"
    printf 'M' > "${manifest}"

    run knit_uv_install_env "${env_dir}" "${manifest}"
    [ "$status" -ne 0 ]
    [[ "$output" == *"uv failed to sync"* ]]
}

# ---------- knit uv wrapper (knit_uv_exec) ----------

@test "knit uv is registered as a wrapper with a table" {
    _knit_command_is_wrapper "uv"
    [ -n "${_KNIT_CMD_uv_table:-}" ]
}

@test "uv_exec is fatal with a hint when uv is not provisioned" {
    # setup() points KNIT_UV_ROOT at a directory with no bin/uv.
    run knit_uv_exec --version
    [ "$status" -ne 0 ]
    [[ "$output" == *"not provisioned"* ]]
    [[ "$output" == *"bootstrap --uv"* ]]
}

@test "uv_exec forwards its arguments verbatim to uv" {
    _fake_uv 0
    run knit_uv_exec pip install numpy --no-cache
    [ "$status" -eq 0 ]
    [[ "$output" == *"uv:pip install numpy --no-cache"* ]]
}

@test "uv_exec forwards --help verbatim" {
    _fake_uv 0
    run knit_uv_exec --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"uv:--help"* ]]
}
