人材育成室 育成メンバーチームで 研修中の はす です。

私は普段よく、`TypeScript` を使って開発をしているのですが、`tsc` を実行した時に、裏側で何をしているかはあまり理解できていませんでした。型チェックが通った・通らなかったという結果はみますが、その過程でコンパイラがどのような処理や、データ構造を扱っているかを覗いたことがある人は少ないのではないでしょうか。

そこで今回は、`tsc --generateTrace` と `Compiler API` を使って、TypeScript コンパイラが内部で生成する「型オブジェクト」を覗いてみたいと思います。

## ざっくり 型チェッカーがやっていること

例えば、以下のようなコードがあったとします。

```typescript
interface User {
  name: string;
  age: number;
}

const user: User = { name: "taro", age: 25 };
```

この場合、コンパイラは `User` インターフェースと `{ name: "taro", age: 25 }` のオブジェクトリテラルそれぞれに対して型オブジェクトを生成し、両者のプロパティを比較して代入可能かどうかを判定しています。

型オブジェクトとは、`tsc` が型チェックを行う過程でコンパイラのメモリ内に作られるデータ構造で、コンパイル結果の `JavaScript` には含まれません。

## `--generateTrace` で型オブジェクトを覗いてみる

では、実際の型オブジェクトを見るために、`tsc --generateTrace` を実行してみます。

```bash
tsc --generateTrace ./trace-output
```

対象コードは以下です。

```typescript
interface User {
  name: string;
  age: number;
  email: string;
}

interface Admin extends User {
  role: "admin" | "superadmin";
  permissions: string[];
}

const user: User = { name: "hasuto", age: 25, email: "hasuto@example.com" };

type IsString<T> = T extends string ? "yes" : "no";
type Result1 = IsString<"hello">;
type Result2 = IsString<42>;
```

すると、`trace.json` と `types.json` の二つが生成されます。
`trace.json` は、コンパイラの処理の流れを記録したもので、`types.json` は、生成された型オブジェクトの情報が記録されたものです。

今回は、型オブジェクトの方に注目します。
全部を見ると量が多すぎるため、最初の方だけ見てみます。

```json
[
  { "id": 1, "intrinsicName": "any", "recursionId": 0, "flags": ["Any"] },
  { "id": 2, "intrinsicName": "any", "recursionId": 1, "flags": ["Any"] },
  { "id": 3, "intrinsicName": "any", "recursionId": 2, "flags": ["Any"] },
  { "id": 4, "intrinsicName": "any", "recursionId": 3, "flags": ["Any"] },
  { "id": 5, "intrinsicName": "error", "recursionId": 4, "flags": ["Any"] },
  {
    "id": 6,
    "intrinsicName": "unresolved",
    "recursionId": 5,
    "flags": ["Any"]
  },
  { "id": 7, "intrinsicName": "any", "recursionId": 6, "flags": ["Any"] },
  { "id": 8, "intrinsicName": "intrinsic", "recursionId": 7, "flags": ["Any"] },
  {
    "id": 9,
    "intrinsicName": "unknown",
    "recursionId": 8,
    "flags": ["Unknown"]
  },
  {
    "id": 10,
    "intrinsicName": "undefined",
    "recursionId": 9,
    "flags": ["Undefined"]
  },
  {
    "id": 11,
    "intrinsicName": "undefined",
    "recursionId": 10,
    "flags": ["Undefined"]
  },
  {
    "id": 12,
    "intrinsicName": "undefined",
    "recursionId": 11,
    "flags": ["Undefined"]
  },
  { "id": 13, "intrinsicName": "null", "recursionId": 12, "flags": ["Null"] },
  {
    "id": 14,
    "intrinsicName": "string",
    "recursionId": 13,
    "flags": ["String"]
  },
  {
    "id": 15,
    "intrinsicName": "number",
    "recursionId": 14,
    "flags": ["Number"]
  }
]
```

### 組み込みプリミティブ型

最初の方に並んでいるのは、TypeScript 組み込みプリミティブ型です。コンパイラが起動した時点で作られるベースの型たちです。

