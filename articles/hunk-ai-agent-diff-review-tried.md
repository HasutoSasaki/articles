---
title: "AIエージェントの diff をターミナルでレビューする hunk を使ってみた"
emoji: "👀"
type: "tech"
topics: ["AI", "CLI", "hunk", "terminal", "codereview"]
published: false
---

こんにちは 人材育成室 育成メンバーチームで 研修中の はすと です。

「ムーザルのプログラミング絶望ラジオ」#51 を聴いていたら、AIエージェント時代の diff レビューツールとして hunk が紹介されていました。「エージェントが書いたコードの量が増えて、素の `git diff` だとレビューが追いつかなくなってきた」という課題感には自分も心当たりがあり、気になって触ってみることにしました。

本記事では、hunk をこの articles リポジトリの実際の差分に対して動かし、`diff` / `show` / `--watch` といった基本コマンドから、hunk 独自の `session` サブコマンド群（エージェント自身が外部からレビュー画面を操作する機能）まで一通り試した結果をまとめます。

## hunk とは

[hunk](https://github.com/modem-dev/hunk) は、Claude Code や Cursor のような AI コーディングエージェントが生成した diff を人間がレビューするための、ターミナルで動作する TUI 型 diff ビューアです。公式サイトのタグラインは "Review-first terminal diff viewer for agentic coders"。

開発元は Modem という会社で、作者の Ben Vinegar さんは Web 開発ポッドキャスト Syntax の元運営メンバー（GM）です。実際 [Syntax #1011](https://syntax.fm/show/1011/tmux-terminal-maxxing-with-ben-vinegar) に本人がゲスト出演し、hunk をデモする回があります。

2026年7月10日時点で GitHub Star は 6.5k、直近も 1〜3 週間おきにリリースが続いていて活発に開発中です。Ghostty 作者の Mitchell Hashimoto さんや Rails 作者の DHH さんが公式サイトで推薦コメントを寄せているのも、伸びている理由の一つに見えます。

- Git / Jujutsu / Sapling に対応
- サイドバー付きのマルチファイルレビュー
- ファイル変更を検知する watch モード
- `git difftool` / `git config core.pager` との連携
- ライセンスは MIT、npm パッケージ名は `hunkdiff`（バイナリ名は `hunk`）

## インストール

Homebrew でインストールしました。

```bash
brew install hunk
```

```bash
hunk --version
# 0.17.0
```

## 実際に手元の差分をレビューしてみる

このリポジトリには、Zenn 記事2本の修正と DevIO 記事1本の新規追加という、ちょうどよい未コミット差分がありました。これを `hunk diff` でレビューしてみます。

```bash
hunk diff
```

起動すると、左にファイルツリー、右に選択中ファイルの diff という2ペイン構成の画面になります。

```
 File  View  Navigate  Agent  Help                            articles working tree  +312  -17
 ──────────────────────────┬─────────────────────────────────────────────────────────────
  M .gitignore           +1 │ .gitignore                                            +1 -0
 articles/                  │ @@ -3,3 +3,4 @@
  M chromadb-...   +18 -11  │ 3   devio/.claude/                    3   devio/.claude/
  M mac-hermes-... +2 -6    │ 4   .article-cache.json               4   .article-cache.json
 devio/articles/            │ 5   node_modules/                     5   node_modules/
  ? claude-code-... +291    │                                     ▌6 + .claude/settings.local.json
```

左のファイルツリーにファイルごとの `+/-` 行数が出ていて、右側は変更前後を左右に並べた split 表示です。素の `git diff` と違い、ファイル間の移動やスクロールが GUI アプリのような操作感で行えます。

## 直近のコミットをレビューする hunk show

作業ツリーだけでなく、コミット単位のレビューもできます。

```bash
hunk show HEAD
```

`hunk diff` と同じ画面構成で、指定したコミット（省略時は直近コミット）の変更内容が表示されます。`hunk show HEAD~1` のように過去のコミットを指定することも可能です。

## ファイルの変更をリアルタイムに追う --watch

`--watch` を付けると、ファイルの変更を検知して自動的に diff を再読み込みしてくれます。

```bash
hunk diff --watch -- .gitignore
```

起動した状態で `.gitignore` に1行追記してみると、保存した瞬間に画面の `+1 -0` が `+2 -0` に変わり、追記した行がそのまま diff に反映されました。ポーリングではなくファイル変更をトリガーに即座に更新される感覚で、エージェントが裏で編集を続けている最中に人間が横で眺める、という使い方に向いていそうです。

## エージェントが外部からレビュー画面を操作する session コマンド

hunk で一番特徴的だと感じたのが `hunk session` サブコマンド群です。起動中の hunk はローカルのデーモンとして自分自身を公開していて、別のターミナルから session ID を指定して操作できます。

まず起動中のセッションを確認します。

```bash
hunk session list
```

実行結果です。

```
a31508e0-725c-4cf2-bc5e-058110aeae86  articles working tree
  path: /Users/hasutosasaki/ghq/github.com/HasutoSasaki/articles
  repo: /Users/hasutosasaki/ghq/github.com/HasutoSasaki/articles
  terminal: tmux
  focus: .gitignore hunk 1
  files: 4
  comments: 0
```

レビュー状態は JSON でも取得できます。エージェントがレビュー結果をプログラム的に読み取る用途を想定しているようです。

```bash
hunk session review --repo . --json
```

ここから、外部プロセスが特定の hunk へジャンプさせたり、レビューコメントを残したりできます。

```bash
hunk session navigate <session-id> --file articles/mac-hermes-agent-setup-guide.md --hunk 1
```

コマンドラインの `--hunk` はよくある0始まりのインデックスだろうと考えると思います。実際には1始まりで、`--hunk 0` を渡すと `Invalid positive integer: 0` と怒られます。

コメント追加も試しました。

```bash
hunk session comment add <session-id> \
  --file articles/mac-hermes-agent-setup-guide.md \
  --new-line 142 \
  --summary "この一文、根拠となる検証ログへのリンクを足すと説得力が増しそう"
```

行番号さえ合っていればファイルのどこにでもコメントを打てるだろうと考えると思います。実際には diff の hunk がカバーしている行番号でないとエラーになります。変更されていない行（今回は11行目）を指定したところ `No new diff hunk in ... covers line 11` と拒否され、実際に追加・変更された行（142行目）を指定して初めてコメントが通りました。裏を返すと、コメントは必ず「変更箇所そのもの」に紐づく設計になっているということです。

追加したコメントは一覧でも確認できます。

```bash
hunk session comment list <session-id>
```

```
mcp:63fe82b1-9771-4f1a-8874-4bbcefb6a1b6  articles/mac-hermes-agent-setup-guide.md:142 (new)
  hunk: 2
  summary: この一文、根拠となる検証ログへのリンクを足すと説得力が増しそう
```

hunk 本体の画面（`hunk diff` を開いたままの側）に戻ると、サイドバーのファイル名の横に `*1` というコメント数バッジが増えていました。別プロセスから追加した内容が、開いている TUI にそのまま反映される作りです。

## 気づき

- サイドバー付き split 表示は、複数ファイルにまたがる変更を一望する場面で素の `git diff` より見やすい
- `--watch` は本当にリアルタイムで、ポーリング待ちのストレスがない
- `session` コマンド群が hunk の核心だと感じました。人間がレビューするための TUI であると同時に、エージェント自身が「自分の変更のどこに注釈を残すか」を外部から操作できる設計になっています。エージェントに `hunk session comment add` を叩かせて自己レビューのメモを残させる、という運用も現実的にできそうです
- ただし `--hunk` のインデックスや `--new-line` の対象範囲など、コマンド仕様に細かい制約があるので、自動化する場合は一度 `--help` と実際のエラーメッセージで挙動を確認しておいたほうがよさそうです

## まとめ

hunk を実際に動かしてみて、ただの diff ビューアではなく「エージェントと人間が同じレビュー画面を共有する」ためのツールだと実感できました。今回は手動でコマンドを打って `session` API を触りましたが、次はこれを Claude Code のフックか何かに組み込んで、エージェントに自分の変更へコメントを残させるところまで試してみたいと思います。

私と同じように、エージェントが書いた diff のレビューに手間を感じている方の参考になれば嬉しいです。

## 参考

- [modem-dev/hunk - GitHub](https://github.com/modem-dev/hunk)
- [Hunk - Review-first terminal diff viewer](https://www.hunk.dev/)
- [agent-workflows.md - modem-dev/hunk](https://github.com/modem-dev/hunk/blob/main/docs/agent-workflows.md)
- [Syntax #1011: tmux + Terminal Maxxing with Ben Vinegar](https://syntax.fm/show/1011/tmux-terminal-maxxing-with-ben-vinegar)
- [ムーザルのプログラミング絶望ラジオ #51](https://www.youtube.com/watch?v=WaE7IAEBr7M)
