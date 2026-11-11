---
title: "ESLintがシェルスクリプトに公式対応したので、ShellCheckと比べて独自ルールも書いてみた"
emoji: "🐚"
type: "tech"
topics: ["eslint", "shellscript", "shellcheck", "bash", "javascript"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

2026年11月6日に、ESLintがシェルスクリプトのLintに公式対応したと発表されました。JSON、Markdown、CSSに続く公式の言語プラグインで、パッケージ名は `@eslint/shell` です。シェルスクリプトのLintといえばShellCheckを使っている方が多いと思います。ESLintでも同じことができるならShellCheckの代わりになるのか、ESLintだからこそできることはあるのか、が気になりました。

本記事では、同じスクリプトに `@eslint/shell` とShellCheckをかけて結果を比べ、ShellCheckではできない独自ルールも書いてみた結果をまとめます。先に言っておくと、同じShellCheckの番号に対応するルールでも、指摘の出し方や自動修正の範囲が違いました。

## @eslint/shell とは

`@eslint/shell` は、シェルスクリプトを構文木に変換するパーサーと、ESLintのルール、推奨設定をまとめたプラグインです。パーサーは `mvdan-sh` をもとにしています。`mvdan-sh` は、シェルスクリプトのフォーマッター `shfmt` のパーサー（mvdan.cc/sh）をJavaScript向けにビルドしたものです。対応しているのはBash、POSIXの `sh`、MirBSD Korn shell（mksh）の3つです。

https://eslint.org/blog/2026/11/eslint-shell-plugin-announcement/

ルールは10個あります。[READMEのルール一覧](https://github.com/eslint/shell#rules)には、各ルールがどのShellCheckのチェックに対応するかが書かれています。

> Each rule mirrors a well-known ShellCheck check.

（和訳）各ルールは、よく知られたShellCheckのチェックに対応しています。

| ルール | 対応するShellCheckの番号 | 内容 | `--fix` | 推奨設定 |
|---|---|---|---|---|
| `no-backticks` | SC2006 | バッククォートではなく `$(...)` を使う | 可 | error |
| `no-expansions-in-single-quotes` | SC2016 | シングルクォートの中では変数が展開されない | | warn |
| `no-ls-iteration` | SC2045 | `ls` の出力をループで回さない | | error |
| `no-unquoted-expansions` | SC2086/46 | 展開をダブルクォートで囲む | 可 | error |
| `no-unused-vars` | SC2034 | 代入したのに使っていない変数 | | error |
| `no-useless-cat` | SC2002 | ファイル1つだけの `cat` をパイプに渡さない | | error |
| `no-useless-echo` | SC2116 | `$(echo ...)` を使わない | | error |
| `no-variables-in-printf-format` | SC2059 | `printf` の書式文字列に変数を入れない | | error |
| `require-cd-guard` | SC2164 | `cd` の失敗を `\|\| exit` で扱う（修正案の提示あり） | | error |
| `require-read-r` | SC2162 | `read` に `-r` を付ける | 可 | error |

番号の対応はREADMEに書かれているため、本記事では、同じ番号のチェックが同じスクリプトに対して実際にどう動くかを確かめます。

## 検証環境

2026年11月8日時点で、次のバージョンを使いました。

| ツール | バージョン |
|---|---|
| macOS | 26.7.1 |
| Node.js | v26.13.0（最新のLTS） |
| pnpm | 12.18.0 |
| ESLint | 10.14.0 |
| `@eslint/shell` | 0.1.2 |
| ShellCheck | 0.11.0（Homebrewで導入） |

## セットアップ

ESLintとプラグインを入れます。

```bash
pnpm add -D eslint @eslint/shell
```

設定ファイルには、まず推奨設定だけを書きます。推奨設定は `**/*.sh` と `**/*.bash` を対象にし、Bashとして解析します。

```js:eslint.config.js
import { defineConfig } from "eslint/config";
import shell from "@eslint/shell";

export default defineConfig([
  {
    plugins: { shell },
    extends: ["shell/recommended"],
  },
]);
```

## 同じスクリプトにかけてみた

よくある間違いを詰め込んだ、デプロイ用のスクリプトを用意しました。

```bash:scripts/deploy.sh
#!/bin/bash
# ビルドした成果物を S3 にアップロードする
BUILD_DIR=./dist
BUCKET=$1
LOG_FILE=deploy.log

cd $BUILD_DIR

for f in $(ls *.js); do
  size=`wc -c < $f`
  printf "$f: $size bytes\n"
done

cat manifest.txt | grep version
echo 'アップロード先: $BUCKET'
name=$(echo $BUCKET)

read -p "続けますか？ [y/N] " answer
if [ $answer != "y" ]; then
  exit 1
fi

cleanup() {
  local ts=$(date +%s)
  echo "cleanup at $ts"
  rm -rf "$TARGET_DIR/"*
}

aws s3 sync . "s3://$name/"
if [ $? -ne 0 ]; then
  cleanup
fi
```

まずESLintです。

```bash
pnpm exec eslint scripts/deploy.sh
```

実行結果です。

```text
/path/to/eslint-shell-check/scripts/deploy.sh
   5:1   error    Variable 'LOG_FILE' is assigned but never used                                 shell/no-unused-vars
   7:1   error    Use 'cd ... || exit' or 'cd ... || return' in case cd fails                    shell/require-cd-guard
   7:4   error    Double quote "$BUILD_DIR" to prevent word splitting and globbing               shell/no-unquoted-expansions
   9:10  error    Iterating over ls output is fragile. Use globs (e.g. *) instead                shell/no-ls-iteration
   9:10  error    Quote this command substitution to prevent word splitting                      shell/no-unquoted-expansions
  10:8   error    Use $(...) notation instead of legacy backticks                                shell/no-backticks
  10:17  error    Double quote "$f" to prevent word splitting and globbing                       shell/no-unquoted-expansions
  11:10  error    Don't use variables in the printf format string. Use printf '...%s...' "$foo"  shell/no-variables-in-printf-format
  14:1   error    Useless cat. Consider 'cmd < file' or 'cmd file' instead                       shell/no-useless-cat
  15:6   warning  Expressions don't expand in single quotes; use double quotes for that          shell/no-expansions-in-single-quotes
  16:6   error    Useless echo? Instead of 'cmd $(echo foo)', just use 'cmd foo'                 shell/no-useless-echo
  16:13  error    Double quote "$BUCKET" to prevent word splitting and globbing                  shell/no-unquoted-expansions
  18:1   error    Using read without -r will mangle backslashes                                  shell/require-read-r
  19:6   error    Double quote "$answer" to prevent word splitting and globbing                  shell/no-unquoted-expansions

✖ 14 problems (13 errors, 1 warning)
  6 errors and 0 warnings potentially fixable with the `--fix` option.
```

次にShellCheckです。`-f gcc` は、1件を1行で出す形式を指定するオプションです。

```bash
shellcheck -f gcc scripts/deploy.sh
```

実行結果です。

```text
scripts/deploy.sh:5:1: warning: LOG_FILE appears unused. Verify use (or export if used externally). [SC2034]
scripts/deploy.sh:7:1: warning: Use 'cd ... || exit' or 'cd ... || return' in case cd fails. [SC2164]
scripts/deploy.sh:9:10: error: Iterating over ls output is fragile. Use globs. [SC2045]
scripts/deploy.sh:9:15: note: Use ./*glob* or -- *glob* so names with dashes won't become options. [SC2035]
scripts/deploy.sh:10:8: note: Use $(...) notation instead of legacy backticks `...`. [SC2006]
scripts/deploy.sh:10:17: note: Double quote to prevent globbing and word splitting. [SC2086]
scripts/deploy.sh:11:10: note: Don't use variables in the printf format string. Use printf '..%s..' "$foo". [SC2059]
scripts/deploy.sh:15:6: note: Expressions don't expand in single quotes, use double quotes for that. [SC2016]
scripts/deploy.sh:16:6: note: Useless echo? Instead of 'cmd $(echo foo)', just use 'cmd foo'. [SC2116]
scripts/deploy.sh:16:13: note: Double quote to prevent globbing and word splitting. [SC2086]
scripts/deploy.sh:18:1: note: read without -r will mangle backslashes. [SC2162]
scripts/deploy.sh:19:6: note: Double quote to prevent globbing and word splitting. [SC2086]
scripts/deploy.sh:24:9: warning: Declare and assign separately to avoid masking return values. [SC2155]
scripts/deploy.sh:26:10: warning: Use "${var:?}" to ensure this never expands to /* . [SC2115]
scripts/deploy.sh:30:6: note: Check exit code directly with e.g. 'if ! mycmd;', not indirectly with $?. [SC2181]
```

ESLintが14件、ShellCheckが15件です。メッセージの文面はほぼ同じですが、行と列で突き合わせると、次のように分かれました。

| 区分 | 件数 | 指摘した箇所 |
|---|---|---|
| 両方が指摘 | 11件 | 5:1、7:1、9:10（`ls`のループ）、10:8、10:17、11:10、15:6、16:6、16:13、18:1、19:6 |
| ESLintだけ | 3件 | 7:4（`$BUILD_DIR`）、9:10（`$(ls *.js)`のクォート）、14:1（`cat`） |
| ShellCheckだけ | 4件 | SC2035、SC2155、SC2115、SC2181 |

なお、重大度の付け方も違います。ESLintの推奨設定はほとんどが `error` ですが、ShellCheckは同じ内容の多くを `note` として出しています。

### `cd $BUILD_DIR` をShellCheckが指摘しなかった理由

7行目の `cd $BUILD_DIR` は、ESLintだけがクォートの付け忘れを指摘しました。同じSC2086に対応するルールのため、ShellCheckも指摘するはずだと考えると思います。

小さいスクリプトで確かめます。

```bash:t1.sh
#!/bin/bash
D=./dist
ls $D
E="./my dist"
ls $E
ls $1
```

```bash
shellcheck -f gcc t1.sh
```

実行結果です。

```text
t1.sh:5:4: note: Double quote to prevent globbing and word splitting. [SC2086]
t1.sh:6:4: note: Double quote to prevent globbing and word splitting. [SC2086]
```

実際には、ShellCheckは空白を含まない `./dist` を代入した `$D` を指摘しませんでした。空白を含む `$E` と、中身の分からない `$1` だけを指摘しています。ShellCheckには代入された値を追いかける解析（データフロー解析）があり、`--extended-analysis=false` でこの解析を止められます。止めて実行してみます。

```bash
shellcheck -f gcc --extended-analysis=false t1.sh
```

実行結果です。

```text
t1.sh:3:4: note: Double quote to prevent globbing and word splitting. [SC2086]
t1.sh:5:4: note: Double quote to prevent globbing and word splitting. [SC2086]
t1.sh:6:4: note: Double quote to prevent globbing and word splitting. [SC2086]
```

解析を止めると、`$D` も指摘されました。一方で、ESLintは代入された値を追いかけず、3つとも指摘します。

```bash
pnpm exec eslint t1.sh
```

実行結果です。

```text
/path/to/eslint-shell-check/t1.sh
  3:4  error  Double quote "$D" to prevent word splitting and globbing  shell/no-unquoted-expansions
  5:4  error  Double quote "$E" to prevent word splitting and globbing  shell/no-unquoted-expansions
  6:4  error  Double quote "$1" to prevent word splitting and globbing  shell/no-unquoted-expansions

✖ 3 problems (3 errors, 0 warnings)
  3 errors and 0 warnings potentially fixable with the `--fix` option.
```

ただし、ESLintもすべての変数を指摘するわけではありません。`deploy.sh` の30行目 `if [ $? -ne 0 ]` はクォートがありませんが、どちらも指摘していません。`no-unquoted-expansions` のコードを見ると、`$?`、`$$`、`$!`、`$#`、`$-` は空白を含む値にならないため、名前で対象外にしていました。

あとで値を変えたときに困らないよう、変数は全部クォートしておく方針なら、ESLintの方が取りこぼしなく指摘してくれます。

### `$(ls *.js)` へのクォートの指摘

9行目の `for f in $(ls *.js)` に対して、ESLintは `no-ls-iteration` に加えて「コマンド置換をクォートしてください」とも指摘しました。ShellCheckがこの位置で出したのはSC2045（`ls` の出力をループで回さない）だけです。

メッセージどおりにクォートすると、どうなるかを試します。`a.js` と `b.js` があるディレクトリで実行しました。

```bash:quoted.sh
#!/bin/bash
for f in "$(ls *.js)"; do
  echo "[$f]"
done
```

```bash
bash quoted.sh
```

実行結果です。

```text
[a.js
b.js]
```

`ls` の出力全体が1つの文字列になり、ループは1回しか回りませんでした。この行の正しい直し方は、`no-ls-iteration` のメッセージにあるとおり `for f in *.js` のようにグロブを使うことです。なお、ESLintの `--fix` はこの箇所にクォートを付けません。`no-unquoted-expansions` のコードを見ると、`for` で `ls` の出力を回している場合は自動修正を付けないようにしていました。自動修正でループの動きが変わることはありませんが、メッセージを読んで手で直すときは注意が必要です。

### ShellCheckだけが出したもの

ShellCheckだけが出した4件は、`@eslint/shell` に対応するルールがないものです。

| 番号 | 内容 |
|---|---|
| SC2035 | `*.js` のようなグロブは、`-` で始まるファイル名がオプションと解釈されないよう `./*.js` にする |
| SC2155 | `local ts=$(date +%s)` のように宣言と代入を同時にすると、コマンドの終了コードが消える |
| SC2115 | `rm -rf "$TARGET_DIR/"*` は、変数が空だと `/*` を消してしまう |
| SC2181 | `$?` を見るのではなく `if ! コマンド; then` で直接判定する |

とくにSC2115は、変数が空のまま `rm -rf` が実行される事故を防ぐチェックです。ルールが10個のESLintでは、今のところ拾えません。

### 不要な `cat` の扱い

14行目の `cat manifest.txt | grep version` は、ESLintだけが指摘しました。ShellCheckでは、このチェック（SC2002）は既定で無効になっています。`-o` は、既定で無効になっているチェックを有効にするオプションです。

```bash
shellcheck -f gcc -o useless-use-of-cat scripts/deploy.sh
```

実行結果のうち、追加された行です。

```text
scripts/deploy.sh:14:5: note: Useless cat. Consider 'cmd < file | ..' or 'cmd file | ..' instead. [SC2002]
```

有効にすると、ShellCheckでも指摘されました。既定で無効なチェックは `shellcheck --list-optional` で一覧できます。

## 自動修正で直る範囲

ESLintは `--fix` で、ShellCheckは `-f diff` で修正を出せます。`--fix` はファイルを直接書き換えるため、ここではコピーしたファイルを修正して、元のファイルと比べます。

```bash
mkdir -p fixed
cp scripts/deploy.sh fixed/deploy.sh
pnpm exec eslint --fix fixed/deploy.sh
diff -u scripts/deploy.sh fixed/deploy.sh
```

実行結果です（`--fix` で直らなかった指摘の一覧は省略しています）。

```diff
--- scripts/deploy.sh	2026-11-08 14:24:17
+++ fixed/deploy.sh	2026-11-08 14:32:51
@@ -4,19 +4,19 @@
 BUCKET=$1
 LOG_FILE=deploy.log
 
-cd $BUILD_DIR
+cd "$BUILD_DIR"
 
 for f in $(ls *.js); do
-  size=`wc -c < $f`
+  size=$(wc -c < "$f")
   printf "$f: $size bytes\n"
 done
 
 cat manifest.txt | grep version
 echo 'アップロード先: $BUCKET'
-name=$(echo $BUCKET)
+name=$(echo "$BUCKET")
 
-read -p "続けますか？ [y/N] " answer
-if [ $answer != "y" ]; then
+read -r -p "続けますか？ [y/N] " answer
+if [ "$answer" != "y" ]; then
   exit 1
 fi
```

ShellCheckの `-f diff` は、修正内容を差分の形式で出力するオプションで、ファイルは書き換えません。出力した差分は `patch` コマンドで当てます。

```bash
shellcheck -f diff scripts/deploy.sh > fix.diff
patch -p1 < fix.diff
```

`fix.diff` の中身です。

```diff
--- a/scripts/deploy.sh
+++ b/scripts/deploy.sh
@@ -4,19 +4,19 @@
 BUCKET=$1
 LOG_FILE=deploy.log
 
-cd $BUILD_DIR
+cd $BUILD_DIR || exit
 
 for f in $(ls *.js); do
-  size=`wc -c < $f`
+  size=$(wc -c < "$f")
   printf "$f: $size bytes\n"
 done
 
 cat manifest.txt | grep version
 echo 'アップロード先: $BUCKET'
-name=$(echo $BUCKET)
+name=$(echo "$BUCKET")
 
 read -p "続けますか？ [y/N] " answer
-if [ $answer != "y" ]; then
+if [ "$answer" != "y" ]; then
   exit 1
 fi
```

バッククォートとクォートの付け忘れの修正は同じですが、`cd` と `read` の扱いが逆になりました。ShellCheckは `cd` に `|| exit` を付けますが、`read` に `-r` は付けません。ESLintは `read` に `-r` を付けますが、`cd` には `|| exit` を付けません。ESLintの `require-cd-guard` は、修正案を提示するだけのルール（エディタで選んで適用するもの）で、`--fix` では適用されないためです。

## shebangが `sh` のスクリプトの扱い

ShellCheckは、スクリプト先頭のshebang（`#!/bin/sh` など）を見てシェルの種類を判断します。ESLintはどうなのかを、Bashの書き方を含む `sh` のスクリプトで確かめます。

```bash:posix/p.sh
#!/bin/sh
if [[ -f a.txt ]]; then
  echo ok
fi
```

`[[ ]]` はBashの書き方で、POSIXの `sh` では定義されていません。

```bash
shellcheck -f gcc posix/p.sh
```

実行結果です。

```text
posix/p.sh:2:4: warning: In POSIX sh, [[ ]] is undefined. [SC3010]
```

ShellCheckはshebangから `sh` と判断して指摘しました。ESLintは、推奨設定のまま実行すると何も出ません。推奨設定はBashとして解析するため、`[[ ]]` は正しい書き方として扱われます。`@eslint/shell` のビルド済みのコード（`dist` 以下）を `#!` で検索しましたが、shebangからシェルの種類を選ぶ処理は見当たりませんでした。シェルの種類は、設定ファイルの `language` で決まります。

そこで、`language` を `shell/posix` にした設定ファイルも試しました。

```js:posix.config.js
import { defineConfig } from "eslint/config";
import shell from "@eslint/shell";

export default defineConfig([
  {
    plugins: { shell },
    extends: ["shell/recommended"],
    language: "shell/posix",
  },
]);
```

`-c` は、使う設定ファイルを指定するオプションです。

```bash
pnpm exec eslint -c posix.config.js posix/p.sh
```

こちらも何も出ず、終了コードは0でした。パーサーを直接呼んで、POSIXとして解析したときに `[[` がどう扱われるかを見てみます。`parseShell` はプラグインが公開しているパーサーの関数で、`variant` でシェルの種類を指定します。

```js:variant.js
import { parseShell } from "@eslint/shell";

for (const variant of ["bash", "posix"]) {
  const { ast } = parseShell("if [[ -f a.txt ]]; then echo ok; fi\n", { variant });
  const test = ast.body[0].test[0];
  console.log(variant, test.type, test.name?.parts[0].value ?? "");
}
```

```bash
node variant.js
```

実行結果です。

```text
bash TestCommand 
posix Command [[
```

Bashとして解析すると `[[ ]]` は条件式（`TestCommand`）になり、POSIXとして解析すると `[[` という名前の普通のコマンドになりました。POSIXでは `[[` はただのコマンド名として読まれるため、構文エラーにはなりません。SC3010のようにBashの書き方を指摘するルールもないため、`sh` 向けのスクリプトでBashの書き方が混ざっていないかを確かめたいときは、今のところShellCheckが必要です。

## 独自ルールを書いてみた

ここまでの比較だと、検出できる範囲はShellCheckの方が広いです。一方で、ESLintにはルールをJavaScriptで書いて追加できる仕組みがあります。ShellCheckの `--help` を見ても、自分でチェックを追加するオプションはなく、`-o` で有効にできるのは `--list-optional` に出てくる組み込みのチェックだけです。

そこで、チームのルールに当たるものを2つ書いてみます。

- `require-aws-profile`：`aws` コマンドに `--profile` か `AWS_PROFILE` を付ける（意図しないアカウントへの操作を防ぐ）
- `require-strict-mode`：スクリプトの先頭で `set -euo pipefail` を実行する

### 構文木を見る

ルールを書く前に、`aws` コマンドがどんな構文木になるかを見ておきます。公式ブログではESLint Code Explorerで構文木を確認できると紹介されていますが、ここでは `parseShell` で出力します。

```js:ast.js
import { parseShell } from "@eslint/shell";

const { ast } = parseShell("AWS_PROFILE=dev aws s3 ls\n");

// 位置情報（start / end）は省いて表示する
const omitPosition = (key, value) => (key === "start" || key === "end" ? undefined : value);
console.log(JSON.stringify(ast.body[0], omitPosition, 2));
```

```bash
node ast.js
```

実行結果です。

```json
{
  "type": "Command",
  "redirects": [],
  "negated": false,
  "background": false,
  "assignments": [
    {
      "type": "VariableAssignment",
      "name": {
        "type": "Identifier",
        "name": "AWS_PROFILE"
      },
      "index": null,
      "value": {
        "type": "Word",
        "parts": [
          {
            "type": "Literal",
            "value": "dev"
          }
        ]
      },
      "array": null,
      "append": false
    }
  ],
  "name": {
    "type": "Word",
    "parts": [
      {
        "type": "Literal",
        "value": "aws"
      }
    ]
  },
  "arguments": [
    {
      "type": "Word",
      "parts": [
        {
          "type": "Literal",
          "value": "s3"
        }
      ]
    },
    {
      "type": "Word",
      "parts": [
        {
          "type": "Literal",
          "value": "ls"
        }
      ]
    }
  ]
}
```

1つのコマンドが `Command` になり、コマンド名は `name`、引数は `arguments`、コマンドの前に書いた環境変数の代入は `assignments` に入っています。ルールでは `Command` を受け取って、これらを調べればよさそうです。

### ルールのコード

`aws` コマンドを調べるルールです。

```js:rules/require-aws-profile.js
// aws コマンドに --profile か AWS_PROFILE が付いているかを調べるルール
export default {
  meta: {
    type: "problem",
    messages: {
      missingProfile: "aws コマンドには --profile か AWS_PROFILE を付けてください",
    },
  },
  create(context) {
    const { sourceCode } = context;
    // 引用符を外した文字列を返す（"--profile" も --profile として扱う）
    const toText = (word) => sourceCode.getText(word).replace(/["']/g, "");

    return {
      Command(node) {
        if (!node.name || toText(node.name) !== "aws") {
          return;
        }
        // AWS_PROFILE=dev aws ... の形
        const hasEnv = node.assignments.some((assignment) => assignment.name?.name === "AWS_PROFILE");
        // aws ... --profile dev / --profile=dev の形
        const hasOption = node.arguments.some((arg) => {
          const text = toText(arg);
          return text === "--profile" || text.startsWith("--profile=");
        });
        if (!hasEnv && !hasOption) {
          context.report({ node, messageId: "missingProfile" });
        }
      },
    };
  },
};
```

`Word` の文字列は、`parts` の種類（`Literal` やダブルクォートの文字列など）ごとに持ち方が違います。プラグインの中には引用符を外して文字列を取り出す関数がありますが、パッケージからは公開されていないため、ここでは元のコードの文字列から引用符を取り除いています。

`set -euo pipefail` を調べるルールです。こちらは `--fix` で自動修正できるようにしました。

```js:rules/require-strict-mode.js
// スクリプトの先頭で set -euo pipefail しているかを調べるルール
export default {
  meta: {
    type: "problem",
    fixable: "code",
    messages: {
      missingStrictMode: "スクリプトの先頭で set -euo pipefail を実行してください",
    },
  },
  create(context) {
    const { sourceCode } = context;

    const isStrictMode = (statement) => {
      if (statement.type !== "Command" || !statement.name) {
        return false;
      }
      if (sourceCode.getText(statement.name) !== "set") {
        return false;
      }
      const args = statement.arguments.map((arg) => sourceCode.getText(arg));
      const flags = args.filter((arg) => arg.startsWith("-")).join("");
      return flags.includes("e") && flags.includes("u") && args.includes("pipefail");
    };

    return {
      Program(node) {
        const first = node.body[0];
        if (!first || isStrictMode(first)) {
          return;
        }
        context.report({
          node: first,
          messageId: "missingStrictMode",
          // 最初の文の前に set -euo pipefail を差し込む
          fix: (fixer) => fixer.insertTextBefore(first, "set -euo pipefail\n\n"),
        });
      },
    };
  },
};
```

コメントは構文木に含まれず `Program` の `comments` に入るため、`node.body[0]` はshebangやコメントを除いた最初の文になります。

設定ファイルに、2つのルールを `local` という名前のプラグインとして追加します。

```js:eslint.config.js
import { defineConfig } from "eslint/config";
import shell from "@eslint/shell";
import requireAwsProfile from "./rules/require-aws-profile.js"; // 追加
import requireStrictMode from "./rules/require-strict-mode.js"; // 追加

export default defineConfig([
  {
    plugins: { shell },
    extends: ["shell/recommended"],
  },
  // 追加
  {
    files: ["**/*.sh"],
    plugins: {
      local: {
        rules: {
          "require-aws-profile": requireAwsProfile,
          "require-strict-mode": requireStrictMode,
        },
      },
    },
    rules: {
      "local/require-aws-profile": "error",
      "local/require-strict-mode": "error",
    },
  },
]);
```

### 動かしてみる

次のスクリプトにかけます。1つ目の `aws` には `--profile`、2つ目には `AWS_PROFILE` を付け、3つ目の `$(...)` の中の `aws` には何も付けていません。

```bash:custom/release.sh
#!/bin/bash
# 成果物を S3 に上げて CloudFront のキャッシュを消す
BUCKET="my-app-assets"
DISTRIBUTION_ID="E1234567890ABC"

aws s3 sync ./dist "s3://${BUCKET}/" --profile dev
AWS_PROFILE=dev aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*"
account=$(aws sts get-caller-identity --query Account --output text)
echo "account: ${account}"
```

```bash
pnpm exec eslint custom/release.sh
```

実行結果です。

```text
/path/to/eslint-shell-check/custom/release.sh
  3:1   error  スクリプトの先頭で set -euo pipefail を実行してください        local/require-strict-mode
  8:11  error  aws コマンドには --profile か AWS_PROFILE を付けてください  local/require-aws-profile

✖ 2 problems (2 errors, 0 warnings)
  1 error and 0 warnings potentially fixable with the `--fix` option.
```

`set -euo pipefail` がないことと、`$(...)` の中の `aws` に `--profile` がないことを指摘できました。コマンド置換の中のコマンドも `Command` として走査されるため、ルール側で特別に扱う必要はありませんでした。同じスクリプトにShellCheckをかけると、何も出ません。

`--fix` で修正します。

```bash
pnpm exec eslint --fix custom/release.sh
```

修正前との差分です。

```diff
 #!/bin/bash
 # 成果物を S3 に上げて CloudFront のキャッシュを消す
+set -euo pipefail
+
 BUCKET="my-app-assets"
 DISTRIBUTION_ID="E1234567890ABC"
```

コメントの直後に `set -euo pipefail` が入りました。

### 今回のルールで拾えない書き方

今回のルールは最小限の実装のため、次の書き方には対応していません。

- `require-aws-profile`：スクリプトの冒頭で `export AWS_PROFILE=dev` してから `aws` を実行すると、誤って指摘します（試したところ、指摘されました）。`sudo aws` や `/usr/local/bin/aws` のような呼び方は見ていません
- `require-strict-mode`：最初の文しか見ていないため、`set -e` と `set -u` を別の行に書いた場合や、`set -o errexit` のような長い書き方は誤って指摘します

実際のチームで使うなら、こうした書き方をどこまで許すかを決めてから作り込むことになりそうです。

## まとめ

`@eslint/shell` のルールはShellCheckのチェックに対応していますが、同じスクリプトにかけると、ShellCheckは代入した値を見て安全と分かる変数はクォートがなくても指摘せず、ESLintは代入した値を見ずに指摘しました。自動修正も、`cd` の `|| exit` はShellCheckだけ、`read -r` はESLintだけが入れるという違いがありました。ルールが10個の今は、`rm -rf "$VAR/"*` のような危ない書き方やBashの書き方が `sh` に混ざっているかはShellCheckでしか拾えないため、置き換えるよりは併用することになりそうです。

今回試してみて一番面白かったのは、シェルスクリプトのルールをJavaScriptで書けることでした。構文木が `Command` や `Word` のように素直な形をしているため、`aws` に `--profile` を付けるといったチーム独自の決まりを、数十行で書けました。ShellCheckでは追加できない部分を、ESLintで補えます。

私と同じように、JavaScriptのプロジェクトでシェルスクリプトも抱えている方の参考になれば嬉しいです。

## 参考

- [ESLint now officially supports linting of shell scripts - ESLint](https://eslint.org/blog/2026/11/eslint-shell-plugin-announcement/)
- [eslint/shell - GitHub](https://github.com/eslint/shell)
- [Shell Syntax Tree Format - eslint/shell](https://github.com/eslint/shell/blob/main/docs/syntax-tree.md)
- [mvdan/sh - GitHub](https://github.com/mvdan/sh)
- [ShellCheck](https://www.shellcheck.net)
- [Custom Rules - ESLint](https://eslint.org/docs/latest/extend/custom-rules)
