#!/usr/bin/env bash
# Package the complete updater from this exact Build checkout. The release CI
# includes this tar at deps/stack/parser-update-tools.tar.gz in the same build
# that contains the Parser payload's component-manifest.json.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=${1:?usage: package-parser-update-tools.sh OUTPUT_DIRECTORY}
mkdir -p "$out"
out=$(cd "$out" && pwd)
name=parser-update-tools.tar.gz
[[ ! -e "$out/$name" && ! -e "$out/$name.sha256" ]] || { echo 'refusing to overwrite published tools' >&2; exit 1; }
stage=$(mktemp -d "$out/.parser-tools.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
files=(install-parser.sh lib/stack-fetch.sh lib/parser-gpu-branch.sh lib/parser_components.py lib/parser-component-helper.sh)
for file in "${files[@]}"; do
    [[ -f "$here/$file" && ! -L "$here/$file" ]] || { echo "missing updater file: $file" >&2; exit 1; }
done
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -czf "$stage/$name" -C "$here" "${files[@]}"
(cd "$stage"; sha256sum "$name" > "$name.sha256")
# No-clobber hard-link publication; a second writer cannot replace a name.
ln "$stage/$name" "$out/$name"
ln "$stage/$name.sha256" "$out/$name.sha256"
printf 'Include %s as deps/stack/%s in the same CI build as the Parser payload.\n' "$out/$name" "$name"
