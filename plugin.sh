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