- id 1-8: `any` のバリエーション
- id 9: `unknown`
- id 10-12: `undefined` (用途別に複数ある)
- id 13: `null`
- id 14: `string`
- id 15: `number`

このように、自分が書いたコードとは関係なく、コンパイラが起動した時点で生成される型オブジェクトがあるということがわかります。

### lib 指定による型オブジェクトの数の違い

あとは、ファイル全体で型オブジェクトが何個生成されたかもみてみます。

```bash
tail -5 trace-output/types.json
```

```json
{"id":14297,"symbolName":"IsString","recursionId":12394,"aliasTypeArguments":[14296],"conditionalCheckType":14296,"conditionalExtendsType":14,"conditionalTrueType":-1,"conditionalFalseType":-1,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":32,"character":2},"end":{"line":35,"character":52}},"flags":["Conditional","IncludesEmptyObject"]},
{"id":14298,"recursionId":12395,"flags":["StringLiteral"],"display":"\"yes\""},
{"id":14299,"recursionId":12396,"flags":["StringLiteral"],"display":"\"yes\""},
{"id":14300,"recursionId":12397,"flags":["StringLiteral"],"display":"\"no\""},
{"id":14301,"recursionId":12398,"flags":["StringLiteral"],"display":"\"no\""}]
```

実際に書いたコードは、20行程度なのに対して、なんと14,301個の型オブジェクトが生成されています。

何がそんなにあるのかというと、`tsconfig.json` で `lib` を指定しなかったため、コンパイラはデフォルトでDOMの型定義やES標準ライブラリを全部読んでいます。
`document.querySelector` 、`HTMLElement`、`Promise` などのブラウザ組み込みAPIの方が膨大にあります。

では、`lib` を指定するとどうなるかみてみます。

```json
{
  "compilerOptions": {
    "lib": ["es2020"]
  }
}
```

```bash
tail -5 trace-output/types.json

{"id":3110,"symbolName":"IsString","recursionId":2105,"aliasTypeArguments":[3109],"conditionalCheckType":3109,"conditionalExtendsType":14,"conditionalTrueType":-1,"conditionalFalseType":-1,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":32,"character":2},"end":{"line":35,"character":52}},"flags":["Conditional","IncludesEmptyObject"]},
{"id":3111,"recursionId":2106,"flags":["StringLiteral"],"display":"\"yes\""},
{"id":3112,"recursionId":2107,"flags":["StringLiteral"],"display":"\"yes\""},
{"id":3113,"recursionId":2108,"flags":["StringLiteral"],"display":"\"no\""},
{"id":3114,"recursionId":2109,"flags":["StringLiteral"],"display":"\"no\""}]
```

すると、型オブジェクトの数が3,000個程度に減りました。

比較
| 設定 | 型オブジェクトの数 |
| --- | --- |
| lib: 未指定 | 約14,300個 |
| lib: ["es2020"] | 約3,100個 |

lib を未指定にすると、デフォルトでライブラリセットが自動的に読み込まれますが、`lib: ["es2020"]` と指定することで、ES2020の標準ライブラリだけに絞ることができます。
デフォルトでは、DOMの型定義等も含まれているため、型オブジェクトの差が大きくなります。

本当にDOMの型定義が含まれていないかを確認してみます。

```bash
$ grep -c "HTMLElement\|Document\|Window" trace-output/types.json

0
```

0 になっているため、DOMの型定義は含まれていないことがわかります。

逆に、lib を指定しない場合は、DOMの型定義が含まれているかを確認してみます。

```bash
$ grep -c "HTMLElement\|Document\|Window" trace-output/types.json

519
```

519 になっているため、DOMの型定義が多く含まれていることがわかります。

### 自分が書いたコードの型オブジェクトを探す

ここからは、自分が書いたコードに対応する型オブジェクトを探してみます。

**lib: ["es2020"] の状態**

```bash
$ grep -n '"User"\|"Admin"\|"IsString"' trace-output/types.json
```

