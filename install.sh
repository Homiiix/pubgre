#!/usr/bin/env bash
#
# One-line installer for pubgre:
#
#   curl -fsSL https://raw.githubusercontent.com/Homiiix/pubgre/main/install.sh | sudo bash
#
# Downloads pubgre from GitHub into a temporary directory, checks it, and runs
# "pubgre install". Set PUBGRE_REF to install a specific tag or commit instead of main:
#
#   curl -fsSL https://raw.githubusercontent.com/Homiiix/pubgre/main/install.sh | sudo PUBGRE_REF=<commit> bash
#
# Everything is inside main() so a truncated download cannot run a partial script.

main() {
    set -euo pipefail
    local repo=Homiiix/pubgre ref=${PUBGRE_REF:-main} tmp url

    fail() { printf 'pubgre installer: %s\n' "$*" >&2; exit 1; }

    ((EUID == 0)) || fail "must run as root: curl -fsSL <url> | sudo bash"
    [[ $ref =~ ^[A-Za-z0-9._/-]{1,100}$ && $ref != *..* ]] || fail "invalid PUBGRE_REF '$ref'"
    command -v curl >/dev/null || fail "curl is required (apt install curl)"

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    url="https://raw.githubusercontent.com/$repo/$ref/pubgre"

    printf 'Downloading %s\n' "$url"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 -o "$tmp/pubgre" "$url" ||
        fail "download failed"
    [[ $(head -n1 "$tmp/pubgre") == '#!/usr/bin/env bash' ]] ||
        fail "downloaded file is not the pubgre script"
    bash -n "$tmp/pubgre" || fail "downloaded script has syntax errors; not installing"
    printf 'sha256 %s\n' "$(sha256sum "$tmp/pubgre" | cut -d' ' -f1)"

    bash "$tmp/pubgre" install
}

main "$@"
