# knit-uv

A [Knit](https://github.com/knit-sh/knit) plugin that adds
[uv](https://docs.astral.sh/uv/) (Astral's fast Python package/project manager)
as an environment manager. Import it to provision a pinned, Python-free uv into a
knit experiment and build reproducible Python environments for your setups.

## What it adds

Importing the plugin gives an experiment:

- **`knit bootstrap --uv [<ref>]`** — provision uv into the experiment's `.knit`
  directory. A ref is a release tag; empty means the latest release. The resolved
  tag and the downloaded binary's sha256 are recorded in provenance metadata.
- **`knit_with_uv_env <pyproject.toml>`** / **`@with_uv_env`** — declare that a
  setup builds a Python environment from a `pyproject.toml` manifest (a path, or
  fed on stdin). `uv sync` resolves and installs it, writing `uv.lock`.
- **`knit_with_uv_specs <spec>...`** / **`@with_uv_specs`** — the same, but from a
  bare list of PEP 508 requirements; the plugin writes the minimal
  `pyproject.toml` for you.
- **`knit uv <args>...`** — run the knit-provisioned uv, forwarding every
  argument verbatim.

Provisioning, update-mode re-provisioning, the freeze-on-built rule, the
`.activate.sh` re-entry lines for dependent jobs, and the manifest/lock
provenance are all handled by knit's generic environment-manager layer; the
plugin supplies only the uv-specific verbs.

## Use it

Add one line near the top of your experiment, after `source knit.sh`:

```bash
source knit.sh
knit_import uv               # github.com/knit-sh/knit-uv
```

Then bootstrap and build a setup:

```bash
./experiment.sh bootstrap

@setup "pyenv" build_pyenv "Build the experiment's Python env."
@with_uv_specs "numpy" "scipy"
@done
```

Pin a specific uv release instead of the latest:

```bash
./experiment.sh bootstrap --uv 0.13.1
```

## How it provisions

The plugin downloads the prebuilt uv binary for the host platform as a GitHub
release asset with `curl` and `tar` (knit's `knit_github_download_asset`), so it
needs **no Python and no git**. The host triple (`uname -s`/`uname -m`) selects
the asset — Linux x86_64/aarch64 and macOS x86_64/arm64 are supported. The
resolved release tag and the asset's sha256 are stored in the experiment's
metadata, so a reproducer provisions the same uv.

The environment itself is reproducible through `uv.lock`: `uv sync` records the
exact resolved dependency set (and, via `requires-python`, downloads a matching
managed Python under `.knit/uv`), which knit captures as provenance.

## Requirements

- Knit (the released `knit.sh`).
- `curl` and `tar` on `PATH`.
- Network access to GitHub (to fetch uv) and to the Python package index (for
  `uv sync`).

## Development

The plugin is a single `plugin.sh` at the repository root. Run the static
checker:

```bash
shellcheck plugin.sh
```

The test suite needs a `knit.sh` build and runs with
[bats](https://bats-core.readthedocs.io/):

```bash
KNIT_SH=/path/to/knit.sh bats tests/test_uv.sh tests/test_setup_uv.sh
```

`KNIT_SH` must point at a `knit.sh` that does not itself register a `uv`
environment manager; the released `knit.sh` is such a build.
