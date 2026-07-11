#!/bin/bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICLOUD="/Users/hasutosasaki/Library/Mobile Documents/iCloud~md~obsidian/Documents/articles"

EXCLUDES=(--exclude=".obsidian/" --exclude=".DS_Store")

# repoルートと同じレイアウトで同期する対象ディレクトリ
TARGETS=(
  "articles"
  "devio/articles"
  "devio/assets"
  "drafts"
  "books"
)

for target in "${TARGETS[@]}"; do
  mkdir -p "$REPO/$target" "$ICLOUD/$target"
  echo "iCloud -> repo: $target"
  rsync -au "${EXCLUDES[@]}" "$ICLOUD/$target/" "$REPO/$target/"
  echo "repo -> iCloud: $target"
  rsync -au "${EXCLUDES[@]}" "$REPO/$target/" "$ICLOUD/$target/"
done

echo "sync完了。git statusで差分を確認してcommitしてください。"
