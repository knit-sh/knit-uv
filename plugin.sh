#!/bin/bash
#
# plugin.sh — the knit-uv plugin.
#
# Knit sources this file after it sources knit.sh, so every public knit function
# is available. The plugin registers uv (Astral's Python package/project manager)
# as a knit environment manager and adds the "knit uv" wrapper. Import it at the
# top of an experiment, after "source knit.sh":
#
#     knit_import uv
#
# Importing it adds the --uv bootstrap option, the knit_with_uv_env /
# knit_with_uv_specs setup directives (and their @with_uv_env / @with_uv_specs
# shorthands), and the "knit uv" command.
#
# The plugin uses only knit's public API (knit_* functions). It provisions uv by
# downloading the prebuilt release binary for the host platform with curl and tar
# (knit's release-asset helper), so it needs no Python and no git.

# Root directory of the uv installation, under the experiment's ".knit". The uv
# and uvx binaries live in "<root>/bin"; the plugin also keeps uv's managed
# Python interpreters and download cache under this root (set at install time) so
# everything uv touches stays inside the experiment's ".knit".
declare -g KNIT_UV_ROOT
KNIT_UV_ROOT="$(knit_prefix)/uv"

# @fn knit_uv_latest_release()
#
# Resolve the latest release tag of uv through the GitHub API. Used when the user
# did not pin a ref: the plugin provisions the newest published release.
#
# @return Prints the newest release tag; fatal if none can be resolved.
knit_uv_latest_release() {
    local url="https://api.github.com/repos/astral-sh/uv/releases/latest"
    local tag
    tag="$(knit_github_api "${url}" | knit_jq -r '.tag_name // empty')"
    if [[ -z "${tag}" ]]; then
        knit_fatal "Could not resolve the latest uv release from ${url}." \
            "If this is a rate-limited environment, set GITHUB_TOKEN."
    fi
    printf '%s' "${tag}"
}

# @fn knit_uv_asset_name()
#
# Print the uv release-asset filename for the host platform. uv publishes one
# prebuilt tarball per target triple (for example
# "uv-x86_64-unknown-linux-gnu.tar.gz"); this maps "uname -s"/"uname -m" to the
# matching asset. Fatal on an unsupported platform (musl and Windows are out of
# scope; the user can provision uv another way and point PATH at it).
#
# @return Prints the asset filename; fatal if the platform is unsupported.
knit_uv_asset_name() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"
    # macOS reports arm64; uv names that target aarch64.
    [[ "${arch}" == "arm64" ]] && arch="aarch64"
    case "${os}" in
        Linux)
            case "${arch}" in
                x86_64)  printf 'uv-x86_64-unknown-linux-gnu.tar.gz' ;;
                aarch64) printf 'uv-aarch64-unknown-linux-gnu.tar.gz' ;;
                *) knit_fatal "No prebuilt uv binary for Linux ${arch}." \
                       "Supported: x86_64, aarch64." ;;
            esac
            ;;
        Darwin)
            case "${arch}" in
                x86_64)  printf 'uv-x86_64-apple-darwin.tar.gz' ;;
                aarch64) printf 'uv-aarch64-apple-darwin.tar.gz' ;;
                *) knit_fatal "No prebuilt uv binary for macOS ${arch}." \
                       "Supported: x86_64, aarch64." ;;
            esac
            ;;
        *) knit_fatal "No prebuilt uv binary for ${os}." \
               "Supported: Linux, Darwin." ;;
    esac
}

# @fn knit_uv_provision()
#
# Provision verb (knit_env_provision): resolve the ref (latest release when
# empty) to a published tag, download the host-platform uv tarball with curl,
# extract the uv/uvx binaries into "<root>/bin", and record provenance metadata
# (resolved tag and the asset's sha256). No Python and no git.
#
# It removes any existing uv root first so it is safe to re-run (knit's generic
# update dispatcher removes .knit/uv on a re-provision; this keeps the verb
# independently idempotent). On first bootstrap the root is absent and the
# removal is a no-op.
#
# The resolved tag is stored under __uv_ref__ (the __<opt>_ref__ key knit's
# update dispatcher reads for the freeze rule) and the downloaded asset's digest
# under __uv_sha256__ (the immutable pin, the uv analogue of a resolved commit).
#
# @param[in] uv_ref uv release ref (tag); empty uses the latest release.
knit_uv_provision() {
    local requested="${1:-}"

    rm -rf "${KNIT_UV_ROOT}"

    local resolved="${requested}"
    if [[ -z "${resolved}" ]]; then
        knit_trace "Resolving latest uv release..."
        resolved="$(knit_uv_latest_release)"
    fi

    local asset
    asset="$(knit_uv_asset_name)"

    local tarball
    tarball="$(mktemp)"
    local sha256
    knit_github_download_asset sha256 astral-sh uv "${resolved}" "${asset}" "${tarball}"

    knit_trace "Extracting uv..."
    mkdir -p "${KNIT_UV_ROOT}/bin"
    # The tarball's single top-level "uv-<triple>/" directory is stripped so the
    # uv and uvx binaries land directly in "<root>/bin".
    if ! knit_framed_run "extract ${asset}" \
            tar -xzf "${tarball}" -C "${KNIT_UV_ROOT}/bin" --strip-components=1; then
        rm -f "${tarball}"
        knit_fatal "Could not extract uv from ${tarball}."
    fi
    rm -f "${tarball}"

    knit_trace "Storing uv provenance metadata..."
    knit metadata store --key "__uv_ref__"    --value "${resolved}"
    knit metadata store --key "__uv_sha256__" --value "${sha256}"
}

