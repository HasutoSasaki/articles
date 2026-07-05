# articles

技術記事の執筆・管理リポジトリ。

## 構成

- `articles/` - Zenn記事（GitHub連携による自動公開対象。frontmatterで公開/下書きを制御）
- `devio/` - DevelopersIO向け記事のワークスペース
- `drafts/` - 下書き・執筆中のメモ

## Zenn記事の執筆

```bash
pnpm install

# ローカルプレビュー
pnpm dlx zenn preview

# 新規記事作成
pnpm dlx zenn new:article
```

`articles/*.md` の frontmatter で `published: false` にすると下書き状態のままpushできる。
