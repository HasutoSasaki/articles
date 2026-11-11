---
title: "Vite+ 1.5 がリリースされたので、vp migrate は ts-node をどこまで移行してくれるのか試してみた"
emoji: "🧰"
type: "tech"
topics: ["vite", "viteplus", "typescript", "nodejs", "tsnode"]
published: false
---

こんにちは、クラスメソッド製造ビジネステクノロジー部のはすとです。

前回の [Vite+ 1.0がリリースされたので、アルファ版から増えた機能を試してみた](https://dev.classmethod.jp/articles/vite-plus-v1-new-features-tried/) では、1.4.0 までの機能を触り、`vpx` で TypeScript のファイルを直接実行できることを確かめました。その後、11 月 4 日に Vite+ 1.5.0 が出て、リリースノートの冒頭に次の 1 文がありました。

> Vite+ 1.5 adds an official Homebrew tap, runs TypeScript through Node.js with `node --import vite-plus/register`, and lets `vp migrate` move `oxnode` and transpile-only `ts-node` scripts to `vpx`.
>
> （Vite+ 1.5 は公式の Homebrew tap を追加し、`node --import vite-plus/register` で Node.js から TypeScript を実行できるようにし、`vp migrate` で `oxnode` と型チェックをしない `ts-node` のスクリプトを `vpx` に移せるようにしました）

1.4.0 までの `vp migrate` は、ts-node のプロジェクトにも Vite+ を入れられましたが、ts-node のスクリプトには手を付けませんでした。ただ、ts-node は TypeScript 7 では動かないので、TypeScript を上げるなら、いずれ ts-node から移る必要があります。1.5.0 でそこまで移行できるなら、ts-node を依存から外せるのでは？？と気になりました。

本記事では、ts-node で組んだ小さなプロジェクトを `vp migrate` で移行し、ts-node を外すところまで試します。

先に結論を言うと、自動で移行できるのは型チェックをしない（`transpile-only` の）ts-node だけでした。型チェックありの ts-node は警告が出るだけで残るため、`vp check` と分けて手動で移すことになります。

## 検証用のプロジェクト

ts-node で動かしている想定で、以下プロジェクトを用意しました。`"type": "module"` の ESM で、スクリプトは 3 本です。

```json
// package.json
{
  "name": "ts-app",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "seed": "node --loader ts-node/esm/transpile-only scripts/seed.ts",
    "report": "node --loader ts-node/esm scripts/report.ts",
    "test": "node --loader ts-node/esm/transpile-only --test test/price.test.ts"
  },
  "devDependencies": {
    "@types/node": "^26.6.6",
    "ts-node": "^10.9.2",
    "typescript": "^6.0.3"
  }
}
```

| スクリプト | 中身 | 型チェック |
|---|---|---|
| `seed` | ts-node のローダーでスクリプトを実行 | しない（`transpile-only`） |
| `report` | ts-node のローダーでスクリプトを実行 | する |
| `test` | Node.js のテストランナーに ts-node のローダーを読ませる | しない（`transpile-only`） |

TypeScript を 6 系にしているのは、ts-node が TypeScript 7 で動かないためです。TypeScript 7 で実行すると、`TypeError: Cannot read properties of undefined (reading 'fileExists')` で止まりました。TypeScript 7 のパッケージからは、ts-node が使うコンパイラの API（`ts.sys` など）がなくなっています。
ts-node は 2023 年 12 月の 10.9.2 から新しい版が出ていないので、TypeScript 7 に上げるなら ts-node から移る必要があります。

```json
// tsconfig.json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "rootDir": ".",
    "strict": true,
    "allowImportingTsExtensions": true,
    "noEmit": true
  }
}
```

計算の本体には、税率を表す enum を入れました。手元で確かめた範囲では、Node.js 22.18 以降（22.18.0、24.11.0、26.13.0）は、型の注釈を取り除くだけで済むコードなら `.ts` のファイルを素の `node` で実行できます。`vite-plus/register` が動くのも Node.js 22.18 以上なので、注釈だけのコードでは、移行後に変換が使われているのかを見分けられません。
そこで、`node` だけでは `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` で止まる enum を使い、移行後に `vite-plus/register` の変換が使われていることを確かめます。検証に使った Nodeのバージョン は v26.13.0 です。



```ts
// src/price.ts
export type Item = { name: string; price: number; quantity: number };

// 消費税率（%）
export enum TaxRate {
  Standard = 10,
  Reduced = 8,
}

// 税込みの合計金額を返す
export function totalWithTax(items: Item[], rate: TaxRate = TaxRate.Standard): number {
  const subtotal = items.reduce((sum, item) => sum + item.price * item.quantity, 0);
  return Math.round((subtotal * (100 + rate)) / 100);
}
```

テストは Node.js 標準の `node:test` で書きます。

```ts
// test/price.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { totalWithTax } from "../src/price.ts";

test("税込みの合計金額を返す", () => {
  assert.equal(totalWithTax([{ name: "コーヒー", price: 450, quantity: 2 }]), 990);
});
```

`scripts/seed.ts` と `scripts/report.ts` は中身が同じで、`totalWithTax` の結果を表示するだけです。`vp migrate` の結果の違いを型チェックの有無だけにするため、中身はそろえています。

```ts
// scripts/seed.ts（scripts/report.ts も同じ）
import { totalWithTax, type Item } from "../src/price.ts";

const items: Item[] = [
  { name: "コーヒー", price: 450, quantity: 2 },
  { name: "ケーキ", price: 520, quantity: 1 },
];
console.log(`税込み合計: ${totalWithTax(items)} 円`);
```

移行前に、3 本とも動くことを確かめておきます。

```bash
pnpm seed
pnpm report
pnpm test
```

```
税込み合計: 1562 円
税込み合計: 1562 円
ℹ pass 1
ℹ fail 0
```

:::message
ESM のプロジェクトで ts-node を使う書き方には、`ts-node --esm scripts/seed.ts` もあります。ただ Node.js 26 では、この書き方だと `.ts` を Node.js 標準の仕組みが先に処理してしまい、ts-node の変換は使われませんでした。enum を含むファイルは `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX` で止まり、型の誤りがあってもそのまま実行されます。そのため今回は、ts-node の変換が確実に使われる `node --loader ts-node/esm` の形にしています。
:::

## 1.4.0 の vp migrate では何も変わらない

比較のため、先に 1.4.0 の `vp migrate` を実行してみます。

```bash
vp upgrade 1.4.0
vp migrate --no-interactive --no-agent --no-editor --no-hooks
```

```
◇ Migrated . to Vite+ 1.4.0
• Node 26.13.0  pnpm 12.16.1
✓ Dependencies installed in 1.6s
• 1 config update applied
```

`package.json` の差分は `vite-plus` の追加だけで、ts-node のスクリプトはそのまま残りました。ts-node についての警告も出ていません。

## 1.5.0 の vp migrate で移行する

### そのままでは 3 本とも移行されなかった

グローバルの `vp` を 1.5.0 に上げ、最初の状態のプロジェクトで `vp migrate` を実行します。

```bash
vp upgrade
vp migrate --no-interactive --no-agent --no-editor --no-hooks
```

実行結果です。

```
● ts-node scripts detected. Auto-migrating supported commands to Vite+...
◇ Migrated . to Vite+ 1.5.0
• Node 26.13.0  pnpm 12.16.1
✓ Dependencies installed in 1.7s
• 1 config update applied
! Warnings:
  - Kept ts-node in package.json scripts "seed": the Node.js preload needs the ts-node config pinned explicitly; set TS_NODE_PROJECT to its file path before migrating.
  - Kept ts-node in package.json scripts "report": this ts-node command type-checks before execution; `vpx` does not type-check. Keep a separate type-check command before changing this script.
  - Kept ts-node in package.json scripts "test": the Node.js preload needs the ts-node config pinned explicitly; set TS_NODE_PROJECT to its file path before migrating.
  - Kept the ts-node devDependency in package.json: `scripts` in package.json still uses ts-node.
```

1.4.0 と違って ts-node のスクリプトを見つけていますが、3 本ともまだ書き換わりませんでした。`seed` と `test` には、ts-node が読む設定ファイルを `TS_NODE_PROJECT` で明示してから移行するよう案内が出ています。

### TS_NODE_PROJECT を付けたら seed が移行された

移行前の状態に戻し、`seed` と `test` の先頭に `TS_NODE_PROJECT=tsconfig.json` を付けてから、もう一度 `vp migrate` を実行しました。

```json
"seed": "TS_NODE_PROJECT=tsconfig.json node --loader ts-node/esm/transpile-only scripts/seed.ts",
"test": "TS_NODE_PROJECT=tsconfig.json node --loader ts-node/esm/transpile-only --test test/price.test.ts"
```

```
• ts-node scripts migrated to Vite+
! Warnings:
  - Kept ts-node in package.json scripts "report": this ts-node command type-checks before execution; `vpx` does not type-check. Keep a separate type-check command before changing this script.
  - Kept ts-node in package.json scripts "test": `test/price.test.ts` has runtime bindings from `node:assert/strict` whose CommonJS interop or import/require resolution may change with `vpx`; migrate the bindings manually.
  - Kept the ts-node devDependency in package.json: `scripts` in package.json still uses ts-node.
```

```diff
-    "seed": "TS_NODE_PROJECT=tsconfig.json node --loader ts-node/esm/transpile-only scripts/seed.ts",
+    "seed": "TS_NODE_PROJECT=tsconfig.json node --import vite-plus/register scripts/seed.ts",
```

`seed` は、ts-node のローダーが `--import vite-plus/register` に置き換わりました。元が `node` コマンドなので、移行先も `vpx` ではなく `node` のままです。`vite-plus/register` は 1.5.0 で増えたもので、`vpx` と同じ TypeScript の変換処理を Node.js に登録します。

ただし、`vite-plus/register` は Node.js 22.18 以上でないと動きません。Node.js 22.12 では、次のエラーで止まりました（20.19 でも動きませんでした）。

```
error: Running scripts with vpx requires Node.js ^22.18.0 || ^24.11.0 || >=26.0.0 (current: v22.12.0)
```

そのため、古い Node.js で ts-node を使っているプロジェクトは、先に Node.js を上げる必要があります。

`test` には別の警告が出ました。`node:assert/strict` から読み込んでいる値が、CommonJS との相互運用の都合で変わるかもしれない、という内容です。テストファイルの `import assert from "node:assert/strict"` の default import が引っかかっています。

### 名前付きの import に変えたら test も移行された

そこで、`TS_NODE_PROJECT` を付けた移行前の状態に戻し、テストを名前付きの import に変えてから、もう一度 `vp migrate` を実行しました。

```ts
// test/price.test.ts
import { test } from "node:test";
import { equal } from "node:assert/strict"; // 変更
import { totalWithTax } from "../src/price.ts";

test("税込みの合計金額を返す", () => {
  equal(totalWithTax([{ name: "コーヒー", price: 450, quantity: 2 }]), 990); // 変更
});
```

実行結果です。

```
• ts-node scripts migrated to Vite+
! Warnings:
  - Kept ts-node in package.json scripts "report": this ts-node command type-checks before execution; `vpx` does not type-check. Keep a separate type-check command before changing this script.
  - Kept the ts-node devDependency in package.json: `scripts` in package.json still uses ts-node.
```

```diff
-    "seed": "TS_NODE_PROJECT=tsconfig.json node --loader ts-node/esm/transpile-only scripts/seed.ts",
+    "seed": "TS_NODE_PROJECT=tsconfig.json node --import vite-plus/register scripts/seed.ts",
-    "test": "TS_NODE_PROJECT=tsconfig.json node --loader ts-node/esm/transpile-only --test test/price.test.ts"
+    "test": "TS_NODE_PROJECT=tsconfig.json node --import vite-plus/register --test test/price.test.ts"
```

名前付きの import にしたことで、`test` も書き換わりました。書き換わった 2 本を動かします。

```bash
pnpm seed
pnpm test
```

```
$ TS_NODE_PROJECT=tsconfig.json node --import vite-plus/register scripts/seed.ts
税込み合計: 1562 円

✔ 税込みの合計金額を返す (2.970042ms)
ℹ pass 1
ℹ fail 0
```

enum を含むコードが、ts-node なしで動いています。移行のために付けた `TS_NODE_PROJECT` はそのまま残っています。

### 型チェックありの report は vp check と分けて移行した

`report` の警告は、ts-node は実行前に型チェックするが `vpx` はしない、という内容です。[移行ルールのドキュメント](https://viteplus.dev/guide/migrate-rules#ts-node-to-vpx)にも同じことが書かれています。

> Migration offers to replace supported ts-node commands with vpx only when type-checking is explicitly disabled. Plain ts-node type-checks before execution; vpx does not.
>
> （移行処理が ts-node のコマンドを vpx に置き換えるのは、型チェックが明示的に無効になっている場合だけです。素の ts-node は実行前に型チェックしますが、vpx はしません）

違いを確かめるため、`scripts/report.ts` の価格をわざと文字列にしました。

```ts
// scripts/report.ts
const items: Item[] = [
  { name: "コーヒー", price: 450, quantity: 2 },
  { name: "ケーキ", price: "520", quantity: 1 }, // 型が合わない
];
```

まず移行前の ts-node で実行します。

```bash
node --loader ts-node/esm scripts/report.ts
echo $?
```

```
node:internal/modules/run_main:111
    triggerUncaughtException(
    ^
[Object: null prototype] {
  Symbol(nodejs.util.inspect.custom): [Function: [nodejs.util.inspect.custom]]
}
1
```

型の誤りで終了コード 1 になり、スクリプトは実行されませんでした。ローダーの形で使うと、エラーの中身は読める形で表示されないようです。

同じファイルを `vite-plus/register` と `vp check` に通します。

```bash
node --import vite-plus/register scripts/report.ts
vp check
```

```
税込み合計: 1562 円

x typescript(TS2322): Type 'string' is not assignable to type 'number'.
  ! typescript(no-floating-promises): Promises must be awaited, add void operator to ignore.
Found 1 error and 1 warning in 5 files (1.0s, 10 threads)
```

`vite-plus/register` は型が合わないまま実行し、文字列の `"520"` が掛け算で数値に変換されたため、結果も変わりませんでした。型の誤りを見つけたのは `vp check` です。そこで警告の案内どおり、型チェックを別のコマンドに分けました。ほかの 2 本にそろえて、実行は `node --import vite-plus/register` にしています。

```json
"report": "vp check && node --import vite-plus/register scripts/report.ts"
```

この形なら、型の誤りがあると `vp check` が終了コード 1 で止まり、スクリプトは実行されません。

### ts-node を外す

最後に、`seed` と `test` に残った `TS_NODE_PROJECT` を消し、ts-node を依存から外します。

```bash
vp remove ts-node
```

移行後の `package.json` は以下のようになりました。

```json
{
  "name": "ts-app",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "seed": "node --import vite-plus/register scripts/seed.ts",
    "report": "vp check && node --import vite-plus/register scripts/report.ts",
    "test": "node --import vite-plus/register --test test/price.test.ts"
  },
  "devDependencies": {
    "@types/node": "^26.6.6",
    "typescript": "^6.0.3",
    "vite-plus": "catalog:"
  }
}
```

3 本とも動くことを確かめます。

```bash
pnpm seed
pnpm report
pnpm test
```

```
税込み合計: 1562 円

Found 0 errors and 1 warning in 5 files (229ms, 10 threads)
税込み合計: 1562 円

ℹ pass 1
ℹ fail 0
```

ts-node が依存から消え、TypeScript の実行は `vite-plus/register`、型チェックは `vp check` という分担になりました。

## CommonJS のプロジェクトでは書き換わらなかった

`"type": "module"` を付けていない CommonJS のプロジェクトでも、同じ移行を試してみました。スクリプトは `ts-node --transpileOnly`、`ts-node`、`TS_NODE_PROJECT=tsconfig.json node -r ts-node/register/transpile-only --test` の 3 本で、テストは最初から名前付きの import にしています。

```
! Warnings:
  - Kept ts-node in package.json scripts "seed": `scripts/seed.ts` has runtime bindings from `../src/price.ts` whose CommonJS interop or import/require resolution may change with `vpx`; migrate the bindings manually.
  - Kept ts-node in package.json scripts "report": this ts-node command type-checks before execution; `vpx` does not type-check. Keep a separate type-check command before changing this script.
  - Kept ts-node in package.json scripts "test": `test/price.test.ts` has runtime bindings from `../src/price.ts` whose CommonJS interop or import/require resolution may change with `vpx`; migrate the bindings manually.
```

3 本とも書き換わりませんでした。`seed` と `test` は、自分のプロジェクトの `../src/price.ts` からの import が、CommonJS との相互運用で変わるかもしれないという警告です。`report` は ESM のときと同じ型チェックの警告でした。

手動で `node --import vite-plus/register` や `vpx` に書き換えると、このプロジェクトでも 3 本とも動きました。`vp migrate` は、挙動が変わらないと判断できたものだけを書き換えるようです。

## まとめ

1.5.0 の `vp migrate` は、1.4.0 では手を付けなかった ts-node のスクリプトを書き換えるようになりました。ただし、自動で移るのは型チェックをしない ts-node だけで、少しでも挙動が変わりそうなものは書き換えずに、警告で理由を示します。今回は警告に従って 3 回実行し、型チェックありの 1 本を `vp check` と分けて手で移して、ts-node を依存から外せました。

少し手間はかかりましたが、警告がそのまま次にやることの一覧になっていたので、迷わずに移行できました。

ts-node が残っているプロジェクトに Vite+ を導入してみたい方は、ぜひ 1.5.0 の `vp migrate` を試してみてください。

## 参考

- [Release v1.5.0 - voidzero-dev/vite-plus - GitHub](https://github.com/voidzero-dev/vite-plus/releases/tag/v1.5.0)
- [ts-node to vpx - Vite+ Migration Rules](https://viteplus.dev/guide/migrate-rules#ts-node-to-vpx)
- [Using Node.js directly - Vite+ Guide](https://viteplus.dev/guide/vpx#using-node-js-directly)
- [Vite+ 1.0がリリースされたので、アルファ版から増えた機能を試してみた - DevelopersIO](https://dev.classmethod.jp/articles/vite-plus-v1-new-features-tried/)