```bash
3079:{"id":3079,"symbolName":"User","recursionId":2075,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":1,"character":1},"end":{"line":5,"character":2}},"flags":["Object"]},
3080:{"id":3080,"symbolName":"Admin","recursionId":2076,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":5,"character":2},"end":{"line":10,"character":2}},"flags":["Object"]},
3094:{"id":3094,"symbolName":"IsString","recursionId":2090,"aliasTypeArguments":[3093],"conditionalCheckType":3093,"conditionalExtendsType":14,"conditionalTrueType":-1,"conditionalFalseType":-1,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":12,"character":77},"end":{"line":14,"character":52}},"flags":["Conditional","IncludesEmptyObject"]},
```

**id:3079** が `User` インターフェースに対応する型オブジェクトということがわかったので抽出してみます。

```json
{
  "id": 3079,
  "symbolName": "User",
  "recursionId": 2075,
  "firstDeclaration": {
    "path": "/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts",
    "start": { "line": 1, "character": 1 },
    "end": { "line": 5, "character": 2 }
  },
  "flags": ["Object"]
}
```

- **id: 3079**
  これは、 3,114個中の3,079個目ということは、コンパイラはES標準ライブラリの約3000個の型を先に処理してから、私の書いたコードの型を処理していることになります。

- **symbolName: "User"**
  ソースコード上のシンボル名に対応しています。

- **recursionId: 2075**
  再帰的な型解決時にループを検出するための内部的なIDです。

- **flags:["Object"]**
  TypeScript の内部では、`interface` 専用のフラグではなく、`Object` フラグで表現されています。

- **firstDeclaration**
  これは、ソースコードのどこで宣言されたかの位置情報です。

続いて、先ほどの結果に含まれていた、**IsString** も追加でみてみます。

```json
{
  "id": 3094,
  "symbolName": "IsString",
  "recursionId": 2090,
  "aliasTypeArguments": [3093],
  "conditionalCheckType": 3093,
  "conditionalExtendsType": 14,
  "conditionalTrueType": -1,
  "conditionalFalseType": -1,
  "firstDeclaration": {
    "path": "/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts",
    "start": { "line": 12, "character": 77 },
    "end": { "line": 14, "character": 52 }
  },
  "flags": ["Conditional", "IncludesEmptyObject"]
}
```

`conditionalExtendsType: 14` に注目です。id:14 は、先ほど `types.json` の先頭で見た　id:14 = string への参照です。
つまり、`IsString<T> = T extends string ? "yes" : "no"` の string の部分が id:14 の型オブジェクトを直接指していることがわかります。

これは、型オブジェクト同士が **id** で参照しあっていることを意味しています。

ここで一つ気になることがあります。
`User` 型オブジェクトの `name:string` や `age:number` というプロパティ情報はどこにあるのでしょうか。

探してみます。

先ほどの `grep` で `User` が id:3079 だとわかったので、その周辺の id:3079〜3095あたりを見てみます。

```bash
$ sed -n '3079,3095p' trace-output/types.json

{"id":3079,"symbolName":"User","recursionId":2075,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":1,"character":1},"end":{"line":5,"character":2}},"flags":["Object"]},
{"id":3080,"symbolName":"Admin","recursionId":2076,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":5,"character":2},"end":{"line":10,"character":2}},"flags":["Object"]},
{"id":3081,"recursionId":2077,"flags":["StringLiteral"],"display":"\"admin\""},
{"id":3082,"recursionId":2078,"flags":["StringLiteral"],"display":"\"admin\""},
{"id":3083,"recursionId":2079,"flags":["StringLiteral"],"display":"\"superadmin\""},
{"id":3084,"recursionId":2080,"flags":["StringLiteral"],"display":"\"superadmin\""},
{"id":3085,"recursionId":2081,"unionTypes":[3081,3083],"flags":["Union"]},
{"id":3086,"recursionId":2082,"flags":["StringLiteral"],"display":"\"hasuto\""},
{"id":3087,"recursionId":2083,"flags":["StringLiteral"],"display":"\"hasuto\""},
{"id":3088,"recursionId":2084,"flags":["NumberLiteral"],"display":"25"},
{"id":3089,"recursionId":2085,"flags":["NumberLiteral"],"display":"25"},
{"id":3090,"recursionId":2086,"flags":["StringLiteral"],"display":"\"hasuto@example.com\""},
{"id":3091,"recursionId":2087,"flags":["StringLiteral"],"display":"\"hasuto@example.com\""},
{"id":3092,"symbolName":"__object","recursionId":2088,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":12,"character":19},"end":{"line":12,"character":76}},"flags":["Object"],"display":"{ name: string; age: number; email: string; }"},
{"id":3093,"symbolName":"T","recursionId":2089,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":14,"character":15},"end":{"line":14,"character":16}},"flags":["TypeParameter","IncludesMissingType"]},
{"id":3094,"symbolName":"IsString","recursionId":2090,"aliasTypeArguments":[3093],"conditionalCheckType":3093,"conditionalExtendsType":14,"conditionalTrueType":-1,"conditionalFalseType":-1,"firstDeclaration":{"path":"/users/sasaki.hasuto/develop/ts-engine-lab/src/sample.ts","start":{"line":12,"character":77},"end":{"line":14,"character":52}},"flags":["Conditional","IncludesEmptyObject"]},
{"id":3095,"recursionId":2091,"flags":["StringLiteral"],"display":"\"hello\""},
```

