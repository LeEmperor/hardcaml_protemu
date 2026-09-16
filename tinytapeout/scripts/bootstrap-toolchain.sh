#!/usr/bin/env bash
#
# Prepare the project-local CMOS5L toolchain described in
# docs/bootstrap-toolchain-plan.md.
#
# Bootstrapping prepares an environment. It does NOT prove that the design passes
# hardening, timing, physical verification, or precheck. Those are separate
# commands with their own results.
#
# All version authority lives in tinytapeout/toolchain.lock. This script parses
# that file as data and never sources it.

set -euo pipefail

# ---------------------------------------------------------------------------
# Exit codes. Section 9 of the plan requires distinguishable failure classes.
# ---------------------------------------------------------------------------
readonly EX_GENERAL=1
readonly EX_PREREQ=2       # missing or unusable host prerequisite
readonly EX_LOCKFILE=3     # malformed, incomplete, or unsupported lockfile
readonly EX_NETWORK=4      # clone/fetch/install could not complete
readonly EX_MISMATCH=5     # wrong revision, dirty checkout, or bad hash
readonly EX_PDK=6          # PDK present but incomplete or unidentifiable
readonly EX_TOOL=7         # a tool ran and failed

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
step()  { printf '\n==> %s\n' "$*"; }
info()  { printf '    %s\n' "$*"; }
warn()  { printf '    warning: %s\n' "$*" >&2; }
net()   { printf '    [network] %s\n' "$*"; }

die() {
    local code=$1
    shift
    printf '\nerror: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit "$code"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
offline=0
check_only=0
require_container=1

usage() {
    cat <<'USAGE'
Usage: tinytapeout/scripts/bootstrap-toolchain.sh [options]

Prepares the project-local CMOS5L toolchain: Python environment, pinned
tt-support-tools checkout, LibreLane, and the IHP Open PDK. Writes only to
ignored paths beneath tinytapeout/ unless an external support-tools checkout is
supplied, which is validated and never modified.

Options:
  --offline        Validate and reuse an already populated environment. Performs
                   no clone, fetch, or install. Fails clearly if something is
                   missing rather than downloading it.
  --check          Validate everything and change nothing. Implies --offline.
  --no-container   Skip the container-runtime prerequisite. LibreLane normally
                   runs dockerized; tt-support-tools also supports a native
                   no-docker path. Use this only if you intend to supply a
                   native LibreLane yourself.
  -h, --help       Show this message.

Environment:
  TT_SUPPORT_TOOLS_DIR   Use an existing tt-support-tools checkout instead of a
                         managed one. It is validated, never modified, and never
                         switched to another revision.
USAGE
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --offline) offline=1 ;;
        --check) check_only=1; offline=1 ;;
        --no-container) require_container=0 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "$EX_GENERAL" "unknown option: $1" ;;
    esac
    shift
done

# A single guard for every mutating action, so --check cannot change anything.
mutating() { [[ $check_only -eq 0 ]]; }

# ---------------------------------------------------------------------------
# Paths. Resolved from the script location, never from the caller's cwd.
# ---------------------------------------------------------------------------
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)
readonly script_dir repo_root

readonly tt_dir="$repo_root/tinytapeout"
readonly lock_file="$tt_dir/toolchain.lock"
# The Python environment belongs to the repository, not to the Tiny Tapeout
# subtree: LibreLane and precheck are ASIC-flow tools that happen to be reached
# through TT. Keeping it at the root keeps this a dune/Hardcaml project that
# uses TT for tooling, rather than a TT project with OCaml in it.
readonly venv_dir="$repo_root/.venv"
# Precheck cannot share the main environment: precheck/pyproject.toml pins
# klayout >=0.28.17.post1,<0.29.0 while the top-level requirements pin 0.29.12,
# and gdstk differs too. Two environments is not a preference, it is forced.
readonly precheck_venv_dir="$repo_root/.venv-precheck"
readonly pdk_dir="$tt_dir/pdk"
readonly managed_tt_dir="$tt_dir/tt"
readonly stage_dir="$tt_dir/build/p0-staged"
readonly env_file="$tt_dir/build/toolchain-env.sh"

