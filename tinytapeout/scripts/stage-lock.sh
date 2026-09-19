# Sourced, not executed.
#
# Exclusive lock on tinytapeout/build/p0-staged. stage-project.sh deletes and
# recreates that directory, and hardening and precheck run inside it for tens of
# minutes; re-staging during a run silently destroys the run in flight. Every
# script that writes to the staged project takes this lock first and refuses to
# start while another one holds it.
#
# The lock is flock(1) on descriptor 9, held until the process exits, so a
# crashed or killed run never leaves a stale lock. Child processes inherit
# descriptor 9 and with it the lock: harden-cmos5l.sh calling stage-project.sh
# is one holder, not a conflict. The lock file lives in build/, beside the staged
# directory rather than inside it, so it survives re-staging.
#
# Usage:
#   source "$script_dir/stage-lock.sh"
#   acquire_stage_lock "$repo_root" || <exit>

acquire_stage_lock() {
    # Prefixed names: callers declare repo_root readonly, and a local of the
    # same name would fail.
    local _sl_path="$1/tinytapeout/build/.stage.lock"
    local _sl_inherited=0

    mkdir -p "$(dirname "$_sl_path")"
    if [[ -e /proc/self/fd/9 && /proc/self/fd/9 -ef $_sl_path ]]; then
        _sl_inherited=1
    else
        exec 9>>"$_sl_path"
    fi

    if ! flock -n 9; then
        printf '\nerror: the staged project is in use by another run\n' >&2
        printf '       %s\n' "$(cat "$_sl_path" 2>/dev/null || echo 'holder unknown')" >&2
        printf '       Re-staging now would delete that run. Wait for it to finish.\n' >&2
        printf '       lock: %s\n' "$_sl_path" >&2
        exec 9>&-
        return 1
    fi

    # Only the process that took the lock describes itself; an inheriting child
    # leaves its parent's record in place.
    if [[ $_sl_inherited -eq 0 ]]; then
        printf 'held by pid %s (%s) since %s\n' \
            "$$" "$(basename "$0")" "$(date '+%Y-%m-%d %H:%M:%S')" >"$_sl_path"
    fi
}
