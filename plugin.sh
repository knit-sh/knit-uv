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
# shorthands), the knit_with_uv_layered directive (@with_uv_layered) for a
# layered environment, and the "knit uv" command.
#
# The plugin uses only knit's public API (knit_* functions): the knit_env_*
# environment-manager verbs, knit_env_record_option (which backs the custom
# knit_with_uv_layered directive), and knit_register_shorthand. It provisions uv
# by downloading the prebuilt release binary for the host platform with curl and
# tar (knit's release-asset helper), so it needs no Python and no git.

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

# @fn knit_uv_manifest_dependencies()
#
# Print, one per line, each requirement string in a pyproject.toml's
# "[project].dependencies" array. Used by the layered install path, which installs
# the setup's specs with "uv pip install" rather than syncing the whole manifest.
# The array is the multi-line, one-entry-per-line form the specs sugar synthesizes
# (knit_uv_specs_to_manifest): the block opens on a "dependencies = [" line and
# closes on a line that is just "]", so a requirement carrying a bracketed extra
# (e.g. "pillow[avif]>=11") does not end it.
#
# @param[in] manifest Path to the pyproject.toml manifest.
knit_uv_manifest_dependencies() {
    local manifest="$1"
    awk '
        /^[[:space:]]*dependencies[[:space:]]*=[[:space:]]*\[/ { indeps = 1; next }
        indeps && /^[[:space:]]*\][[:space:]]*$/ { indeps = 0; next }
        indeps {
            line = $0
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            sub(/,$/, "", line)
            sub(/^"/, "", line); sub(/"$/, "", line)
            if (line != "") print line
        }
    ' "${manifest}"
}

# @fn knit_uv_install_env()
#
# Install verb (knit_env_install): build the setup's uv environment from a
# pyproject.toml manifest. Two modes, selected by the trailing build options knit
# forwards (recorded by the setup's directives):
#
#   * Hermetic (default, no "layered" option): "uv sync" on a uv-managed
#     CPython — the environment is self-contained and reproducible on any machine
#     (see knit_uv_install_env_hermetic).
#   * Layered (the "layered" option): a venv on the ambient (profile/module)
#     interpreter with --system-site-packages, into which the manifest's specs are
#     installed with "uv pip install" (see knit_uv_install_env_layered).
#
# The manifest is placed inside the environment directory (uv resolves the project
# from "<env_dir>/pyproject.toml"), and uv's managed interpreters and download
# cache are kept under ".knit/uv" so nothing uv touches escapes the experiment's
# ".knit". Both modes run uv directly (stdout/stderr inherit the caller's
# terminal) and, on failure, log a knit_error and return non-zero (never
# knit_fatal) so the setup dispatcher can remove the half-built setup directory.
#
# Unknown options are ignored (forward compatibility with options a newer core
# records but this plugin version does not interpret).
#
# @param[in] env_dir  Directory in which to build the uv environment.
# @param[in] manifest Path to the pyproject.toml manifest describing the project.
# @param[in] ...      Manager-specific build options ("layered", "no-deps").
# @return 0 if the environment was built, non-zero otherwise.
knit_uv_install_env() {
    local env_dir="$1"
    local manifest="$2"
    shift 2
    local layered="false" no_deps="false"
    local opt
    for opt in "$@"; do
        case "${opt}" in
            layered) layered="true" ;;
            no-deps) no_deps="true" ;;
            *) knit_warning "knit-uv: ignoring unknown build option \"%s\"." "${opt}" ;;
        esac
    done

    mkdir -p "${env_dir}"
    # The generic layer materializes the manifest elsewhere under
    # KNIT_SETUP_PREFIX; copy it in (skipping a no-op self-copy if already there)
    # so uv resolves the project from "<env_dir>/pyproject.toml" and so the
    # after-callback captures it as provenance.
    if [[ "${manifest}" != "${env_dir}/pyproject.toml" ]]; then
        cp "${manifest}" "${env_dir}/pyproject.toml"
    fi
    export UV_PYTHON_INSTALL_DIR="${KNIT_UV_ROOT}/python"
    export UV_CACHE_DIR="${KNIT_UV_ROOT}/cache"

    if [[ "${layered}" == "true" ]]; then
        knit_uv_install_env_layered "${env_dir}" "${no_deps}"
    else
        knit_uv_install_env_hermetic "${env_dir}" "${manifest}"
    fi
}

