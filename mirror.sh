#!/usr/bin/env bash
# Copies keeperfx.exe.debug from dkfans/keeperfx alpha and release builds into
# monthly releases of this repo, before GitHub's 90-day artifact expiry deletes them.
set -euo pipefail

SOURCE_REPO=dkfans/keeperfx
WORKFLOWS=(build-alpha-patch-signed.yml build-release-patch-signed.yml)
MAX_BUILDS=${MAX_BUILDS:-100}
INDEX=index.tsv

[ -s "$INDEX" ] || printf 'run_id\tcreated\tartifact\trelease\tasset\n' > "$INDEX"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

since=$(date -u -d '91 days ago' +%F)
for wf in "${WORKFLOWS[@]}"; do
    gh api --paginate "repos/$SOURCE_REPO/actions/workflows/$wf/runs?status=success&created=>=$since&per_page=100" \
        --jq '.workflow_runs[] | [.id, .created_at] | @tsv'
done | sort -t$'\t' -k2 > "$work/runs.tsv"   # oldest first: closest to expiry

mirrored=0
while IFS=$'\t' read -r run_id created; do
    [ "$mirrored" -lt "$MAX_BUILDS" ] || break
    cut -f1 "$INDEX" | grep -qx "$run_id" && continue

    artifact=$(gh api "repos/$SOURCE_REPO/actions/runs/$run_id/artifacts" \
        --jq '[.artifacts[] | select((.name | endswith("-symbols")) and (.expired | not)) | .name][0] // ""')
    if [ -z "$artifact" ]; then
        printf '%s\t%s\t-\t-\t-\n' "$run_id" "$created" >> "$INDEX"
        continue
    fi

    month=${created:0:7}
    tag="symbols-$month"
    base=${artifact%-symbols}
    asset="${base%-patch}.exe.debug.xz"

    gh run download "$run_id" -R "$SOURCE_REPO" -n "$artifact" -D "$work/$run_id"
    debug_file=$(find "$work/$run_id" -name keeperfx.exe.debug | head -n 1)
    if [ -z "$debug_file" ]; then
        echo "::warning::$artifact has no keeperfx.exe.debug"
        printf '%s\t%s\t%s\t-\t-\n' "$run_id" "$created" "$artifact" >> "$INDEX"
        rm -rf "${work:?}/$run_id"
        continue
    fi
    xz -9 -T0 -c "$debug_file" > "$work/$asset"

    if ! gh release view "$tag" > /dev/null 2>&1; then
        gh release create "$tag" --title "Symbols $month" \
            --notes "keeperfx.exe.debug for KeeperFX builds made in $month. See the README for how to use them."
    fi
    gh release upload "$tag" "$work/$asset" --clobber

    printf '%s\t%s\t%s\t%s\t%s\n' "$run_id" "$created" "$artifact" "$tag" "$asset" >> "$INDEX"
    rm -rf "${work:?}/$run_id" "$work/$asset"
    mirrored=$((mirrored + 1))
    echo "Mirrored $artifact -> $tag/$asset"
done < "$work/runs.tsv"

echo "Mirrored $mirrored build(s)"
