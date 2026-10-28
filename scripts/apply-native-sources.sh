#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="${1:?Specify pinned native core source directory}"
patch_file="$root/native-patches/database-source.patch"
# The database patch is incremental on the stability-patched source. Its
# guarded reverse check also makes repeated platform builds idempotent.
if ! patch -d "$source_dir" -p1 --reverse --force --batch --dry-run < "$patch_file" >/dev/null 2>&1; then
  bash "$root/scripts/apply-native-stability.sh" "$source_dir"
fi
python3 "$root/scripts/apply-database-source.py" "$source_dir"
