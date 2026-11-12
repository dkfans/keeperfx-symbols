#!/usr/bin/env bash
# Builds a small symbol table (<build>.sym.gz) for every mirrored build that lacks one,
# and publishes them on the 'tables' branch. Browsers can fetch files from
# raw.githubusercontent.com (it allows cross-origin requests); release downloads can't be.
# The branch is rewritten as a single commit each time, so its history never grows.
set -euo pipefail

INDEX=index.tsv
MAX_TABLES=${MAX_TABLES:-50}
KEEP_DAYS=${KEEP_DAYS:-400}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

out="$work/tables"
remote="https://x-access-token:${GH_TOKEN}@github.com/${GH_REPO}.git"
if git ls-remote --exit-code "$remote" refs/heads/tables > /dev/null 2>&1; then
    git clone -q --depth 1 --branch tables "$remote" "$out"
else
    git init -q "$out"
    git -C "$out" remote add origin "$remote"
fi

made=0
removed=0
cutoff=$(date -u -d "$KEEP_DAYS days ago" +%F)
declare -A keep
while IFS=$'\t' read -r run_id created artifact tag asset; do
    [ "$asset" != "-" ] && [ "$run_id" != "run_id" ] || continue
    [[ "$created" > "$cutoff" ]] || continue
    build=${asset%.exe.debug.xz}
    keep["$build.sym.gz"]=1
    [ -f "$out/$build.sym.gz" ] && continue
    [ "$made" -lt "$MAX_TABLES" ] || continue

    gh release download "$tag" -p "$asset" -D "$work" --clobber
    xz -d -c "$work/$asset" > "$work/keeperfx.exe.debug"
    commit=$(gh api "repos/dkfans/keeperfx/actions/runs/$run_id" --jq .head_sha)
    python3 "$here/make_table.py" "$work/keeperfx.exe.debug" "$build" "$commit" "$out/$build.sym.gz"
    rm -f "$work/$asset" "$work/keeperfx.exe.debug"
    made=$((made + 1))
done < "$INDEX"

# Drop tables for builds that left the index window
for f in "$out"/*.sym.gz; do
    [ -e "$f" ] || continue
    [ -n "${keep[$(basename "$f")]:-}" ] && continue
    rm -f "$f"
    echo "Removed $(basename "$f")"
    removed=$((removed + 1))
done

echo "Made $made table(s), removed $removed"
if [ "$made" -gt 0 ] || [ "$removed" -gt 0 ]; then
    cd "$out"
    git checkout -q --orphan next
    git add -A
    git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit -q -m "Symbol tables"
    git push -q -f origin next:tables
    echo "Published tables branch"
fi
