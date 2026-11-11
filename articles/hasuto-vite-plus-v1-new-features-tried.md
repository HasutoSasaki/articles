---
title: "Vite+が1.0になったので、アルファ版から増えた機能を試してみた"
emoji: "🧰"
type: "tech"
topics: ["vite", "viteplus", "typescript", "frontend", "toolchain"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

6月に[統合ツールチェーン Vite+ を試してみた](https://dev.classmethod.jp/articles/vite-plus-unified-toolchain-tried/)という記事を書きました。この時はまだアルファ版のv0.2.1でしたが、その後7月にベータ、9月28日に1.0が出て、10月23日には1.4まで進んでいます。個人的に、この4か月で何が増えたのか気になったので、まとめてみることにしました。

本記事では、v0.2.1以降に増えた機能から、普段の開発で使いそうなものを選んで試した結果をまとめます。

## アルファ版から増えた主な機能

[GitHubのリリース一覧](https://github.com/voidzero-dev/vite-plus/releases)を見ると、v0.2.1のあと1.4までに19回のリリースがあります。その中から、今回は次の9つを試します。

| 機能 | 追加されたバージョン | できること |
|---|---|---|
| `vpx` でのファイル実行 | 1.4 | TypeScriptのファイルをtsxなしで実行する |
| `vp hooks` | 0.2.9 | Gitフックの有効化・無効化・状態の確認をする |
| `vp check --deny-warnings` | 1.4 | Lintの警告でもチェックを失敗させる |
| `vp toolchain` | 0.2.9 | 同梱しているツールとバージョンの関係を表示する |
| `create-vite-plus` | 1.3 | グローバルの `vp` を入れずにプロジェクトを作る |
| `vp pm pkg` | 1.3 | `package.json` の値を読み書きする |
| `vp pm patch` | 0.2.8 | 依存しているパッケージにパッチを当てる |
| `vp env use` | 0.3.2 | Node.jsとパッケージマネージャーのバージョンを、今のシェルだけ切り替える |
| `vp env clean` | 0.2.5 | 使っていないNode.jsとパッケージマネージャーを消す |

ほかにも、Vitest 5への移行やタスクキャッシュの改善などが入っています。

:::details v0.2.2から1.4.0までに追加された機能
各リリースのリリースノートから、新しく追加された機能を拾いました。バグ修正と、同梱しているツールの更新は省いています。0.2.2がベータ版です。

| バージョン | 追加された機能 |
|---|---|
| 0.2.2 | `vp migrate` で既存のVite+プロジェクトを新しいバージョンに上げられる（`--full` でフックやエディターの設定も行う） |
| 0.2.2 | 公式のDockerイメージ `ghcr.io/voidzero-dev/vite-plus` |
| 0.2.2 | キャッシュの設定を書かなくても `vp build` の結果がキャッシュされる |
| 0.2.2 | Vite+が管理するNode.jsのダウンロードをPGP署名で検証する |
| 0.2.2 | `vite.config.ts` の `check` で、`vp check` のフォーマットやLintを既定で省ける |
| 0.2.2 | `vp env list-remote` がインストール済みのバージョンを強調して表示する |
| 0.2.2 | `vp run` の短縮形 `vpr` が `vite-plus` パッケージに入り、グローバルの `vp` がなくても使える |
| 0.2.2 | タスクの `dependsOn` で、依存しているパッケージのタスクを指定できる |
| 0.2.2 | タスクの `env` の指定で、`!` を付けて変数を除外できる |
| 0.2.5 | `vp env clean` で、使っていないNode.jsとパッケージマネージャーのキャッシュを消せる |
| 0.2.5 | `vp pm version` |
| 0.2.5 | 型定義の生成がTypeScript 7に対応 |
| 0.2.6 | 型情報を使うLintが、安定版のtsgolint 7に移る |
| 0.2.7 | `vp pack --concurrency` で、並列で動くビルドの数を制限できる |
| 0.2.7 | 組み込みコマンドと同じ名前のスクリプトがあるとき、`vpr <name>` を案内する |
| 0.2.8 | モノレポのルートで `vp dev`、`build`、`preview`、`pack` を実行すると、対象のパッケージを選べる（`-C <dir>` や `defaultPackage` でも指定できる） |
| 0.2.8 | `vp pm ci`、`vp pm patch`、`vp pm patch-commit` |
| 0.2.8 | ほかに指定がないとき、`.nvmrc` からNode.jsのバージョンを読む |
| 0.2.8 | pnpm 12に対応 |
| 0.2.9 | `vp toolchain` |
| 0.2.9 | `vp hooks` |
| 0.2.9 | Codex CLIとClaude Codeの既定のサンドボックスの中でも `vp run` が動く |
| 0.2.9 | エディターの設定でJetBrains系のエディターを選べる |
| 0.2.9 | パッケージマネージャーのダウンロードに進み具合を表示する |
| 0.2.9 | `vp create` が、npm 12でインストールスクリプトがブロックされた依存を表示する |
| 0.3.0 | `vp migrate` がtsupのプロジェクトを `vp pack` に移す |
| 0.3.0 | Bun 1.4以降では、`vp dedupe` などのコマンドを `bun` に渡す |
| 0.3.0 | 新しくインストールすると、XDGに沿ったディレクトリの構成になる |
| 0.3.0 | 更新の確認を別のプロセスで行い、コマンドを待たせない |
| 0.3.1 | `vp env` でNode.jsとパッケージマネージャーのバージョンをまとめて管理する（Corepackの代わり） |
| 0.3.1 | `vp check --quiet` で、Lintの警告を隠してエラーと件数だけを表示する |
| 0.3.1 | `vp sync-versions --json` |
| 0.3.2 | `vp env use` で、パッケージマネージャーごとにバージョンを設定できる |
| 0.3.2 | Oxlintのカスタムルールで、`vite-plus/lint/plugins` からAPIをimportできる |
| 0.3.2 | `vp install` と `vp add` が `--ignore-scripts` に対応 |
| 1.0.0-rc.0 | `vp test` がVitest 5に移る（`vp migrate` が移行を手伝う） |
| 1.0.0-rc.0 | インストーラーと `vp upgrade` が、リリースのバイナリの来歴（SLSA provenance）を検証する |
| 1.0.0-rc.0 | `vp add` が `--offline`、`--frozen-lockfile` などのオプションに対応 |
| 1.0.0-rc.0 | `vp rebuild` がYarn Berryに対応 |
| 1.0.0-rc.1 | タスクのキャッシュの設定を `cache` の下に書く（`vp migrate` が書き換える） |
| 1.0.0-rc.1 | パッケージのディレクトリで実行した `vp lint` と `vp fmt` が、エディターと同じ設定を使う |
| 1.0.0 | 1.0.0-rc.1をそのまま安定版にしたもの（コードの変更なし） |
| 1.1 | `vp dev` がローカルのURLを表示するまでの時間が約24%短くなる |
| 1.1 | `vp run` が `npm_execpath` と `npm_config_user_agent` を設定する |
| 1.2 | 認証が必要なプライベートのnpmレジストリに対応 |
| 1.2 | `vp run` の最後の表示に、キャッシュのヒット率と成功したタスクの数が出る |
| 1.2 | インストーラーがダウンロードしたファイルをハッシュで検証し、`vp upgrade` が進み具合を表示する |
| 1.3 | `create-vite-plus` |
| 1.3 | `vp pm pkg` で `package.json` を読み書きできる |
| 1.3 | `vp pm licenses list` で依存のライセンスを一覧にできる |
| 1.3 | `vp env` で `pnpm@latest-10` のようなdist-tagを指定できる |
| 1.4 | `vpx <file>` と `vpx --watch <file>` |
| 1.4 | `vp migrate` がtsxのスクリプトを `vpx` に置き換える |
| 1.4 | `vp check --deny-warnings` |
| 1.4 | `vp pm team` で、レジストリの組織のチームを管理できる |
| 1.4 | `vp pm` のレジストリ系のコマンド（`login`、`publish` など）が、pnpm 11以降ではpnpmのコマンドを使う |
| 1.4 | インストーラーと `vp upgrade` が、リリースごとのロックファイルでグローバルの `vp` の依存をそろえる |
:::

## 検証環境

2026年10月25日から31日にかけて検証した環境です。

| 項目 | バージョン |
|---|---|
| macOS | 26.7.1 |
| Node.js | 24.22.1 |
| pnpm | 12.15.0 |
| Git | 2.52.0 |
| vite-plus | 1.4.0 |

## 手元の vp を最新に上げる

グローバルの `vp` は `vp upgrade` で上げます。私の手元では、一度 v1.0 に上げていたため、v1.0 からの更新です。

```bash
vp upgrade
```

実行結果です。

```
info: checking for updates...
info: found vite-plus@1.4.0 (current: 1.0.0)
info: downloading vite-plus@1.4.0 for darwin-arm64...
info: installing...
info: Preparing Node.js and pnpm...
info: Installing dependencies...
✓ Dependencies installed.

✓ Updated vite-plus from 1.0.0 → 1.4.0
```

これだけでは、プロジェクトに入っている `vite-plus` は上がらないため、プロジェクト側は `vp migrate` で上げます。

```bash
vp migrate --no-interactive --no-agent --no-editor
```

`--no-interactive` は、質問を出さずに既定の値で進めるオプションで、`--no-agent` と `--no-editor` は、AGENTS.mdなどのコーディングエージェント向けの指示と、エディタの設定ファイルを書き込まないようにしてます。今回は検証用なので、ファイルを増やさないために付けてますが、普段はオプションなしで実行し、質問に答えながら進めるで問題ないです。

実行結果です。

```
◇ Updated . to Vite+ 1.4.0
• Node 24.22.1  pnpm 12.15.0
• Dependencies:
    vite-plus  1.0.0 → 1.4.0
    vite       8.3.1 → 8.3.5
✓ Dependencies installed in 1.4s
• Package manager settings configured
• Skipped editor, hooks, and lint setup. Run `vp migrate --full` to apply them.
```

## vpx でTypeScriptのファイルを直接実行する

今回特に気になっていたのが、`vpx` でTypeScriptのファイルを直接実行する機能です。

> `vpx` runs TypeScript and JavaScript files directly, without a `tsx` or `ts-node` dependency.
>
> （`vpx` は、`tsx` や `ts-node` に依存せずにTypeScriptとJavaScriptのファイルを直接実行します）
>
> [vpx - Vite+](https://viteplus.dev/guide/vpx#running-scripts)

Node.js 24は型を取り除くだけで `.ts` を実行できるため、`node` で足りるのでは？と考える方もいると思います。違いが出るのは、型を取り除くだけでは動かない構文で、`enum` を使ったファイルで比べてみます。

```ts:scripts/hello.ts
enum Level {
  Info = "INFO",
  Warn = "WARN",
}

const greet = (name: string, level: Level = Level.Info): string => `[${level}] Hello, ${name}`;

console.log(greet("Vite+"));
console.log(greet("vpx", Level.Warn));
```

まずNode.jsで実行します。

```bash
node scripts/hello.ts
```

実行結果です。

```
SyntaxError [ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX]: TypeScript enum is not supported in strip-only mode
```

次に `vpx` です。

```bash
vpx scripts/hello.ts
```

実行結果です。

```
[INFO] Hello, Vite+
[WARN] Hello, vpx
```

`enum` を含むファイルも動きました。ドキュメントによると、`enum` のほかに `namespace`、コンストラクタ引数のプロパティ宣言、JSXにも対応しています。ただし、`vpx` は型チェックをしないため、型の誤りは `vp check` で確かめます。

`vpx --watch` を使うと、`tsx watch` と同じようにファイルの変更で再実行されます。`scripts/watch-main.ts` からimportしている `scripts/lib/message.ts` を書き換えて試しました。

```bash
vpx --watch scripts/watch-main.ts
```

実行結果です（`scripts/lib/message.ts` の文字列を `first` から `second` に書き換えたところまで）。

```
17:27:58 [vpx] watching for changes
message: first
17:27:58 [vpx] completed — waiting for changes
17:28:00 [vpx] change in ./scripts/lib/message.ts, rerunning
message: second
17:28:00 [vpx] completed — waiting for changes
```

### tsxのスクリプトを vp migrate で置き換える

すでにtsxを使っている場合は、`vp migrate --full` が `vpx` に書き換えてくれます。`package.json` にtsxを使うスクリプトを3つの書き方で用意し、シバン（1行目の `#!`）でtsxを指定したファイルも置いて試しました。

```bash
vp migrate --full --no-interactive --no-agent --no-editor --no-hooks
```

`--full` は、すでにVite+を使っているプロジェクトでも移行の処理をすべて実行するオプションです。`--no-hooks` はコミット前のフックを設定しないオプションで、他は先ほどと同じです。

実行結果です。

```
● tsx scripts detected. Auto-migrating to vpx...
● Formatting code...
● Code formatted
◇ Updated . to Vite+ 1.4.0
• Node 24.22.1  pnpm 12.15.0
✓ Dependencies installed in 637ms
• tsx scripts migrated to `vpx`
```

`git diff` で変更を確認します。

```diff
-    "hello": "tsx scripts/hello.ts",
-    "hello:watch": "tsx watch scripts/hello.ts",
-    "plain": "node --import tsx scripts/plain.ts"
+    "hello": "vpx scripts/hello.ts",
+    "hello:watch": "vpx --watch scripts/hello.ts",
+    "plain": "vpx scripts/plain.ts"
   },
   "devDependencies": {
-    "tsx": "^4.23.15",
     "typescript": "~6.0.3",
```

```diff
-#!/usr/bin/env tsx
+#!/usr/bin/env vpx
 console.log(`now: ${new Date().toISOString()}`);
```

スクリプトもシバンも `vpx` に置き換わり、使われなくなった `tsx` は開発依存から外れました。なお、すでにVite+を使っているプロジェクトでは、`--full` を付けないと置き換わりません。

## vp hooks でコミット前のチェックを管理する

コミット前にLintやフォーマットをかけるには、huskyとlint-stagedを入れるのが定番ですが、Vite+にはアルファ版のころから、ステージしたファイルだけをチェックする `vp staged` と、Gitフックを設定する `vp config` がありました。さらに、0.2.9では、フックの有効化・無効化と状態の確認をする `vp hooks` が加わりました。

まず `vite.config.ts` の `staged` に、ステージしたファイルに対して実行するコマンドを書きます。

```ts:vite.config.ts
import { defineConfig } from "vite-plus";

export default defineConfig({
  // 追加
  staged: {
    "*": "vp check --fix",
  },
  // （以下は省略）
});
```

次に、コミット前に実行するフックを `.vite-hooks/pre-commit` に書きます。

```sh:.vite-hooks/pre-commit
vp staged
```

`vp hooks enable` で、Gitがこのフックを使うように設定します。

```bash
vp hooks enable
```

```
Git hook dispatcher installed at .vite-hooks/_
```

`vp hooks status` で、設定の状態を確かめます。

```bash
vp hooks status
```

```
Preference:     enabled
Hooks dir:      .vite-hooks
core.hooksPath: .vite-hooks/_ (Vite+ dispatcher)
Dispatcher:     installed (.vite-hooks/_)
Project hooks:  pre-commit
```

Gitの `core.hooksPath` が `.vite-hooks/_` に向き、そこに置かれた仕組みから `.vite-hooks/pre-commit` が呼ばれます。

整形されていないファイルをステージして、動きを確かめます。コミットはせずにフックだけを実行するため、`git hook run` を使いました。

```ts:src/math.ts
export const add=(a:number,b:number)=>{return a+b}
```

```bash
git add src/math.ts
git hook run pre-commit
```

```
✔ vp check --fix
```

`git show :src/math.ts` で、ステージされている内容を表示します。

```bash
git show :src/math.ts
```

```
export const add = (a: number, b: number) => {
  return a + b;
};
```

`vp check --fix` で整形された内容が、そのままステージに反映されました。huskyやlint-stagedを入れなくても、`vite.config.ts` の設定とフックのファイルだけで同じことができます。フックが有効かどうかを `vp hooks status` でいつでも確かめられるのもいい点です。

## vp check --deny-warnings で警告もCIを止める

`vp check` はフォーマット、Lint、型チェックをまとめて実行するコマンドです。Lintの警告だけでは失敗にならないため、警告でもCIを止めたい場合は `vp lint --deny-warnings` を別に実行する必要がありました。1.4から `vp check` にも `--deny-warnings` が付きました。

Oxlintが警告を出す `debugger` 文を入れて試します。

```ts:src/counter.ts
export function debugCounter(count: number) {
  debugger;
  return count;
}
```

まず、オプションなしで実行します。結果は一部省略しています。

```bash
vp check
echo $?
```

```
pass: All 14 files are correctly formatted (205ms, 10 threads)
warn: Lint or type warnings found
! eslint(no-debugger): `debugger` statement is not allowed
...
Found 0 errors and 1 warning in 9 files (1.0s, 10 threads)
0
```

警告は出ますが、終了コードは0です。次に `--deny-warnings` を付けて実行します。

```bash
vp check --deny-warnings
echo $?
```

```
pass: All 14 files are correctly formatted (171ms, 10 threads)
warn: Lint or type warnings found
! eslint(no-debugger): `debugger` statement is not allowed
...
Found 0 errors and 1 warning in 9 files (211ms, 10 threads)
1
```

`--deny-warnings` を付けると、同じ警告で終了コードが1になりました。CIのチェックは `vp check --deny-warnings` の1つで済みます。

## vp toolchain で同梱ツールの関係を見る

0.2.9で入った `vp toolchain` を使うと、Vite+に同梱されているVite、Vitest、Oxlintなどのバージョンを、ツールどうしの関係と一緒に木の形で確認できます。

```bash
vp toolchain
```

実行結果です。

```
Vite+ toolchain (local)

vite-plus@1.4.0
├── depends on @voidzero-dev/vite-plus-core@1.4.0
│   ├── bundles vite@8.3.5
│   │   └── uses rolldown@1.2.15
│   │       ├── compiles oxc@0.155.0
│   │       └── compiles oxc-resolver@11.24.3
│   ├── bundles rolldown@1.2.15
│   │   ├── compiles oxc@0.155.0
│   │   └── compiles oxc-resolver@11.24.3
│   └── bundles tsdown@0.23.1
├── depends on vitest@5.0.5
├── depends on oxlint@1.89.0
├── depends on oxlint-tsgolint@7.0.2004
├── depends on oxfmt@0.74.0
├── compiles vite-task (built 2026-10-23T02:30:38Z, revision a3c087a771a116f7c60220fc72738703eb45ac2e)
└── compiles oxc-node@1.0.0 (4759cedbda87f67ca646d3277166884cfcd62f81)
    ├── compiles oxc@0.155.0
    └── compiles oxc-resolver@11.24.3
```

ViteとRolldownは `vite-plus-core` に同梱され、VitestやOxlintは通常の依存として入っていることが分かります。`vpx` が使うoxc-nodeも含まれていました。バグを報告するときや、Vite単体のリリースノートと見比べるときに使えそうです。

## グローバルの vp なしでプロジェクトを作る

1.3で `create-vite-plus` が追加され、グローバルの `vp` がなくても `pnpm create vite-plus` でプロジェクトを作れるようになりました。私の環境にはグローバルの `vp` が入っているため、`PATH` から `~/.vite-plus` 配下を外して試します。

```bash
PATH=$(echo $PATH | tr ':' '\n' | grep -v '\.vite-plus' | paste -sd: -) bash
command -v vp || echo none
```

```
none
```

`vp` が見つからない状態で、`pnpm create vite-plus` を実行します。

```bash
pnpm create vite-plus vite --no-interactive --no-agent --no-editor --no-git --no-hooks --package-manager pnpm -- create-vite-plus-lab --template vanilla-ts
```

`--no-git` はGitのリポジトリを作らないオプションで、`--package-manager pnpm` はパッケージマネージャーにpnpmを使うよう指定します。

実行結果です（一部省略）。

```
...
◇ Scaffolded create-vite-plus-lab with Vanilla + TypeScript
• Node 24.13.0  pnpm 12.15.0
✓ Dependencies installed in 396ms
→ Next: cd create-vite-plus-lab && pnpm exec vp run
```

`vp` が見つからない状態でも作成でき、末尾の説明では、プロジェクトに入った `vp` を使う `pnpm exec vp run` になっています。チームのメンバー全員にグローバルの `vp` を入れてもらわなくても、`pnpm` さえあれば始められます。

なお、Node.jsが24.13.0になっているのは、`PATH` から外したVite+管理のNode.jsの代わりに、別に入れていたnvmのNode.jsが使われたためです。

## パッケージマネージャーまわりのコマンドを試す

`vp pm` と `vp env` にも、細かいコマンドがいくつも増えています。ここでは `vp create` で作った別のプロジェクトを使い、Node.jsとpnpmのバージョンを検証環境にそろえて試します。

```bash
vp create vite --no-interactive --no-agent --no-editor --no-hooks --package-manager pnpm -- vite-plus-pm-lab --template vanilla-ts
cd vite-plus-pm-lab
vp env pin 24.22.1 pnpm@12.15.0
```

### vp pm pkg で package.json を書き換える

1.3で入った `vp pm pkg` は、`package.json` の値を読み書きするコマンドです。

> `vp pm pkg` reads and updates fields in `package.json` using the detected package manager.
>
> （`vp pm pkg` は、検出したパッケージマネージャーを使って `package.json` のフィールドを読み書きします）
>
> [Package Management - Vite+](https://viteplus.dev/guide/package-management#package-manifest)

```bash
vp pm pkg get name
```

```
vite-plus-pm-lab
```

`set` と `delete` でスクリプトを書き換えて、差分を見ます。

```bash
vp pm pkg set scripts.test="vp test"
vp pm pkg delete scripts.preview
git diff package.json
```

```diff
   "scripts": {
     "dev": "vp dev",
     "build": "tsc && vp build",
-    "preview": "vp preview"
+    "test": "vp test"
   },
```

`get` で値を読み、`set` と `delete` でスクリプトの追加と削除ができました。`package.json` を開かずに書き換えられるため、READMEの手順やCIのスクリプトに書いておくのに向いていそうです。

### vp pm patch で依存にパッチを当てる

0.2.8では、依存しているパッケージを手元で直してパッチとして残す `vp pm patch` と `vp pm patch-commit` が入りました。`picocolors` を追加して試します。

```bash
vp add picocolors
vp pm patch picocolors
```

実行結果です（一部省略）。

```
Patch: You can now edit the package at:

  ~/vite-plus-pm-lab/node_modules/.pnpm_patches/picocolors@1.1.1

To commit your changes, run:

  pnpm patch-commit '~/vite-plus-pm-lab/node_modules/.pnpm_patches/picocolors@1.1.1'
```

案内が `pnpm patch-commit` になっていることから、pnpmの `patch` コマンドに渡していることが分かります。表示されたディレクトリのファイルを書き換えてから、`vp pm patch-commit` でパッチにします。

```bash
echo 'module.exports.patched = true' >> node_modules/.pnpm_patches/picocolors@1.1.1/picocolors.js
vp pm patch-commit node_modules/.pnpm_patches/picocolors@1.1.1
cat patches/picocolors.patch
```

```diff
diff --git a/picocolors.js b/picocolors.js
...
 module.exports = createColors()
 module.exports.createColors = createColors
+module.exports.patched = true
```

`pnpm-workspace.yaml` の差分と、`require` したときの値も確かめます。

```bash
git diff pnpm-workspace.yaml
```

```diff
 overrides:
   vite@*: "catalog:"
+patchedDependencies:
+  picocolors: patches/picocolors.patch
 peerDependencyRules:
```

```bash
node -e 'console.log(require("picocolors").patched)'
```

```
true
```

`patches/picocolors.patch` が作られ、`pnpm-workspace.yaml` の `patchedDependencies` に登録されました。`require` した `picocolors` にも、足した値が入っています。

### vp env use でシェルごとにバージョンを切り替える

`vp env use` は、今のシェルだけNode.jsやパッケージマネージャーのバージョンを切り替えるコマンドです。0.3.2から、パッケージマネージャーのバージョンもNode.jsとは別に切り替えられるようになりました。

手元ではnvmで入れたpnpmを優先する設定にしているため、この節と次の節は `VP_HOME` を別のディレクトリにした環境で試しました。手元のNode.jsとpnpmを消さないためでもあります。

```bash
export VP_HOME=/tmp/vp-sandbox
export PATH="$VP_HOME/bin:/usr/bin:/bin"
~/.vite-plus/current/bin/vp env setup
. "$VP_HOME/env"
```

`PATH` からnvmなどを外しているため、`vp env setup` は手元に入っている `vp` を直接指定して実行し、`VP_HOME` の下に `vp`、`node`、`pnpm` などを作ります。

まず、既定のバージョンを決めます。ここからは、プロジェクトの外にある空のディレクトリで実行しました。

```bash
vp env default 24.22.1
vp env default pnpm@12.15.0
node -v && pnpm -v
```

```
✓ Default Node.js version set to 24.22.1
✓ Default pnpm version set to 12.15.0
v24.22.1
12.15.0
```

次に、`vp env use` でNode.jsとpnpmを別のバージョンに切り替えます。

```bash
vp env use 26.13.0 pnpm@11.8.0
node -v && pnpm -v
```

```
Installing Node.js v26.13.0...
Using Node.js v26.13.0 (resolved from 26.13.0)
Using pnpm v11.8.0 (resolved from 11.8.0)
v26.13.0
11.8.0
```

最後に、`--unset pnpm` でpnpmだけを戻します。

```bash
vp env use --unset pnpm
node -v && pnpm -v
```

```
Reverted selected components to project environment resolution
v26.13.0
12.15.0
```

pnpmだけが既定のバージョンに戻り、Node.jsは26.13.0のままです。Node.jsとパッケージマネージャーを別々に扱えることが分かります。

ただし、先ほどの `vite-plus-pm-lab` の中で同じことをすると、pnpmは12.15.0のままでした。`vp env which pnpm` は11.8.0のpnpmを指していて、そのpnpmをプロジェクトの中で直接実行しても12.15.0と表示されました。`package.json` の `devEngines.packageManager` に書いたバージョンに、pnpm自身が切り替えているようです。`vp create` で作ったプロジェクトにはこの指定が入るため、プロジェクトの中でpnpmのバージョンを変えたいときは `vp env pin` で書き換えることになりそうです。

### vp env clean で使っていないバージョンを消す

0.2.5で入った `vp env clean` は、使っていないNode.jsとパッケージマネージャーを消すコマンドです。ドキュメントによると、今使っているバージョンと既定のバージョンは残ります。先ほどの環境には、Node.jsとpnpmが2つずつ入っています。

```bash
vp env use --unset
vp env list
```

```
Reverted selected components to project environment resolution
Node.js
  * v24.22.1 current default
  * v26.13.0
...
pnpm
  * 11.8.0
  * 12.15.0 default
...
```

`vp env clean` を実行してから、もう一度一覧を見ます。

```bash
vp env clean
```

```
✓ Removed 1 Node.js runtime
✓ Removed 1 package manager install
```

```bash
vp env list
```

```
Node.js
  * v24.22.1 current default
...
pnpm
  * 12.15.0 default
```

既定にしていない26.13.0と11.8.0が消えました。手元で実行するときは、残したいバージョンを先に `vp env default` で既定にしておくと安心です。

## 1.0は本番で使えるのか

アルファ版の記事では「プロダクション利用は慎重に」と書きました。1.0の告知は、安定版であることと、機能がまだ足りないことを両方書いています。

> Vite+ reached 1.0 but is far from feature-complete.
>
> （Vite+は1.0に到達しましたが、機能として完成にはほど遠い状態です）

本番で動いているプロジェクトについては、先に移行ガイドを読むように書かれています。リリースノートを見ると、v0.2.2から1.0までの間に Breaking Changesの節があるリリースが6つありました。1.0のあとの1.1から1.4にはありません。

個人や小さめのプロジェクトであれば、使い始めてよいと感じました。チームで使う場合は、`vp upgrade` のあとに `vp migrate` を実行する手順を更新作業に入れておくのがよさそうです。

## まとめ

アルファ版のときに試したのは、開発サーバー、テスト、チェック、ビルドを `vp` 1つで動かすところまででした。1.0以降は、tsxのようにVite+の外で入れていたツールの役割まで `vp` に入ってきていると感じました。

開発の速さも素晴らしく、v0.2.1が出た6月18日から1.4.0が出た10月23日までの約4か月で、リリースは19回あり、およそ1週間に1回のペースです。同じ期間にGitHubでマージされたPRは、ボットを除いて617件ありました。1日あたり5件ほどで、タイトルが `feat` で始まる機能追加のPRだけでも64件です。

この速さをみると、次は何が増えるのかワクワクしてきます。アルファ版で止まっていた方はぜひ `vp upgrade` と `vp migrate` で上げて試してみてください。

## 参考

- [Releases - voidzero-dev/vite-plus - GitHub](https://github.com/voidzero-dev/vite-plus/releases)
- [Announcing Vite+ 1.0 - VoidZero](https://voidzero.dev/posts/announcing-vite-plus-1-0)
- [vpx - Vite+](https://viteplus.dev/guide/vpx)
- [Commit Hooks - Vite+](https://viteplus.dev/guide/commit-hooks)
- [Package Management - Vite+](https://viteplus.dev/guide/package-management)
- [Environment - Vite+](https://viteplus.dev/guide/env)
- [統合ツールチェーン Vite+ を試してみた - DevelopersIO](https://dev.classmethod.jp/articles/vite-plus-unified-toolchain-tried/)
