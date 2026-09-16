#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
stage_dir="$repo_root/tinytapeout/build/p0-staged"
default_support_tools_dir="$repo_root/../tt-support-tools-cmos5l"
support_tools_dir=${TT_SUPPORT_TOOLS_DIR:-$default_support_tools_dir}
lock_file="$repo_root/tinytapeout/toolchain.lock"

lock_value() {
    key=$1
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found = 1 }
        END { if (!found) exit 1 }' "$lock_file"
}

expected_support_tools_revision=$(lock_value support_tools_revision)
expected_def_sha256=$(lock_value floorplan_def_sha256)
expected_tiles=$(lock_value tiles)
if test "$expected_tiles" != "6x4"; then
    echo "Unexpected target in toolchain.lock: $expected_tiles" >&2
    exit 1
fi

case "$stage_dir" in
    "$repo_root"/tinytapeout/build/*) ;;
    *)
        echo "Refusing unexpected staging path: $stage_dir" >&2
        exit 1
        ;;
esac

"$repo_root/tinytapeout/scripts/generate-rtl.sh"
rm -rf "$stage_dir"
mkdir -p "$stage_dir/src" "$stage_dir/test" "$stage_dir/docs"
cp "$repo_root/tinytapeout/info.yaml" "$stage_dir/info.yaml"
cp "$repo_root/tinytapeout/toolchain.lock" "$stage_dir/toolchain.lock"
cp "$repo_root/tinytapeout/src/config.json" "$stage_dir/src/config.json"
cp "$repo_root/tinytapeout/src/p0_observable.v" "$stage_dir/src/p0_observable.v"
cp "$repo_root/tinytapeout/src/project.v" "$stage_dir/src/project.v"
cp "$repo_root/tinytapeout/test/Makefile" "$stage_dir/test/Makefile"
cp "$repo_root/tinytapeout/test/tb.v" "$stage_dir/test/tb.v"
cp "$repo_root/tinytapeout/docs/info.md" "$stage_dir/docs/info.md"

# tt-support-tools' Project.harden() reads the project's git remote and HEAD
# commit (for runs/wokwi/final/commit_id.json) before LibreLane starts, and
# raises InvalidGitRepositoryError on a plain directory. In CI the project is a
# GitHub checkout; here it is a staged copy, so it gets a one-commit repository
# whose origin is this repository's and whose message names the source commit.
# The staging commit hash is not the source commit: harden-summary.json records
# that.
source_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)
source_dirty=$(test -n "$(git -C "$repo_root" status --porcelain 2>/dev/null)" && echo " (dirty)" || true)
source_remote=$(git -C "$repo_root" remote get-url origin 2>/dev/null || echo "file://$repo_root")
git -C "$stage_dir" init --quiet
git -C "$stage_dir" remote add origin "$source_remote"
git -C "$stage_dir" add -A
git -C "$stage_dir" -c user.name=stage-project -c user.email=stage-project@localhost \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit --quiet -m "staged from $source_commit$source_dirty"

if test -d "$support_tools_dir"; then
    support_tools_dir=$(realpath "$support_tools_dir")
    actual_revision=$(git -C "$support_tools_dir" rev-parse HEAD)
    if test "$actual_revision" != "$expected_support_tools_revision"; then
        echo "Unexpected tt-support-tools revision: $actual_revision" >&2
        echo "Expected: $expected_support_tools_revision" >&2
        exit 1
    fi
    if test -n "$(git -C "$support_tools_dir" status --porcelain)"; then
        echo "tt-support-tools checkout is dirty: $support_tools_dir" >&2
        exit 1
    fi

    tile_sizes="$support_tools_dir/tech/ihp-sg13cmos5l/tile_sizes.yaml"
    floorplan_def="$support_tools_dir/tech/ihp-sg13cmos5l/def/tt_block_6x4_pgvdd.def"
    test -f "$tile_sizes"
    test -f "$floorplan_def"
    grep -Fx '6x4: "0 0 1289.28 710.64"' "$tile_sizes" >/dev/null
    actual_def_sha256=$(sha256sum "$floorplan_def" | awk '{print $1}')
    if test "$actual_def_sha256" != "$expected_def_sha256"; then
        echo "Unexpected CMOS5L 6x4 DEF hash: $actual_def_sha256" >&2
        echo "Expected: $expected_def_sha256" >&2
        exit 1
    fi

    ln -s "$support_tools_dir" "$stage_dir/tt"
    echo "Linked validated CMOS5L support tools at $stage_dir/tt"
else
    echo "Support tools not linked; expected $support_tools_dir" >&2
    echo "Set TT_SUPPORT_TOOLS_DIR to a pinned CMOS5L checkout to include them." >&2
fi

echo "Staged phase-P0 project at $stage_dir"