すると、**id:3092** に `__object` という名前で、`{ name: string; age: number; email: string; }` という表示の型オブジェクトがあることがわかります。
この型オブジェクトが、`User` 型オブジェクトのプロパティ情報を持っているだろうという予想ができます。

`--generateTrace` はパフォーマンスのボトルネックを特定するためのもので、型オブジェクトの構造を完全に出力するものではないため、`__object` 型オブジェクトの中身まではわかりませんでした。

なので、`Compiler API ` を使って、型オブジェクトの構造を直接見てみます。

## Compiler API で型の中身を見る

以下のようなコードを書いて、型オブジェクトの構造を直接見てみます。

```typescript
const ts = require("typescript");

const program = ts.createProgram(["src/sample.ts"], {
  strict: true,
  noEmit: true,
  lib: ["lib.es2020.d.ts"],
});

const checker = program.getTypeChecker();
const source = program.getSourceFile("src/sample.ts");

ts.forEachChild(source, (node) => {
  if (ts.isInterfaceDeclaration(node)) {
    const type = checker.getTypeAtLocation(node);
    const symbol = type.getSymbol();

    console.log(`\n--- ${symbol.getName()} ---`);
    console.log(`  flags: ${type.flags}`);
    console.log(`  symbol.name: ${symbol.getName()}`);
    console.log(`  properties:`);

    for (const prop of type.getProperties()) {
      const propType = checker.getTypeOfSymbolAtLocation(prop, node);
      console.log(`    - ${prop.getName()}: ${checker.typeToString(propType)}`);
    }
  }
});
```

**ts.createProgram** は、`tsc` を実行したときと同じコンパイラエンジンを起動します。第一引数に、コンパイル対象のファイルを指定し、第二引数にコンパイラオプションを指定します。

**getTypeChecker** は、型チェッカーを取得します。
**getSourceFile** は、パース済みのAST（抽象構文木）を返します。
**forEachChild** は、ASTのトップレベルのノードを一つずつ見ていきます。`sample.ts` のトップレベルには、`interface User`, `interface Admin`, `const user`, `type IsString` などがあるので、それぞれのノードを見ていきます。
**isInterfaceDeclaration** で、そのノードが `interface` 宣言かどうかを判定します。今回は、`User` と `Admin` だけが該当します。

```bash
$ node ./scripts/dump-type.js

--- User ---
  flags: 1048576
  symbol.name: User
  properties:
    - name: string
    - age: number
    - email: string

--- Admin ---
  flags: 1048576
  symbol.name: Admin
  properties:
    - role: "admin" | "superadmin"
    - permissions: string[]
    - name: string
    - age: number
    - email: string
```

`User` と `Admin` の型オブジェクトの構造を直接見ることができました。

ここまでで、実際の型オブジェクトの構造を見ることができたので、次は、型オブジェクトがどのように生成されているのかを追ってみます。

##　checker.ts を軽く読んでみる

型オブジェクトの生成ロジックを追うために、`checker.ts` を軽く読んでみます。