# @fn knit_uv_install_env_hermetic()
#
# Hermetic install: run "uv sync" with the project rooted at <env_dir>, so uv
# creates "<env_dir>/.venv" and writes "<env_dir>/uv.lock", resolving the whole
# dependency set and downloading a managed interpreter that satisfies
# requires-python. Always builds on a uv-managed CPython, never the host Python:
# uv ignores whatever is installed on the login node, keeping the environment
# self-contained and reproducible across machines (a host with no Python, an old
# Python, or a differently-patched one all resolve to the same managed
# interpreter) and letting a manifest require a Python newer than the host.
#
# @param[in] env_dir  The uv environment directory (holds pyproject.toml).
# @param[in] manifest Path to the manifest, for the error message only.
# @return 0 if the sync succeeded, non-zero otherwise.
knit_uv_install_env_hermetic() {
    local env_dir="$1"
    local manifest="$2"
    export UV_PYTHON_PREFERENCE="only-managed"
    if ! "${KNIT_UV_ROOT}/bin/uv" sync --project "${env_dir}"; then
        knit_error "uv failed to sync the environment at %s from %s." \
            "${env_dir}" "${manifest}"
        return 1
    fi
}

# @fn knit_uv_install_env_layered()
#
# Layered install: create a venv on the ambient (platform/module-provided)
# interpreter with --system-site-packages, then install the setup's specs on top
# with "uv pip install". The interpreter is resolved with --python-preference
# only-system so uv never downloads a managed CPython: knit sources the profile
# (its "module load") before the install, so the module's Python — carrying, for
# example, Aurora's XPU-built torch — is the one on PATH and is inherited into the
# venv's site-packages. The specs come from the manifest's [project].dependencies
# (layered mode pairs with the spec directives, so the manifest is the specs
# list). With no_deps "true" the specs are installed with --no-deps, so a package
# a module already provides is not overwritten by a public-index build of the
# same name pulled in as a transitive dependency.
#
# Layered mode runs no "uv sync", so there is no uv.lock. For provenance it
# instead writes a "uv pip freeze" of the built venv to the lockfile path the
# generic after-callback captures as __uv_lock__ (see knit_uv_freeze_lock). That
# is best-effort: a freeze failure warns but does not discard a working
# environment.
#
# @param[in] env_dir The uv environment directory (holds pyproject.toml).
# @param[in] no_deps "true" to install the specs with --no-deps, "false" otherwise.
# @return 0 if the venv was created and the specs installed, non-zero otherwise.
knit_uv_install_env_layered() {
    local env_dir="$1"
    local no_deps="$2"
    local uv="${KNIT_UV_ROOT}/bin/uv"
    if ! "${uv}" venv --system-site-packages --python-preference only-system \
            "${env_dir}/.venv"; then
        knit_error "uv failed to create the layered venv at %s/.venv." "${env_dir}"
        return 1
    fi
    local specs=()
    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] && specs+=("${line}")
    done < <(knit_uv_manifest_dependencies "${env_dir}/pyproject.toml")
    if [[ ${#specs[@]} -eq 0 ]]; then
        knit_error "The layered uv environment at %s declares no dependencies to install." \
            "${env_dir}"
        return 1
    fi
    local pip_args=(pip install --python "${env_dir}/.venv/bin/python")
    [[ "${no_deps}" == "true" ]] && pip_args+=(--no-deps)
    if ! "${uv}" "${pip_args[@]}" "${specs[@]}"; then
        knit_error "uv failed to install the layered specs into %s/.venv." "${env_dir}"
        return 1
    fi
    knit_uv_freeze_lock "${env_dir}"
}

# @fn knit_uv_freeze_lock()
#
# Write a "uv pip freeze" of the layered venv to "<env_dir>/uv.lock", the
# lockfile path the generic after-callback captures as the __uv_lock__ provenance
# output. Layered mode has no real uv.lock (it runs no "uv sync"); the freeze is
# its reproducibility snapshot — the concrete set of versions that landed in the
# venv on top of the module's interpreter. A leading comment marks the file as a
# layered freeze so it is not mistaken for a uv sync lock (it is requirements
# format, not uv.lock TOML).
#
# Best-effort: if the freeze fails the environment is still usable, so this warns
# and leaves no lockfile (the __uv_lock__ output stays empty) rather than failing
# the setup.
#
# @param[in] env_dir The layered uv environment directory (holds .venv).
knit_uv_freeze_lock() {
    local env_dir="$1"
    local freeze
    if freeze="$("${KNIT_UV_ROOT}/bin/uv" pip freeze \
            --python "${env_dir}/.venv/bin/python" 2>/dev/null)"; then
        printf '# knit-uv layered environment: uv pip freeze snapshot (not a uv sync lock).\n%s\n' \
            "${freeze}" > "${env_dir}/uv.lock"
    else
        knit_warning "Could not freeze the layered uv environment at %s/.venv; __uv_lock__ provenance will be empty." \
            "${env_dir}"
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
# version are fixed placeholders. No requires-python is pinned: the synthesized
# project imposes no Python floor of its own, so the dependencies dictate the
# interpreter (a dependency needing, e.g., Python >= 3.11 is honored, not
# rejected because the project claimed to support older versions). The managed
# CPython is still forced by knit_uv_install_env (UV_PYTHON_PREFERENCE), so
# dropping the floor does not fall back to a system Python. A setup that needs an
# explicit floor uses knit_with_uv_env with a real pyproject.toml instead.
# Printed to stdout; knit feeds it to knit_with_uv_env.
#
# @param[in] ... One or more PEP 508 requirement strings (e.g. "numpy>=2").
knit_uv_specs_to_manifest() {
    local toml spec
    toml=$'[project]\nname = "knit-uv-env"\nversion = "0.0.0"\ndependencies = [\n'
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

# @fn knit_with_uv_layered()
#
# Setup directive: build this setup's uv environment in LAYERED mode instead of
# the default hermetic mode. A layered environment is a venv created on the
# ambient (platform/module-provided) Python interpreter with
# --system-site-packages, into which the setup's specs are installed — rather
# than a self-contained "uv sync" on a managed CPython. Use it when a site ships
# a blessed interpreter + framework stack as a module (for example Aurora's
# "frameworks" module, carrying an XPU-built torch) that the experiment should
# layer on, not rebuild. The profile must put that interpreter on PATH (e.g.
# modules: ["frameworks"]); knit sources the profile before the environment is
# built.
#
# Valid only inside a setup registration (knit_env_record_option is fatal
# otherwise). It records the "layered" build option through knit's
# environment-manager options channel; the install verb (knit_uv_install_env)
# reads it and switches to the venv/pip path. It also notes the layered build in
# the setup's "--help" and pushes a done-callback that rejects a layered
# environment declared with a complete manifest.
#
# Layered mode pairs with the spec directives (knit_with_uv_specs /
# knit_with_uv_specs_from), not a full manifest: see
# knit_uv_reject_layered_manifest.
knit_with_uv_layered() {
    knit_env_record_option "uv" "layered"
    knit_add_command_note "The uv environment is layered on the platform-provided Python: the venv inherits the active module's site-packages (knit_with_uv_layered)."
    knit_push_done_cb knit_uv_reject_layered_manifest "${_KNIT_CURRENT_COMMAND}"
}

# @fn knit_uv_reject_layered_manifest()
#
# Done-callback pushed by knit_with_uv_layered. It runs at the close of the setup
# registration, when the environment mode is finally known regardless of the
# order the directives were written, and rejects a layered environment declared
# with a complete manifest (world A: knit_with_uv_env / knit_with_uv_env_from).
# Layered mode installs the setup's specs on top of a module-provided interpreter
# with "uv pip install", so it pairs with the spec directives; a full manifest
# would be re-resolved and reinstalled by "uv sync", defeating the layer. Fatal
# in that case, naming the directives and pointing at the spec directives.
#
# The mode is read from _KNIT_CMD_<cmd>_envmode_uv, which knit sets to "env" for a
# manifest and "specs" for a spec list (empty when the setup declares no uv
# environment, in which case there is nothing to reject).
#
# @param[in] cmd Mangled command name of the setup being registered.
knit_uv_reject_layered_manifest() {
    local cmd="$1"
    local mode_var="_KNIT_CMD_${cmd}_envmode_uv"
    if [[ "${!mode_var:-}" == "env" ]]; then
        knit_fatal "Setup \"%s\" declares a layered uv environment (knit_with_uv_layered) together with a complete manifest (knit_with_uv_env / knit_with_uv_env_from). Layered mode installs specs on top of the platform interpreter, so declare the packages with knit_with_uv_specs / knit_with_uv_specs_from instead." \
            "${cmd//__1__/:}"
    fi
}

# @fn knit_with_uv_no_deps()
#
# Setup directive: install this setup's specs with --no-deps, so uv installs each
# spec without its transitive dependencies. Normally paired with
# knit_with_uv_layered: when layering on a module that already provides a
# framework (for example Aurora's torch), --no-deps keeps a spec from pulling a
# public-index build of that same package over the module's one. It is accepted
# without knit_with_uv_layered too (a hermetic install then ignores it, since
# "uv sync" resolves from the manifest), but that combination is unusual.
#
# Valid only inside a setup registration (knit_env_record_option is fatal
# otherwise). It records the "no-deps" build option through knit's
# environment-manager options channel; the install verb reads it and adds
# --no-deps to the layered "uv pip install".
knit_with_uv_no_deps() {
    knit_env_record_option "uv" "no-deps"
}

# Give the layered-mode directives their "@" shorthands. The plugin loads after
# src/shorthand.sh, so the shorthand seam already exists; register now (each
# target function is defined just above, as knit_register_shorthand requires).
knit_register_shorthand "with_uv_layered" "knit_with_uv_layered"
knit_register_shorthand "with_uv_no_deps" "knit_with_uv_no_deps"

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
