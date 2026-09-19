# Sourced, not executed.
#
# `nix-shell --run` needs an interactive bash for the shell it spawns, and gets it
# by evaluating (import <nixpkgs> {}).bashInteractive. Resolving <nixpkgs> needs a
# channel or NIX_PATH, and a machine with neither -- an apt nix-bin install, for
# instance -- prints an evaluation error and falls back to the environment's bash.
# The tools themselves are unaffected: precheck/default.nix pins nixpkgs by
# revision with fetchTarball and never consults the search path. So the error is
# noise, but it is the kind of noise that stops a bootstrap being read.
#
# Pointing <nixpkgs> at the same revision default.nix already pins silences it and
# makes the wrapper shell come from the pin too, which is the more reproducible
# answer anyway. Nix serves that tarball from its own cache, so nothing is fetched
# twice; only bashInteractive itself is new, about 1 MiB, once per machine.
#
# Usage:
#   source "$script_dir/nix-pin.sh"
#   NIX_PATH=$(nixpkgs_pin "$nix_file") nix-shell "$nix_file" --run ...

# Prints a NIX_PATH value for the revision that nix_file pins, or nothing when the
# pin cannot be read: an empty search path would be worse than the error above, so
# callers fall back to the environment's NIX_PATH rather than to nothing.
nixpkgs_pin() {
    local url
    url=$(sed -n 's|.*fetchTarball[[:space:]]*"\([^"]*\)".*|\1|p' "$1" | head -1)
    [[ -n $url ]] || return 0
    printf 'nixpkgs=%s' "$url"
}
