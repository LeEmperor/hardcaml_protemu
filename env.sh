# Per-shell activation. Source it; do not run it:
#
#   source ./env.sh
#
# Installs nothing and is safe to source repeatedly. It sets up what a new shell
# lacks after a reboot or in a new terminal: the opam switch, the flow variables
# written by the bootstrap, and the project Python environment on PATH.
#
# None of this is needed by the repository's scripts, which locate their own
# tools; it is for running dune, python, librelane, etc. by hand. Precheck's
# separate .venv-precheck is never activated: precheck.sh calls it directly.

_protemu_root=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

# 1. OCaml
if command -v opam >/dev/null 2>&1; then
    eval "$(opam env --switch="${OPAM_SWITCH:-5.2.0+ox}" --set-switch)"
else
    echo "env.sh: opam not found; run ./bootstrap.sh" >&2
fi

# 2. Flow variables (PDK, PDK_ROOT, TT_SUPPORT_TOOLS_DIR)
if [ -f "$_protemu_root/tinytapeout/build/toolchain-env.sh" ]; then
    . "$_protemu_root/tinytapeout/build/toolchain-env.sh"
else
    echo "env.sh: flow environment not bootstrapped; run ./bootstrap.sh" >&2
fi

# 3. Python environment. The same effect as .venv/bin/activate without changing
#    the prompt. Any previously active environment (another worktree's, or this
#    one from an earlier source) is removed from PATH first, so re-sourcing
#    switches rather than stacks, and .venv always leads the opam bin.
if [ -x "$_protemu_root/.venv/bin/python" ]; then
    for _protemu_old in "${VIRTUAL_ENV:-}" "$_protemu_root/.venv"; do
        [ -n "$_protemu_old" ] || continue
        PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_protemu_old/bin" | paste -sd: -)
    done
    export VIRTUAL_ENV="$_protemu_root/.venv"
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    unset PYTHONHOME _protemu_old
fi

unset _protemu_root