# @fn knit_uv_install_env()
#
# Install verb (knit_env_install): build a uv-managed Python environment from a
# pyproject.toml manifest. The manifest is placed inside the environment
# directory and "uv sync" is run with the project rooted there, so uv creates
# "<env_dir>/.venv" and writes "<env_dir>/uv.lock" (resolving the dependency set
# and downloading a managed interpreter that satisfies requires-python). uv's
# managed interpreters and download cache are kept under ".knit/uv" so nothing
# uv touches escapes the experiment's ".knit".
#
# The sync runs directly (its stdout/stderr inherit the caller's terminal) so
# uv's own progress output is shown. Every step is checked: on failure the
# function logs a knit_error and returns non-zero (it does NOT knit_fatal) so the
# setup dispatcher can remove the half-built setup directory and avoid recording
# it.
#
# @param[in] env_dir  Directory in which to build the uv environment.
# @param[in] manifest Path to the pyproject.toml manifest describing the project.
# @return 0 if the environment was synced, non-zero otherwise.
knit_uv_install_env() {
    local env_dir="$1"
    local manifest="$2"
    mkdir -p "${env_dir}"
    # uv resolves the project from "<env_dir>/pyproject.toml"; the generic layer
    # materializes the manifest elsewhere under KNIT_SETUP_PREFIX, so copy it in
    # (skipping a no-op self-copy if it is already there).
    if [[ "${manifest}" != "${env_dir}/pyproject.toml" ]]; then
        cp "${manifest}" "${env_dir}/pyproject.toml"
    fi
    export UV_PYTHON_INSTALL_DIR="${KNIT_UV_ROOT}/python"
    export UV_CACHE_DIR="${KNIT_UV_ROOT}/cache"
    # Always build on a uv-managed interpreter, never the host Python: uv
    # downloads a managed CPython that satisfies requires-python and ignores
    # whatever happens to be installed on the login node. This keeps the
    # environment self-contained and reproducible across machines (a host with
    # no Python, an old Python, or a differently-patched one all resolve to the
    # same managed interpreter) and lets a manifest require a Python newer than
    # the host provides.
    export UV_PYTHON_PREFERENCE="only-managed"
    if ! "${KNIT_UV_ROOT}/bin/uv" sync --project "${env_dir}"; then
        knit_error "uv failed to sync the environment at %s from %s." \
            "${env_dir}" "${manifest}"
        return 1
    fi
}

# @fn knit_uv_activation()
#
# Activate verb (knit_env_activate): print the shell line that re-enters the uv
# environment at <env_dir> — source the venv's activate script, which sets PATH
# and VIRTUAL_ENV. Knit both eval-s this in the setup's build shell and appends
# it to the setup's .activate.sh for dependent jobs.
#
# @param[in] env_dir Directory of the built uv environment.
knit_uv_activation() {
    local env_dir="$1"
    printf 'source %q\n' "${env_dir}/.venv/bin/activate"
}

# @fn knit_uv_specs_to_manifest()
#
# Specs verb (knit_env_specs): synthesize a minimal pyproject.toml from a list of
# PEP 508 requirements, for the knit_with_uv_specs sugar. The project name and
# version are fixed placeholders and requires-python is a conservative floor; a
# setup that needs tighter control uses knit_with_uv_env with a real
# pyproject.toml instead. Printed to stdout; knit feeds it to knit_with_uv_env.
#
# @param[in] ... One or more PEP 508 requirement strings (e.g. "numpy>=2").
knit_uv_specs_to_manifest() {
    local toml spec
    toml=$'[project]\nname = "knit-uv-env"\nversion = "0.0.0"\nrequires-python = ">=3.9"\ndependencies = [\n'
    for spec in "$@"; do
        toml+="    \"${spec}\","$'\n'
    done
    toml+=$']\n'
    printf '%s' "${toml}"
}

# Register uv as a knit environment manager. This generates the knit_with_uv_env
# / knit_with_uv_specs setup directives (and their @with_uv_env / @with_uv_specs
# shorthands), declares the --uv bootstrap option, and routes provisioning,
# update-mode re-provisioning, the freeze-on-built rule, and manifest/lockfile
# provenance through knit's generic environment-manager layer.
knit_register_env_manager "uv" "uv-managed Python environments."
knit_env_provision knit_uv_provision --options "uv:string"
knit_env_install   knit_uv_install_env
knit_env_activate  knit_uv_activation
knit_env_specs     knit_uv_specs_to_manifest
knit_env_manifest  "pyproject.toml"
knit_env_lockfile  "uv.lock"
knit_env_done

# @fn knit_uv_exec()
#
# Run the knit-provisioned uv, forwarding all arguments verbatim (this is the
# body of the "knit uv" wrapper). Fatal-with-hint if uv has not been provisioned.
# Unlike the Spack wrapper, uv is a single static binary with no per-process
# setup to source, so this just runs "<root>/bin/uv" and returns its status. It
# deliberately does not "exec" the binary: the wrapper declares a table, and
# exec-ing would replace the knit process before the invocation is recorded.
#
# @param[in] ... Arguments forwarded verbatim to uv (including --help).
# @return The exit status of uv.
knit_uv_exec() {
    if [[ ! -x "${KNIT_UV_ROOT}/bin/uv" ]]; then
        knit_fatal "uv is not provisioned in %s. Run 'bootstrap --uv' (optionally with a ref) first." \
            "${KNIT_UV_ROOT}"
    fi
    "${KNIT_UV_ROOT}/bin/uv" "$@"
}

# Register the "knit uv" wrapper: forwards every argument verbatim to the
# knit-provisioned uv. Declaring a table logs each invocation's full command
# line (schema id, args) for provenance.
knit_register_wrapper "uv" "knit_uv_exec" \
    "Run the knit-provisioned uv, forwarding all arguments verbatim."
knit_with_table
knit_done