# Section 9: resolve and validate a path before creating or replacing anything
# under it. Only the ignored toolchain subtrees are writable: the root .venv
# and the ignored directories beneath tinytapeout/.
assert_writable_path() {
    local path=$1
    case $path in
        "$repo_root"/.venv|"$repo_root"/.venv/*) ;;
        "$repo_root"/.venv-precheck|"$repo_root"/.venv-precheck/*) ;;
        "$tt_dir"/pdk|"$tt_dir"/pdk/*) ;;
        "$tt_dir"/tt|"$tt_dir"/tt/*) ;;
        "$tt_dir"/build|"$tt_dir"/build/*) ;;
        *) die "$EX_GENERAL" "refusing to write outside the ignored toolchain paths: $path" ;;
    esac
}

# ---------------------------------------------------------------------------
# Portable helpers
# ---------------------------------------------------------------------------
abspath() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# True only when $1 is itself the root of a git checkout.
#
# Testing for a .git *directory* is wrong: in a linked worktree .git is a file,
# and the plan's documented development layout uses a worktree. Comparing the
# toplevel is also what stops an ignored directory inside this repository, such
# as tinytapeout/pdk, from reading as a checkout of the repository itself.
is_git_checkout() {
    local dir=$1 top
    [[ -d $dir ]] || return 1
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ $(abspath "$top") == "$(abspath "$dir")" ]]
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# 1. Lockfile. Parsed as data: no sourcing, so a modified lockfile cannot run
#    shell code. Duplicate and malformed keys are rejected.
# ---------------------------------------------------------------------------
declare -A LOCK

parse_lockfile() {
    [[ -f $lock_file ]] || die "$EX_LOCKFILE" "lockfile not found: $lock_file"

    local line key value lineno=0
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            die "$EX_LOCKFILE" "malformed lockfile line $lineno" "$line"
        fi
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        if [[ -n ${LOCK[$key]+set} ]]; then
            die "$EX_LOCKFILE" "duplicate key '$key' at line $lineno of $lock_file"
        fi
        LOCK[$key]=$value
    done <"$lock_file"
}

lock() {
    local key=$1
    [[ -n ${LOCK[$key]+set} ]] || die "$EX_LOCKFILE" "missing required lockfile key: $key"
    printf '%s' "${LOCK[$key]}"
}

validate_lockfile() {
    local key
    for key in \
        template_repository template_branch template_revision \
        gds_action_repository gds_action_branch gds_action_revision \
        support_tools_repository support_tools_branch support_tools_revision \
        pdk pdk_repository pdk_revision \
        librelane_version python tiles \
        floorplan_def floorplan_def_sha256 floorplan_die_area
    do
        [[ -n ${LOCK[$key]+set} ]] || die "$EX_LOCKFILE" "missing required lockfile key: $key"
    done

    # Section 11: a different process or allocation is a reviewed lockfile
    # change, never an implicit one.
    [[ $(lock pdk) == "ihp-sg13cmos5l" ]] || die "$EX_LOCKFILE" \
        "unsupported process: $(lock pdk)" \
        "This script supports ihp-sg13cmos5l only."
    [[ $(lock tiles) == "6x4" ]] || die "$EX_LOCKFILE" \
        "unsupported tile allocation: $(lock tiles)" \
        "6x4 is the authoritative competition target. Changing it is a reviewed" \
        "change to toolchain.lock, not a flag."

    local rev
    for key in support_tools_revision pdk_revision template_revision gds_action_revision; do
        rev=$(lock "$key")
        [[ $rev =~ ^[0-9a-f]{40}$ ]] || die "$EX_LOCKFILE" \
            "$key is not a full 40-character git revision: $rev"
    done

    [[ $(lock floorplan_def_sha256) =~ ^[0-9a-f]{64}$ ]] || die "$EX_LOCKFILE" \
        "floorplan_def_sha256 is not a SHA-256 digest"
}

# ---------------------------------------------------------------------------
# 2. Host prerequisites. Checked before anything is downloaded or installed.
#    Never installed here: that needs authority this repository does not have.
# ---------------------------------------------------------------------------
check_prerequisites() {
    step "Checking host prerequisites"

    if [[ ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
        die "$EX_PREREQ" "bash 4 or newer is required (found ${BASH_VERSION:-unknown})" \
            "macOS ships bash 3.2. Install a newer bash and rerun with it."
    fi

    local tool missing=()
    for tool in git awk grep make python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || missing+=("sha256sum or shasum")
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "$EX_PREREQ" "missing host prerequisites: ${missing[*]}" \
            "Install them with your operating system's package manager."
    fi

    local py_version
    py_version=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
        die "$EX_PREREQ" "python3 is $py_version; 3.11 or newer is required" \
            "The pinned flow expects Python $(lock python)."
    fi
    # Only required when an environment has to be created. A usable environment
    # that already exists is checked in ensure_venv instead.
    #
    # Checking `import venv` alone is not enough: the module imports on systems
    # where ensurepip has been split into a separate package, and creation then
    # fails partway through, leaving a broken directory behind.
    if [[ ! -d $venv_dir ]] && ! python3 -c 'import venv, ensurepip' 2>/dev/null; then
        die "$EX_PREREQ" "python3 cannot create virtual environments" \
            "Both the venv and ensurepip modules are required." \
            "On Debian/Ubuntu install the matching package, for example:" \
            "  apt install python${py_version}-venv" \
            "Alternatively, place a usable environment at $venv_dir yourself."
    fi
    info "python3 $py_version (lockfile expects $(lock python))"

    if [[ $require_container -eq 1 ]]; then
        local runtime=""
        for tool in docker podman; do
            command -v "$tool" >/dev/null 2>&1 && { runtime=$tool; break; }
        done
        if [[ -z $runtime ]]; then
            die "$EX_PREREQ" "no Docker-compatible container runtime found" \
                "LibreLane runs dockerized by default; tt-support-tools invokes it as" \
                "  python -m librelane --dockerized ... src/config_merged.json" \
                "Install and start Docker (or Podman) and make it usable by this user," \
                "or rerun with --no-container if you will supply a native LibreLane." \
                "This repository will not install or configure a container daemon."
        elif ! "$runtime" info >/dev/null 2>&1; then
            die "$EX_PREREQ" "$runtime is installed but not usable by this user" \
                "Start the service and confirm your user may talk to it, then rerun."
        else
            info "container runtime: $runtime"
        fi
    else
        warn "container check skipped; hardening will need a native LibreLane"
    fi

    local avail
    avail=$(df -Pk "$tt_dir" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}') || avail=""
    if [[ -n $avail ]]; then
        info "free space on the toolchain filesystem: ${avail} GiB"
        # No hard minimum is enforced. The plan asks for a figure published only
        # after a clean bootstrap has actually been observed.
    fi
}

# ---------------------------------------------------------------------------
# 3. Python environment
# ---------------------------------------------------------------------------
ensure_venv() {
    step "Preparing the Python environment"

    if [[ -d $venv_dir ]]; then
        [[ -x $venv_dir/bin/python ]] || die "$EX_PREREQ" \
            "$venv_dir exists but is not a virtual environment" \
            "Inspect it and remove it yourself; this script will not delete it."
        local existing
        existing=$("$venv_dir/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
        if ! "$venv_dir/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'; then
            die "$EX_PREREQ" "existing environment uses Python $existing; 3.11+ required" \
                "Remove $venv_dir yourself and rerun."
        fi
        # An environment built with --without-pip, or one whose pip was removed,
        # reads as valid here and then fails at the first install.
        "$venv_dir/bin/python" -m pip --version >/dev/null 2>&1 || die "$EX_PREREQ" \
            "the environment at $venv_dir has no working pip" \
            "Remove it yourself and rerun so it can be recreated."
        info "reusing existing environment (Python $existing)"
        return
    fi

    if ! mutating; then
        die "$EX_PREREQ" "no Python environment at $venv_dir" "Rerun without --check to create it."
    fi
    if [[ $offline -eq 1 ]]; then
        die "$EX_PREREQ" "no Python environment at $venv_dir" "Rerun without --offline to create it."
    fi

    assert_writable_path "$venv_dir"
    if ! python3 -m venv "$venv_dir"; then
        # A failed creation leaves a partial directory that would otherwise be
        # reported as "not a virtual environment" on every later run. Removing
        # it is safe: this call created it, and the path is already validated.
        rm -rf "$venv_dir"
        die "$EX_TOOL" "failed to create $venv_dir" \
            "The partial directory was removed. Fix the reported cause and rerun."
    fi
    info "created $venv_dir"
}

# ---------------------------------------------------------------------------
# 4. Support tools. An externally supplied checkout is validated and never
#    modified. A managed checkout may move to the locked revision only when it
#    is clean.
# ---------------------------------------------------------------------------
support_tools_dir=""
support_tools_managed=0

resolve_support_tools() {
    step "Resolving tt-support-tools"

    local default_external="$repo_root/../tt-support-tools-cmos5l"

    if [[ -n ${TT_SUPPORT_TOOLS_DIR:-} ]]; then
        [[ -d $TT_SUPPORT_TOOLS_DIR ]] || die "$EX_PREREQ" \
            "TT_SUPPORT_TOOLS_DIR does not exist: $TT_SUPPORT_TOOLS_DIR"
        support_tools_dir=$(abspath "$TT_SUPPORT_TOOLS_DIR")
        info "using TT_SUPPORT_TOOLS_DIR (external, read-only to this script)"
    elif [[ -d $default_external ]]; then
        support_tools_dir=$(abspath "$default_external")
        info "using the sibling checkout (external, read-only to this script)"
        info "  $support_tools_dir"
    else
        support_tools_dir=$managed_tt_dir
        support_tools_managed=1
        info "using the managed checkout at $managed_tt_dir"
    fi

    if [[ $support_tools_managed -eq 1 ]]; then
        ensure_managed_support_tools
    fi
    verify_support_tools_revision
}

ensure_managed_support_tools() {
    local want; want=$(lock support_tools_revision)

    if ! is_git_checkout "$managed_tt_dir"; then
        if [[ -e $managed_tt_dir ]]; then
            die "$EX_MISMATCH" "$managed_tt_dir exists but is not a git checkout" \
                "Inspect and remove it yourself; this script will not delete it."
        fi
        [[ $offline -eq 0 ]] || die "$EX_NETWORK" \
            "no support-tools checkout and --offline was given" \
            "Rerun online, or set TT_SUPPORT_TOOLS_DIR to an existing checkout."
        mutating || die "$EX_MISMATCH" "no support-tools checkout at $managed_tt_dir"

        assert_writable_path "$managed_tt_dir"
        net "cloning $(lock support_tools_repository)"
        git clone --quiet "$(lock support_tools_repository)" "$managed_tt_dir" \
            || die "$EX_NETWORK" "clone failed: $(lock support_tools_repository)"
    fi

    # Never discard local changes; stop with an actionable error instead.
    if [[ -n $(git -C "$managed_tt_dir" status --porcelain) ]]; then
        die "$EX_MISMATCH" "managed support-tools checkout is dirty: $managed_tt_dir" \
            "This script never discards local changes. Resolve them yourself."
    fi

    local head; head=$(git -C "$managed_tt_dir" rev-parse HEAD)
    if [[ $head != "$want" ]]; then
        [[ $offline -eq 0 ]] || die "$EX_NETWORK" \
            "managed checkout is at $head, lockfile wants $want, and --offline was given"
        mutating || die "$EX_MISMATCH" "managed checkout is at $head, lockfile wants $want"

        if ! git -C "$managed_tt_dir" cat-file -e "$want^{commit}" 2>/dev/null; then
            net "fetching $want"
            git -C "$managed_tt_dir" fetch --quiet origin "$(lock support_tools_branch)" \
                || die "$EX_NETWORK" "fetch failed for $(lock support_tools_branch)"
        fi
        # Detached HEAD at the exact locked revision: never a branch head.
        git -C "$managed_tt_dir" checkout --quiet --detach "$want" \
            || die "$EX_MISMATCH" "could not check out $want"
        info "moved managed checkout to $want"
    fi
}

verify_support_tools_revision() {
    is_git_checkout "$support_tools_dir" || die "$EX_MISMATCH" \
        "not a git checkout: $support_tools_dir"

    local want head
    want=$(lock support_tools_revision)
    head=$(git -C "$support_tools_dir" rev-parse HEAD)
    if [[ $head != "$want" ]]; then
        die "$EX_MISMATCH" "tt-support-tools is at the wrong revision" \
            "found:    $head" \
            "expected: $want" \
            "This script never switches an externally supplied checkout." \
            "Select the required revision yourself, or unset TT_SUPPORT_TOOLS_DIR."
    fi
    if [[ -n $(git -C "$support_tools_dir" status --porcelain) ]]; then
        die "$EX_MISMATCH" "tt-support-tools checkout is dirty: $support_tools_dir"
    fi
    info "revision $head, clean"
}

# ---------------------------------------------------------------------------
# 5. Floorplan inputs, verified against the lockfile before the flow starts.
# ---------------------------------------------------------------------------
verify_floorplan() {
    step "Verifying the $(lock tiles) floorplan inputs"

    local pdk_name tiles tile_sizes def_path
    pdk_name=$(lock pdk)
    tiles=$(lock tiles)
    tile_sizes="$support_tools_dir/tech/$pdk_name/tile_sizes.yaml"
    def_path="$support_tools_dir/$(lock floorplan_def)"

    [[ -f $tile_sizes ]] || die "$EX_MISMATCH" \
        "tile size table not found: $tile_sizes" \
        "The checkout may not support $pdk_name."
    [[ -f $def_path ]] || die "$EX_MISMATCH" \
        "floorplan DEF not found: $def_path" \
        "$tiles has no floorplan in this support-tools revision."

    # The lockfile stores the die area comma-separated; the tile table uses
    # spaces. Compare on a normalised form.
    local want_area entry
    want_area=$(lock floorplan_die_area | tr ',' ' ')
    entry="$tiles: \"$want_area\""
    grep -Fxq "$entry" "$tile_sizes" || die "$EX_MISMATCH" \
        "tile table does not contain the locked entry" \
        "expected line: $entry" \
        "in: $tile_sizes"

    local actual want
    actual=$(sha256_of "$def_path")
    want=$(lock floorplan_def_sha256)
    [[ $actual == "$want" ]] || die "$EX_MISMATCH" \
        "floorplan DEF hash mismatch" \
        "found:    $actual" \
        "expected: $want" \
        "file:     $def_path"

    info "$tiles die area $want_area"
    info "DEF hash verified"
}

# ---------------------------------------------------------------------------
# 6. Python packages. Installed only inside the project-local environment.
# ---------------------------------------------------------------------------
pip_run() { "$venv_dir/bin/python" -m pip "$@"; }

installed_version() {
    "$venv_dir/bin/python" - "$1" <<'PY' 2>/dev/null || true
import sys
from importlib.metadata import PackageNotFoundError, version
try:
    print(version(sys.argv[1]))
except PackageNotFoundError:
    pass
PY
}

install_python_packages() {
    step "Installing project-local Python packages"

    local want_librelane have_librelane
    want_librelane=$(lock librelane_version)
    have_librelane=$(installed_version librelane)

    if [[ $offline -eq 1 ]]; then
        [[ -n $have_librelane ]] || die "$EX_NETWORK" \
            "librelane is not installed and --offline was given"
        [[ $have_librelane == "$want_librelane" ]] || die "$EX_MISMATCH" \
            "librelane $have_librelane installed, lockfile wants $want_librelane"
        info "librelane $have_librelane (offline, reused)"
        return
    fi
    mutating || { info "would install support-tools requirements and librelane==$want_librelane"; return; }

    local requirements="$support_tools_dir/requirements.txt"
    [[ -f $requirements ]] || die "$EX_MISMATCH" "requirements.txt not found: $requirements"

    net "installing tt-support-tools requirements"
    pip_run install --quiet --upgrade pip >/dev/null \
        || die "$EX_NETWORK" "could not upgrade pip inside $venv_dir"
    pip_run install --quiet -r "$requirements" \
        || die "$EX_NETWORK" "failed to install $requirements"

    if [[ $have_librelane != "$want_librelane" ]]; then
        net "installing librelane==$want_librelane"
        pip_run install --quiet "librelane==$want_librelane" \
            || die "$EX_NETWORK" "failed to install librelane==$want_librelane"
    fi

    # Verify the resolved version rather than trusting the request.
    have_librelane=$(installed_version librelane)
    [[ $have_librelane == "$want_librelane" ]] || die "$EX_MISMATCH" \
        "librelane resolved to $have_librelane, lockfile wants $want_librelane"
    info "librelane $have_librelane"
}

# ---------------------------------------------------------------------------
# 6b. Precheck environment. Separate by necessity, not by taste: its klayout and
#     gdstk pins conflict with the top-level requirements.
#
#     Precheck also shells out to native `klayout` (and, for other processes,
#     `magic`), which pip cannot supply. Upstream ships precheck/default.nix
#     pinning nixpkgs for exactly those two, and precheck.sh runs inside it.
# ---------------------------------------------------------------------------
precheck_tools=""

install_precheck_environment() {
    step "Preparing the precheck environment"

    local requirements="$support_tools_dir/precheck/requirements.txt"
    [[ -f $requirements ]] || die "$EX_MISMATCH" \
        "precheck requirements not found: $requirements"

    if [[ ! -d $precheck_venv_dir ]]; then
        if [[ $offline -eq 1 ]] || ! mutating; then
            warn "no precheck environment at $precheck_venv_dir"
            warn "rerun without --offline/--check to create it"
            return
        fi
        assert_writable_path "$precheck_venv_dir"
        if ! python3 -m venv "$precheck_venv_dir"; then
            rm -rf "$precheck_venv_dir"
            die "$EX_TOOL" "failed to create $precheck_venv_dir"
        fi
        info "created $precheck_venv_dir"
    fi

    if [[ $offline -eq 0 ]] && mutating; then
        net "installing precheck requirements"
        "$precheck_venv_dir/bin/python" -m pip install --quiet --upgrade pip >/dev/null \
            || die "$EX_NETWORK" "could not upgrade pip inside $precheck_venv_dir"
        "$precheck_venv_dir/bin/python" -m pip install --quiet -r "$requirements" \
            || die "$EX_NETWORK" "failed to install $requirements"
    fi

    # The conflicting pin is the whole reason this environment exists, so confirm
    # it actually resolved the way precheck expects.
    local klayout_version
    klayout_version=$("$precheck_venv_dir/bin/python" -c \
        'from importlib.metadata import version; print(version("klayout"))' 2>/dev/null || true)
    if [[ -n $klayout_version ]]; then
        case $klayout_version in
            0.28.*) info "klayout python module $klayout_version" ;;
            *) warn "precheck environment has klayout $klayout_version; precheck pins 0.28.x" ;;
        esac
    elif [[ $offline -eq 0 ]] && mutating; then
        die "$EX_TOOL" "klayout did not install into $precheck_venv_dir"
    fi

    prepare_precheck_tools
}

# The native tools come from upstream's precheck/default.nix, never from PATH:
# a host-installed klayout is an unpinned version. Nix is a host prerequisite
# this script does not install, and precheck is a later step than bootstrap,
# so every problem here is reported rather than fatal. precheck.sh re-verifies
# and refuses to run on any of them.
prepare_precheck_tools() {
    local nix_file="$support_tools_dir/precheck/default.nix"
    local pins="$support_tools_dir/precheck/tool-versions.json"

    if ! command -v nix-shell >/dev/null 2>&1; then
        warn "nix-shell not found; precheck.sh needs Nix for its pinned KLayout"
        precheck_tools="nix not installed"
        return
    fi

    # With a daemon install, a user outside the daemon's allowed group gets
    # "Permission denied" on every command, so installed is not enough.
    if ! nix-instantiate --eval --expr 'builtins.nixVersion' >/dev/null 2>&1; then
        warn "Nix is installed but this user cannot use it (daemon permission denied)"
        warn "Ubuntu's nix-bin package limits the daemon to the nix-users group:"
        warn "  sudo usermod -aG nix-users \$USER   # then log out and back in"
        precheck_tools="nix not usable by $USER"
        return
    fi

    # Realizing the shell downloads KLayout and Magic into /nix/store. The
    # nixpkgs pin is a fetchTarball, which may touch the network, so this is
    # skipped offline and under --check.
    if [[ $offline -eq 1 ]] || ! mutating; then
        info "nix usable; pinned precheck tools not realized (offline)"
        precheck_tools="nix usable, not realized"
        return
    fi

    net "realizing $nix_file (first run downloads KLayout and Magic)"
    local versions
    if ! versions=$(nix-shell "$nix_file" --run 'klayout -v; magic --version 2>&1 || true' </dev/null); then
        warn "nix-shell could not provide the precheck tools; precheck.sh will retry"
        precheck_tools="nix realization failed"
        return
    fi

    local want have
    want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["klayout"])' "$pins")
    have=$(printf '%s\n' "$versions" | awk '$1 == "KLayout" { print $2; exit }')
    if [[ $have == "$want" ]]; then
        info "klayout $have from Nix (pinned $want)"
        precheck_tools="klayout $have via nix"
    else
        warn "Nix provided KLayout '${have:-unknown}'; tool-versions.json pins $want"
        precheck_tools="klayout ${have:-unknown} via nix (pin $want)"
    fi
}

# ---------------------------------------------------------------------------
# 7. PDK. Fetched at the exact pinned revision, then verified for the views the
#    flow and the gate-level test actually consume.
# ---------------------------------------------------------------------------
# Tracked or untracked changes in the PDK checkout, less the SOURCES record that
# ensure_pdk writes itself (upstream does not track it).
pdk_local_changes() {
    git -C "$pdk_dir" status --porcelain | grep -vxF "?? $(lock pdk)/SOURCES" || true
}

# The PDK is always a checkout this script created, never one supplied by the
# user, so a lockfile change moves it rather than requiring manual removal. The
# rules match the managed support-tools checkout: only when clean, only to the
# exact locked revision, detached. Only that revision is fetched (IHP-Open-PDK is
# large, so a full clone is avoided), and earlier revisions stay in the object
# store: switching back to a branch with an older lockfile works offline.
move_pdk() {
    local head=$1 want=$2
    local from=${head:-"no revision"}

    if [[ -n $head ]]; then
        local changes=()
        mapfile -t changes < <(pdk_local_changes)
        if [[ ${#changes[@]} -gt 0 ]]; then
            local shown=("${changes[@]:0:10}")
            die "$EX_MISMATCH" "PDK checkout is at $head, lockfile wants $want, and it has local changes" \
                "${shown[@]/#/  }" \
                "This script never discards local changes. If they are your edits, resolve" \
                "them yourself. If an earlier move was interrupted, finish it with:" \
                "  git -C $pdk_dir checkout --force --detach $want"
        fi
    fi
    mutating || die "$EX_MISMATCH" "PDK checkout is at $from, lockfile wants $want" \
        "Rerun without --check to move it."

    if ! git -C "$pdk_dir" cat-file -e "$want^{commit}" 2>/dev/null; then
        [[ $offline -eq 0 ]] || die "$EX_NETWORK" \
            "PDK checkout is at $from, lockfile wants $want, and --offline was given" \
            "That revision has never been fetched into $pdk_dir."
        local repo; repo=$(lock pdk_repository)
        git -C "$pdk_dir" remote set-url origin "$repo" 2>/dev/null \
            || git -C "$pdk_dir" remote add origin "$repo"
        net "fetching $repo at $want"
        git -C "$pdk_dir" fetch --quiet --depth 1 origin "$want" \
            || die "$EX_NETWORK" "could not fetch $want from $repo" \
                   "Some servers refuse fetch-by-SHA. If so, record a reachable tag or" \
                   "branch in toolchain.lock and rerun."
    fi

    git -C "$pdk_dir" -c advice.detachedHead=false checkout --quiet --detach "$want" \
        || die "$EX_MISMATCH" "could not check out $want in $pdk_dir" \
               "git reported the reason above. The checkout is unchanged or partly moved;" \
               "rerunning will say which."
    info "moved PDK from $from to $want"
}

ensure_pdk() {
    step "Preparing the $(lock pdk) PDK"

    local want; want=$(lock pdk_revision)

    if ! is_git_checkout "$pdk_dir"; then
        if [[ -e $pdk_dir ]]; then
            die "$EX_PDK" "$pdk_dir exists but is not a git checkout" \
                "Inspect and remove it yourself; this script will not delete it."
        fi
        [[ $offline -eq 0 ]] || die "$EX_NETWORK" "no PDK at $pdk_dir and --offline was given"
        mutating || die "$EX_PDK" "no PDK at $pdk_dir"

        assert_writable_path "$pdk_dir"
        mkdir -p "$pdk_dir"
        git -C "$pdk_dir" init --quiet
        git -C "$pdk_dir" remote add origin "$(lock pdk_repository)"
    fi

    # Empty only when an earlier first fetch was interrupted after `git init`:
    # nothing is checked out, so there is nothing to lose.
    local head
    head=$(git -C "$pdk_dir" rev-parse --verify --quiet HEAD) || head=""

    if [[ $head != "$want" ]]; then
        move_pdk "$head" "$want"
        head=$want
    else
        local changes=()
        mapfile -t changes < <(pdk_local_changes)
        if [[ ${#changes[@]} -gt 0 ]]; then
            # A warning rather than a refusal until a hardening run has shown
            # whether the flow itself writes beneath PDK_ROOT.
            warn "the PDK checkout has local changes; results may not match the lockfile:"
            printf '      %s\n' "${changes[@]:0:10}" >&2
        fi
    fi
    info "revision $head"

    # The upstream repository does not contain SOURCES. The pinned action's
    # install_sg13cmos5l.sh writes it immediately after the same checkout:
    #   echo "IHP-Open-PDK $IHP_PDK_REV" > "$PDK_ROOT/ihp-sg13cmos5l/SOURCES"
    # It is reproduced here from the verified HEAD, never from free text, and
    # repaired if an earlier run fetched the PDK without writing it.
    local process_dir="$pdk_dir/$(lock pdk)"
    local sources="$process_dir/SOURCES" record="IHP-Open-PDK $head"
    if [[ -d $process_dir ]] && { [[ ! -f $sources ]] || [[ $(<"$sources") != "$record" ]]; }; then
        if mutating; then
            assert_writable_path "$sources"
            printf '%s\n' "$record" >"$sources"
            info "wrote $sources (as tt-gds-action install_sg13cmos5l.sh does)"
        fi
    fi
}

verify_pdk() {
    step "Verifying PDK contents"

    local pdk_name root
    pdk_name=$(lock pdk)
    root="$pdk_dir/$pdk_name"

    [[ -d $root ]] || die "$EX_PDK" \
        "the PDK checkout has no $pdk_name directory" \
        "looked in: $root" \
        "The pinned revision may not contain this process, or PDK_ROOT has a" \
        "different layout than assumed. Confirm against the install step in" \
        "$(lock gds_action_repository) at $(lock gds_action_revision)."

    # Paths the gate-level target in tinytapeout/test/Makefile already consumes,
    # plus the collateral synthesis and place-and-route require.
    #
    # libs.ref is what synthesis and place-and-route consume. libs.tech holds the
    # rule decks and layer properties that precheck reads by absolute path:
    #   klayout -b -r   $PDK_ROOT/$PDK/libs.tech/klayout/tech/drc/$PDK.drc
    # The magicrc is kept in the list because precheck.py references it
    # generically, although no ihp-sg13cmos5l check currently runs magic.
    # A PDK missing either half is incomplete for this project.
    local missing=() rel
    for rel in \
        "libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v" \
        "libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v" \
        "libs.ref/sg13cmos5l_stdcell/lib" \
        "libs.ref/sg13cmos5l_stdcell/lef" \
        "libs.ref/sg13cmos5l_stdcell/gds" \
        "libs.tech/klayout/tech" \
        "libs.tech/klayout/tech/drc/${pdk_name}.drc" \
        "libs.tech/magic/${pdk_name}.magicrc"
    do
        [[ -e "$root/$rel" ]] || missing+=("$rel")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "$EX_PDK" "the PDK is incomplete for this flow" \
            "PDK_ROOT: $pdk_dir" \
            "missing under $pdk_name/:" \
            "${missing[@]/#/  }" \
            "A raw repository checkout is not always a built PDK. If the pinned" \
            "CMOS5L action installs it differently, record that mechanism here and" \
            "in toolchain.lock rather than assuming this layout."
    fi

    # tt-support-tools reads this at harden time:
    #   Tech.read_pdk_version -> parse_openpdks_pdk_version(<root>/SOURCES, "IHP-Open-PDK")
    # A missing or differently-shaped SOURCES file crashes harden() after the
    # LibreLane run, so it is checked here instead. ensure_pdk writes it; the
    # full record is compared so it cannot silently describe another revision.
    local sources="$root/SOURCES" want_record
    want_record="IHP-Open-PDK $(lock pdk_revision)"
    [[ -f $sources ]] || die "$EX_PDK" \
        "PDK identity record not found: $sources" \
        "tt-support-tools reads it during harden via Tech.read_pdk_version." \
        "Rerun without --check so it can be written from the verified revision."

    [[ $(<"$sources") == "$want_record" ]] || die "$EX_PDK" \
        "unexpected PDK identity in $sources" \
        "found:    $(<"$sources")" \
        "expected: $want_record"

    info "views present; identity $(cat "$sources")"
}

# ---------------------------------------------------------------------------
# 8. Staging and flow configuration
# ---------------------------------------------------------------------------
stage_project() {
    step "Staging the Tiny Tapeout project"
    mutating || { info "would run stage-project.sh"; return; }

    # Held for the rest of the script, which also writes the user configuration
    # into the staged project. stage-project.sh inherits it.
    # shellcheck source=stage-lock.sh
    source "$script_dir/stage-lock.sh"
    acquire_stage_lock "$repo_root" || exit "$EX_GENERAL"

    # Pass the resolved checkout explicitly so this script and stage-project.sh
    # can never disagree about which support tools were validated.
    TT_SUPPORT_TOOLS_DIR="$support_tools_dir" "$script_dir/stage-project.sh" \
        || die "$EX_TOOL" "stage-project.sh failed"
}

create_user_config() {
    step "Generating the LibreLane user configuration"
    mutating || { info "would run tt_tool.py --create-user-config --ihp"; return; }

    [[ -d $stage_dir ]] || die "$EX_TOOL" "staged project not found: $stage_dir"

    # create_merged_config() reads "src/config" as a path relative to the
    # process working directory, so tt_tool.py must run from the project dir.
    #
    # tt_tool.py shells out by bare name (`yowasp-yosys`, `python -m librelane`),
    # so invoking the venv's interpreter is not enough: its bin/ must lead PATH.
    ( cd "$stage_dir" \
      && PATH="$venv_dir/bin:$PATH" PDK_ROOT="$pdk_dir" \
         "$venv_dir/bin/python" "$support_tools_dir/tt_tool.py" \
           --project-dir "$stage_dir" --create-user-config --ihp ) \
        || die "$EX_TOOL" "tt_tool.py --create-user-config failed"
}

inspect_user_config() {
    step "Inspecting the generated configuration"
    if ! mutating; then
        info "would verify DESIGN_NAME, VERILOG_FILES, DIE_AREA, FP_DEF_TEMPLATE, clock"
        return
    fi

    local merged="$stage_dir/src/config_merged.json"
    [[ -f $merged ]] || die "$EX_TOOL" "merged configuration not written: $merged"

    DIE_AREA_WANT=$(lock floorplan_die_area | tr ',' ' ') \
    TILES_WANT=$(lock tiles) \
    PDK_WANT=$(lock pdk) \
    "$venv_dir/bin/python" - "$merged" "$stage_dir/info.yaml" <<'PY' \
        || die "$EX_MISMATCH" "the generated configuration does not match the lockfile"
import json, os, sys

merged_path, info_path = sys.argv[1], sys.argv[2]
with open(merged_path) as fh:
    cfg = json.load(fh)

problems = []

def need(key):
    if key not in cfg:
        problems.append(f"missing key {key}")
        return None
    return cfg[key]

# Top module must match info.yaml rather than a hardcoded name.
top = None
for line in open(info_path):
    stripped = line.strip()
    if stripped.startswith("top_module:"):
        top = stripped.split(":", 1)[1].strip().strip('"\'')
        break
if top is None:
    problems.append("info.yaml has no top_module")
elif need("DESIGN_NAME") not in (None, top):
    problems.append(f"DESIGN_NAME is {cfg['DESIGN_NAME']}, info.yaml says {top}")

sources = need("VERILOG_FILES")
if sources is not None:
    if not sources:
        problems.append("VERILOG_FILES is empty")
    if any("*" in s for s in sources):
        problems.append("VERILOG_FILES contains a wildcard; sources must be explicit")

die_area = need("DIE_AREA")
want_area = os.environ["DIE_AREA_WANT"]
if die_area is not None and " ".join(str(die_area).split()) != want_area:
    problems.append(f"DIE_AREA is {die_area!r}, lockfile wants {want_area!r}")

tiles = os.environ["TILES_WANT"]
def_template = need("FP_DEF_TEMPLATE")
if def_template is not None and f"tt_block_{tiles}_" not in str(def_template):
    problems.append(f"FP_DEF_TEMPLATE {def_template!r} is not the {tiles} floorplan")

for key in ("CLOCK_PORT", "CLOCK_PERIOD", "RT_MAX_LAYER", "VDD_PIN", "GND_PIN"):
    need(key)

if problems:
    for p in problems:
        print(f"    {p}", file=sys.stderr)
    sys.exit(1)

print(f"    DESIGN_NAME     {cfg['DESIGN_NAME']}")
print(f"    VERILOG_FILES   {len(sources)} explicit source(s)")
print(f"    DIE_AREA        {die_area}")
print(f"    FP_DEF_TEMPLATE {def_template}")
print(f"    clock           {cfg['CLOCK_PORT']} @ {cfg['CLOCK_PERIOD']} ns")
print(f"    RT_MAX_LAYER    {cfg['RT_MAX_LAYER']}")
PY
}

# ---------------------------------------------------------------------------
# 9. Environment handoff. A script cannot export into its caller's shell, so it
#    writes an ignored activation file instead. Shell startup files are never
#    modified.
# ---------------------------------------------------------------------------
write_env_file() {
    step "Writing the activation file"
    mutating || { info "would write $env_file"; return; }

    assert_writable_path "$env_file"
    mkdir -p "$(dirname "$env_file")"
    cat >"$env_file" <<EOF
# Generated by tinytapeout/scripts/bootstrap-toolchain.sh. Do not edit.
# Ignored build output: regenerate it rather than keeping local changes.
export PDK=$(lock pdk)
export PDK_ROOT=$pdk_dir
export TT_SUPPORT_TOOLS_DIR=$support_tools_dir

# Scripts source this file directly. For an interactive shell, source the
# repository's env.sh instead: it loads this file, the opam switch, and .venv.
# Precheck's separate $precheck_venv_dir is never activated.
EOF
    info "$env_file"
}

summary() {
    cat <<EOF

================================================================================
$(mutating && echo "Environment ready." || echo "Environment valid (--check: nothing was changed).")

  process           $(lock pdk)
  tiles             $(lock tiles)
  librelane         $(lock librelane_version)
  support tools     $support_tools_dir
                    $(lock support_tools_revision)
  PDK_ROOT          $pdk_dir
                    $(lock pdk_revision)
  python env        $venv_dir
  precheck env      $precheck_venv_dir
  precheck tools    ${precheck_tools:-not checked}
  staged project    $stage_dir

Activate (each new shell):
  source $repo_root/env.sh

Next commands:
  dune exec protemu -- check      RTL regression: generation, tests, lint,
                                  generic synthesis, staging
  dune exec protemu -- harden     mapped synthesis and place-and-route
  dune exec protemu -- precheck   required Tiny Tapeout checks (needs Nix)
  (not yet written)
  tinytapeout/scripts/test-gates.sh      gate-level wrapper simulation
  tinytapeout/scripts/report-run.sh      artifact hashes and experiment summary

This prepared an environment. It did not run hardening, timing analysis,
physical verification, precheck, or gate-level simulation, and says nothing
about whether the design closes.
================================================================================
EOF
}

# ---------------------------------------------------------------------------
main() {
    if [[ $check_only -eq 1 ]]; then
        step "Running in --check mode: nothing will be modified"
    elif [[ $offline -eq 1 ]]; then
        step "Running in --offline mode: nothing will be fetched or installed"
    fi

    parse_lockfile
    validate_lockfile
    step "Lockfile validated: $lock_file"
    info "process $(lock pdk), tiles $(lock tiles), librelane $(lock librelane_version)"

    check_prerequisites
    ensure_venv
    resolve_support_tools
    verify_floorplan
    install_python_packages
    install_precheck_environment
    ensure_pdk
    verify_pdk
    stage_project
    create_user_config
    inspect_user_config
    write_env_file
    summary
}

main
