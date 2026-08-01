---
title: "TypeScriptをNode.jsなしの実行ファイルにするscriptcを試してみた"
emoji: "⚙️"
type: "tech"
topics: ["typescript", "scriptc", "compiler", "nodejs"]
published: false
---

こんにちは 人材育成室 育成メンバーチームで 研修中の はすと です。

最近、Vercel LabsからTypeScriptをネイティブ実行ファイルにする`scriptc`が公開されていました。Node.jsなしでどのように実行するのか気になったので、`scriptc`の対応範囲を公式情報と3つのサンプルで整理し、`coverage`の出力とNode.jsとの挙動の違いを確認してみます。

## scriptcとは

[scriptc](https://github.com/vercel-labs/scriptc)は、TypeScriptやJavaScriptからネイティブ実行ファイルを生成する実験的なコンパイラで、今回は`0.0.17`を使用します。

公式READMEでは、次のように説明されています。

> "Zero-runtime TypeScript."
>
> （ランタイムを必要としないTypeScript）

TypeScript Compiler APIで構文解析と型検査を行い、型付きの中間表現へ変換します。デフォルトではLLVM IRを生成し、`clang`でネイティブ実行ファイルにします。LLVMで対応していない一部のプログラムではCバックエンドに切り替わります。

公式の[How It Works](https://scriptc.dev/how-it-works)では、バックエンドについて次のように説明されています。

> The LLVM backend is the default. The C backend is the reference.
>
> （LLVMバックエンドがデフォルトで、Cバックエンドは参照用のバックエンドです）

バックエンドの違いと、静的コンパイル・動的実行の分類は別の話です。LLVMとCはどちらもネイティブコードを生成します。デフォルトではLLVMを使い、LLVMバックエンドが対応していない一部のプログラムではCバックエンドに自動で切り替わります。`--backend c`を指定すると、参照用の読みやすいCコードを確認することができます。

一方、`--dynamic`はバックエンドをCにするオプションではありません。QuickJSを組み込み、静的コンパイルできない一部の処理をJavaScriptとして実行するためのオプションです。

### `coverage`の3分類

公式の[Coverage Reports](https://scriptc.dev/coverage)では、通常の`coverage`に表示される状態を次の3つに分類しています。`coverage --dynamic`では、`runs with --dynamic`に該当する箇所が`compile dynamically`と表示されます。

| 分類 | 意味 |
| --- | --- |
| `compile statically` | LLVMまたはCバックエンドでネイティブコードになります。組み込みJavaScriptエンジンは使いません |
| `runs with --dynamic`（`coverage --dynamic`では`compile dynamically`） | `--dynamic`を付けた場合に、組み込みQuickJSでJavaScriptとして実行されます |
| `blockers` | 静的にも動的にも未対応です。`--dynamic`を付けてもビルドできません |

公式ドキュメントには、`runs with --dynamic`について次の説明があります。

> “Sites that would run in the embedded engine if you rebuilt with `--dynamic`.”
>
> （`--dynamic`を付けてビルドし直すと、組み込みエンジンで実行される箇所）

一方、`blockers`はどの分類にも入らず、`--dynamic`でも解消されない箇所です。

`coverage`が100%の場合、そのプログラムの実行文はすべて静的コンパイルされ、動的エンジンなしでネイティブ実行ファイルになります。これはTypeScript全体の対応率ではなく、対象プログラムで静的コンパイルできる割合を示しています。

## 検証環境

今回使用した環境です。

```text
macOS arm64
Node.js v24.18.1（LTS）
Apple clang 21.0.0
scriptc 0.0.17
```

`scriptc@0.0.17`で検証したため、バージョンアップで結果が変わる可能性があります。

検証用ディレクトリで、`scriptc@0.0.17`をインストールします。

```bash
pnpm add -D scriptc@0.0.17
```

## 3つのサンプルでcoverageを確認してみた

`scriptc@0.0.17`で、3つの最小サンプルを確認します。

- `static.ts`: 完全に静的コンパイルされる例
- `dynamic.ts`: `--dynamic`を付けるとビルドできる例
- `blocker.ts`: `--dynamic`を付けてもblockerになる例

### 完全に静的コンパイルされる例

まず、`static.ts`を用意します。

```typescript:static.ts
const quote = "筋肉は裏切らない";

console.log(quote);
```

`coverage`コマンドで、すべての文が静的にコンパイルできることを確認します。

```bash
pnpm exec scriptc coverage static.ts
```

```text
statements analyzed   2
compile statically    2  (100%)

fully static — this program has no dynamic remainder.
```

2つの文がどちらも静的にコンパイルできました。`--dynamic`を付けた場合も、動的に実行される文はありません。

```bash
pnpm exec scriptc coverage static.ts --dynamic
```

```text
statements analyzed   2
compile statically    2  (100%)
compile dynamically   0  (0%) (island sites — the embedded engine runs them)

fully static — this program has no dynamic remainder.
```

続いてビルドします。

```bash
pnpm exec scriptc build static.ts -o .scriptc/static
./.scriptc/static
```

```text
.scriptc/static
筋肉は裏切らない
```

### `--dynamic`ならビルドできる例

`Math.cos`は静的コンパイルの対象外なので、`--dynamic`を付けると組み込みエンジンで実行されます。また、ネットワークアクセスを使わないため、生成した実行ファイルまで確認することができます。

```typescript:dynamic.ts
const result = Math.cos(0);

console.log(result);
```

まずは、通常の`coverage`を実行します。

```bash
pnpm exec scriptc coverage dynamic.ts
```

```text
statements analyzed   2
compile statically    1  (50%)

runs with --dynamic   1 site (embeds a JS engine, ~620KB — static stays the default)
    ×1  'Math.cos' runs in the embedded dynamic engine, which this build does not include  SC2012
```

`--dynamic`を付けた場合の見込みも確認することができます。

```bash
pnpm exec scriptc coverage dynamic.ts --dynamic
```

```text
statements analyzed   2
compile statically    1  (50%)
compile dynamically   1  (50%) (island sites — the embedded engine runs them)

builds with --dynamic — no remaining blockers (the island sites above run in the embedded engine).
```

このように、`--dynamic`を付けると動的に実行される箇所が`compile dynamically`として表示されます。※動的エンジンを組み込むビルドにはCMakeが必要です。

実際にビルドして実行してみます。

```bash
pnpm exec scriptc build dynamic.ts --dynamic -o .scriptc/dynamic
./.scriptc/dynamic
```

```text
.scriptc/dynamic
1
```

`coverage --dynamic`の判定どおり、静的コンパイルされた文と、組み込みエンジンで実行される文を含む実行ファイルを生成できました。

### `blockers`になる例

`console.table`は標準ライブラリの型定義に存在するため型検査は通りますが、`scriptc`にはネイティブコードへ変換する処理がありません。[Coverage Reports](https://scriptc.dev/coverage)では、このような状態を`SC2020`として説明しています。

```typescript:blocker.ts
const quotes = ["筋肉は裏切らない", "迷ったらスクワット"];

console.table(quotes);
```

`--dynamic`を付けても解消されないことを確認します。

まずは、通常の`coverage`を実行してみます。

```bash
pnpm exec scriptc coverage blocker.ts
```

```text
statements analyzed   2
compile statically    1  (50%)

blockers:
    ×1  'console.table' is part of the standard library types but has no scriptc lowering yet  SC2020
```

次に、`--dynamic`を付けて`coverage`を実行します。

```bash
pnpm exec scriptc coverage blocker.ts --dynamic
```

```text
statements analyzed   2
compile statically    1  (50%)
compile dynamically   0  (0%) (island sites — the embedded engine runs them)

blockers:
    ×1  'console.table' is part of the standard library types but has no scriptc lowering yet  SC2020
```

`--dynamic`を付けても、`console.table`は`compile dynamically`にならず、`blockers`として残りました。型定義がある機能でも、静的コンパイルと動的実行のどちらでも対応していなければビルドできないことが分かります。

実際にビルドしても拒否されます。

```bash
pnpm exec scriptc build blocker.ts --dynamic
```

```text
error SC2020: 'console.table' is part of the standard library types but has no scriptc lowering yet

1 error.
```

この結果から、`--dynamic`は未対応の機能をすべて救済するオプションではないことが分かります。

## Node.jsと異なる挙動も確認してみた

`scriptc`は、すべての場面でNode.jsと同じ挙動を再現するわけではありません。[Limitations](https://scriptc.dev/limitations)には、意図的な違いや未対応の構文が整理されています。

今回は配列の範囲外アクセスを試しました。

```typescript:array-boundary.ts
const trainingQuotes = ["筋肉は裏切らない", "迷ったらスクワット"];

console.log(trainingQuotes[10]);
```

配列の添字が範囲内かどうかは、TypeScriptの型検査では判定されません。Node.jsでは実行時の例外にはならず、`undefined`が表示されます。

```bash
node array-boundary.ts
```

```text
undefined
```

`scriptc coverage`では100%静的にコンパイルできると判定され、ビルドも成功します。

```bash
pnpm exec scriptc coverage array-boundary.ts
pnpm exec scriptc build array-boundary.ts -o .scriptc/array-boundary
./.scriptc/array-boundary
```

```text
statements analyzed   2
compile statically    2  (100%)

fully static — this program has no dynamic remainder.
.scriptc/array-boundary
scriptc: RangeError: array index 10 out of bounds (length 2)
```

一方、`scriptc`で生成した実行ファイルは、範囲外アクセスの時点でエラーになります。

このように、`coverage`の値はコンパイル方法を示すもので、Node.jsとの挙動が同じかどうかは別に確認する必要があります。

## まとめ

`scriptc`を使うと、静的コンパイルできる範囲のTypeScriptから、Node.jsやV8を含まないネイティブ実行ファイルを生成できました。`coverage`では、静的コンパイルされる箇所、`--dynamic`で組み込みエンジンを使う箇所、どちらでも対応していない箇所を事前に確認することができます。しかし、`coverage`が100%の場合でも、Node.jsとの挙動が異なる場合もあるので注意が必要です。

静的コンパイルと動的実行の分類、LLVM・Cバックエンドの選択が別の仕組みになっている点も確認できました。TypeScriptから生成されるLLVM IRや参照用のCコードの中身も気になるため、次回は`--emit-ir`や`--backend c`を使って覗いてみたいと思います。

## 参考

- [scriptc - GitHub](https://github.com/vercel-labs/scriptc)
- [Quickstart - scriptc](https://scriptc.dev/quickstart)
- [CLI Reference - scriptc](https://scriptc.dev/cli)
- [How It Works - scriptc](https://scriptc.dev/how-it-works)
- [Coverage Reports - scriptc](https://scriptc.dev/coverage)
- [Limitations - scriptc](https://scriptc.dev/limitations)
- [Node.js Releases - Node.js](https://nodejs.org/en/about/previous-releases)