ブラウザ上では、ファイルサイズが大きすぎて見れないので、ローカルにクローンしてきて、`src/compiler/checker.ts` を見てみます。

```bash
$ git clone https://github.com/microsoft/TypeScript.git
```

クローンしてきたら、`src/compiler/checker.ts` を開いてみます。

![スクリーンショット 2026-02-23 9.19.10](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1771882684/2026/02/24/bprtxpzpgq5skiypvz3u.png)

何と、54420行もありました。
ここから、型オブジェクト生成に関係する部分を見ていきます。

### createType (L5517) v6.0.0-beta 時点

createType は最も根本的な部分で、すべての型オブジェクトはこの関数を通して生成されます。
typeCount++ でインクリメントされる 連番が、types.json の id に対応しています。つまり id の順番は createType が呼ばれた順番ということになります。

```typescript
function createType(flags: TypeFlags): Type {
  const result = new Type(checker, flags);
  typeCount++;
  result.id = typeCount;
  tracing?.recordType(result);
  return result;
}
```

### 組み込みプリミティブ型の生成

続いて、組み込みプリミティブ型の生成部分も見てみます。
以下のように、`any` や `error` などの型オブジェクトが、コンパイラ起動時に生成されていることがわかります。

```typescript
var anyType = createIntrinsicType(TypeFlags.Any, "any");
var autoType = createIntrinsicType(
  TypeFlags.Any,
  "any",
  ObjectFlags.NonInferrableType,
  "auto",
);
var wildcardType = createIntrinsicType(
  TypeFlags.Any,
  "any",
  /*objectFlags*/ undefined,
  "wildcard",
);
var blockedStringType = createIntrinsicType(
  TypeFlags.Any,
  "any",
  /*objectFlags*/ undefined,
  "blocked string",
);
var errorType = createIntrinsicType(TypeFlags.Any, "error");
var unresolvedType = createIntrinsicType(TypeFlags.Any, "unresolved");
// ... 省略
```

中途半端になってしまいますが、これ以上 checker.ts に入ると、量が多くなりすぎるので、今回はここまでにします。

## まとめ

今回の検証では、`--generateTrace` と `Compiler API` を使って、型オブジェクトの構造や生成の流れを見ることができました。
たった20行程度のコードでも、14,000 個以上の型オブジェクトが生成されているのは驚きでした。lib を指定することで、生成される型オブジェクトの数が大幅に減ることがわかりました。

パフォーマンスの観点では、2026年2月にリリースされた TypeScript 6.0 Beta で、`types` の デフォルトが空配列 `[]` に変更され、公式のブログによると、`types` を適切に設定するだけで、ビルド時間が 20 〜 50% 改善したプロジェクトもあるとのことです。

[公式のブログ](https://devblogs.microsoft.com/typescript/announcing-typescript-6-0-beta/#types-now-defaults-to-[])

今回検証した、`lib` と `types` は対象が異なりますが（`lib` はランタイムAPIの型定義、`types` は `@types/*` パッケージの自動取り込みを制御）、どちらも型オブジェクトの数に大きく影響することが考えられます。

次回は、今回深く見れなかった、`types` オプションの影響や、checker.ts の型オブジェクトの生成ロジックを見てみたいと思います。

## 参考

[TypeScript/src/compiler/checker.ts at main · microsoft/TypeScript · GitHub](https://github.com/microsoft/TypeScript/blob/main/src/compiler/checker.ts)

[Performance Tracing · microsoft/TypeScript Wiki · GitHub](https://github.com/microsoft/TypeScript/wiki/Performance-Tracing)

[Progress on TypeScript 7 - December 2025 - TypeScript](https://devblogs.microsoft.com/typescript/progress-on-typescript-7-december-2025/)

[Announcing TypeScript 6.0 Beta - TypeScript](https://devblogs.microsoft.com/typescript/announcing-typescript-6-0-beta/#types-now-defaults-to-[])

[TypeScript/src/compiler/tracing.ts at main · microsoft/TypeScript · GitHub](https://github.com/microsoft/TypeScript/blob/main/src/compiler/tracing.ts)
