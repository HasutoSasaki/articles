# LanceDB でベクトル検索の仕組みを触ってみた

こんにちは 人材育成室 育成メンバーチームで 研修中の はすと です。

最近、仕様書や要件ドキュメントを NotebookLM に入れて質問するようにしたところ、意味的に近い情報を拾い上げてくれて、欲しい回答が返ってくるようになりました。「この仕組みをローカルで再現できないか」と思って調べていたところ、LanceDB というベクトルDB を知りました。

本記事では、LanceDB を使ってベクトル検索の基礎を動かした結果と、その過程で理解した仕組みをまとめます。

## LanceDB とは

[LanceDB](https://docs.lancedb.com/) は、アプリに組み込んで使えるオープンソースのベクトルデータベースです。SQLite のように別途サーバーを立てる必要がなく、ファイルシステム上に直接データを保存します。独自の列指向フォーマット「Lance」の上に構築されており、ベクトルデータだけでなくテキスト・画像・動画といったマルチモーダルなデータも同じテーブルで扱えます。

### 主な特徴

| 特徴 | 内容 |
|---|---|
| 組み込み型（Embedded） | アプリと同じプロセス内で動く。別途 DB サーバーの起動不要 |
| 検索の種類 | ベクトル検索・全文検索・ハイブリッド検索・SQL に対応 |
| Lance フォーマット | 独自の列指向フォーマット（オープンソース）によるストレージ |
| 自動バージョニング | テーブルのバージョン管理とスキーマ変更の履歴が自動で記録される |
| マルチモーダル | テキスト・画像・動画など異種データを同じテーブルで管理（※） |
| 言語対応 | Python・TypeScript・Rust |
| ライセンス | Apache 2.0 |

### 他の主要ベクトルDB との比較

以下は各 DB の公式サイト・GitHub から確認した情報です。

| DB | 形態 | ライセンス | 向いているケース |
|---|---|---|---|
| **LanceDB** | 組み込み型・OSS | Apache 2.0 | マルチモーダルデータの管理・ローカル〜クラウドまで対応 |
| Chroma | 組み込み型・OSS | Apache 2.0 | ローカル・セルフホスト・クラウドまで段階的に対応 |
| Qdrant | サーバー型・OSS | Apache 2.0 | 本番環境でのセマンティック検索・AI アプリ |
| Weaviate | サーバー型・OSS | BSD-3-Clause | セマンティック検索・RAG・AI エージェントワークフロー |
| Pinecone | フルマネージド Cloud・非 OSS | 非公開 | インフラ運用なしで使いたい場合 |
| pgvector | PostgreSQL 拡張・OSS | PostgreSQL License | 既存の PostgreSQL 環境に追加する場合 |

※ マルチモーダルについて補足すると、LanceDB 自体はベクトルの保存と検索を担うだけです。テキストも画像も「ベクトルに変換してから渡す」という点は変わらず、変換を担うのは OpenCLIP や ImageBind といった外部の埋め込みモデルです。LanceDB はそれらのモデルと組み合わせることを前提に設計されています。

本記事では LanceDB OSS をローカルで動かします。JavaScript SDK は `@lancedb/lancedb` パッケージで提供されています。

## ベクトルとは何か

LanceDB を動かす前に、「ベクトル」が何を表しているのかを整理します。

サンプルコードには次のようなデータが登場します。

```typescript
const data = [
  { id: "1", text: "dog",  vector: [0.8, 0.9, 0.7] },
  { id: "2", text: "cat",  vector: [0.6, 0.8, 0.5] },
  { id: "3", text: "wolf", vector: [0.9, 0.2, 0.8] },
  { id: "4", text: "fish", vector: [0.1, 0.2, 0.2] },
];
```

`vector` の数値は「dog というテキストが意味的にどういう性質を持つか」を数値で表したものです。同時に、多次元空間上の座標（位置）でもあります。「意味の表現」と「空間上の位置」は同じものを指しています。

- dog `[0.8, 0.9, 0.7]` と cat `[0.6, 0.8, 0.5]` は数値が近い → どちらもペット系で意味的に近い
- fish `[0.1, 0.2, 0.2]` は大きく離れている → 性質が大きく違う

このサンプルのベクトルは説明のために手動で割り当てた仮の値です。実際のユースケースでは、OpenAI Embeddings API などの埋め込みモデルがテキストから自動で生成します。

## 実際に動かしてみた

### セットアップ

```bash
pnpm add @lancedb/lancedb
```

`package.json` に `"type": "module"` が必要です。

### テーブルへのデータ保存

```typescript
import * as lancedb from "@lancedb/lancedb";

const db = await lancedb.connect("sample-lancedb"); // ローカルディレクトリに接続

const data = [
  { id: "1", text: "dog",  vector: [0.8, 0.9, 0.7] },
  { id: "2", text: "cat",  vector: [0.6, 0.8, 0.5] },
  { id: "3", text: "wolf", vector: [0.9, 0.2, 0.8] },
  { id: "4", text: "fish", vector: [0.1, 0.2, 0.2] },
];

const table = await db.createTable("animals", data, { mode: "overwrite" });
```

実行後、`sample-lancedb/animals.lance` というディレクトリが生成されます。中を見ると以下の構成になっています。

```
sample-lancedb/animals.lance/
├── data/          # 実際のデータ（バイナリ列形式）
├── _versions/     # 自動バージョニングの履歴
└── _transactions/ # 更新のトランザクションログ
```

バイナリ形式なので直接は読めませんが、LanceDB の API 経由で中身を取り出せます。

```typescript
const table = await db.openTable("animals");
const rows = await table.query().toArray();
console.log(JSON.stringify(rows, null, 2));
// [
//   { "id": "1", "text": "dog",  "vector": [0.8, 0.9, 0.7] },
//   { "id": "2", "text": "cat",  "vector": [0.6, 0.8, 0.5] },
//   { "id": "3", "text": "wolf", "vector": [0.9, 0.2, 0.8] },
//   { "id": "4", "text": "fish", "vector": [0.1, 0.2, 0.2] }
// ]
```

`text`（元テキスト）と `vector`（索引）がセットで保存されている点が重要です。

### ベクトル検索

```typescript
// このクエリベクトルは「探したい特徴」を手動で指定した数値。単語ではない
const queryVector = [0.9, 0.9, 0.8];
const results = await table.search(queryVector).limit(2).toArray();

console.log(results);
// [
//   { id: '1', text: 'dog', vector: [0.8, 0.9, 0.7], _distance: 0.02 },
//   { id: '2', text: 'cat', vector: [0.6, 0.8, 0.5], _distance: 0.19 }
// ]
```

dog が1位、cat が2位で返ってきました。なお、テキストをそのままクエリにする方法は後述の Ollama セクションで扱います。

## ベクトル検索の仕組み

LanceDB のデフォルト距離指標は L2 で、`_distance` には各次元の差の二乗和が返されます。値が小さいほど近い（似ている）という判断です。

```
クエリ: [0.9, 0.9, 0.8]

_distance = (x1-x2)² + (y1-y2)² + (z1-z2)²

dog  [0.8, 0.9, 0.7]: (0.01 +  0.00 + 0.01) = 0.02  ← 1位（実行結果と一致）
cat  [0.6, 0.8, 0.5]: (0.09 +  0.01 + 0.09) = 0.19  ← 2位
wolf [0.9, 0.2, 0.8]: (0.00 +  0.49 + 0.00) = 0.49
fish [0.1, 0.2, 0.2]: (0.64 +  0.49 + 0.36) = 1.49
```

wolf が離れている原因を見ると、2番目の次元の差が `0.49`（= 0.7²）と突出して大きくなっています。クエリの2番目の次元は `0.9` ですが、wolf は `0.2` と大きく離れています。dog・cat はともに `0.9`・`0.8` と近いため、この次元での差が小さくなっています。

このように、ベクトル検索は全次元の差を同時に考慮して最も近い順に返します。どの次元が大きく離れているかによって、結果の順序が変わります。

## 埋め込みモデルとの組み合わせ

このサンプルはベクトルを手動で割り当てていますが、実際は埋め込みモデル（Embedding Model）に文字列を渡して自動生成します。

```typescript
// OpenAI の場合のイメージ
const response = await openai.embeddings.create({
  model: "text-embedding-3-small",
  input: "dog",
});
const vector = response.data[0].embedding; // 1536次元の数値配列
```

埋め込みモデルは、大量のテキストを使って「ある単語の周辺にどんな単語が出やすいか」を繰り返し予測することで学習します。「dog」も「cat」も「pet」「animal」「feed」といった単語と一緒に登場しやすいため、学習を経るうちにベクトルが自然に近い位置へ収束していきます。

「dog と cat は似ている」という正解をあらかじめ人間が与えているわけではなく、大量のテキストの統計的なパターンから自然に生まれる関係性です。

また、モデルは単語を辞書で照合するのではなく、文字列をサブワード（部分文字列）単位に分割してニューラルネットで処理します。そのため、学習データに含まれない固有名詞や造語でも何らかのベクトルが返ってきます。

## Ollama でローカル埋め込みを試してみた

API キーなしで本物の埋め込みを試すために、ローカルで LLM を動かせる [Ollama](https://ollama.com/) を使います。Ollama には埋め込み専用モデルも用意されており、`nomic-embed-text`（274MB）が手軽です。

```bash
ollama pull nomic-embed-text
```

Ollama は REST API を `localhost:11434` で提供しており（[公式 API ドキュメント](https://github.com/ollama/ollama/blob/main/docs/api.md)）、追加パッケージなしに `fetch()` で呼べます。

```typescript
import * as lancedb from "@lancedb/lancedb";

async function embed(texts: string[]): Promise<number[][]> {
  const response = await fetch("http://localhost:11434/api/embed", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: "nomic-embed-text", input: texts }),
  });
  const json = (await response.json()) as { embeddings: number[][] };
  return json.embeddings;
}

const words = ["dog", "cat", "wolf", "fish"];
const vectors = await embed(words);

// 手動の [0.8, 0.9, 0.7] の代わりにモデルが返したベクトルを入れる
const data = words.map((text, i) => ({
  id: i + 1,
  text,
  vector: vectors[i],
}));

const db = await lancedb.connect("sample-lancedb-ollama");
const table = await db.createTable("animals", data, { mode: "overwrite" });

// クエリも同じモデルでベクトル化してから検索
const queryText = "domestic pet animal";
const [queryVector] = await embed([queryText]);

const results = await table.search(queryVector).limit(2).toArray();

console.log(`クエリ: "${queryText}"`);
console.log("検索結果:");
results.forEach((r) =>
  console.log(` - ${r.text} (距離: ${r._distance?.toFixed(4)})`)
);
```

実行結果です。

```
クエリ: "domestic pet animal"
検索結果:
 - dog (距離: 0.4019)
 - cat (距離: 0.7591)
```

「domestic pet animal」に対して dog → cat の順で返ってきました。wolf や fish より飼育動物として近いと判断されています。

保存されたデータを API で取り出すと、手動ベクトルとは違い768次元の数値が格納されているのが確認できます。

```typescript
const table = await db.openTable("animals");
const rows = await table.query().toArray();
rows.forEach(r => {
  const vec = Array.from(r.vector);
  console.log(`${r.text}: [${vec.slice(0, 4).map(v => v.toFixed(4))}... (${vec.length}次元)]`);
});
// dog:  [ 0.0028, -0.0114, -0.1613, -0.0433... (768次元)]
// cat:  [ 0.0317,  0.0623, -0.1355, -0.0382... (768次元)]
// wolf: [ 0.0090, -0.0430, -0.1768,  0.0167... (768次元)]
// fish: [-0.0132,  0.0536, -0.1657, -0.0260... (768次元)]
```

手動で割り当てた `[0.8, 0.9, 0.7]` のような直感的な数値とは異なり、モデルが生成したベクトルは人間には解釈できない値が並びます。それでも LanceDB は同じ距離計算でベクトル間の近さを判断しています。

手動ベクトルと違い、クエリがテキストのまま書けます。ベクトルへの変換は `embed()` が担っており、**LanceDB 側の検索ロジックは何も変わっていない**のがポイントです。`nomic-embed-text` が返すベクトルは768次元ですが、LanceDB は次元数に関係なく同じ距離計算で動作します。

## モデルを変えると何が変わるか

Ollama を触っていて、ふと「別のモデルに変えたら何が変わるんだろう？」と気になったので調べてみました。変わるのは主に以下の点です。

**次元数**：モデルによって出力の次元数が異なります。次元数が多いほど、より多くの意味的特徴を表現できます。

| モデル | 次元数 |
|---|---|
| nomic-embed-text（今回） | 768 |
| text-embedding-3-small（OpenAI） | 1536 |
| text-embedding-3-large（OpenAI） | 3072 |

**検索精度**：より高精度なモデルでは、細かい意味の違いも捉えられるようになります。今回のサンプルは「dog と cat が近い」程度の大まかな関係なら正しく返せますが、精度の高いモデルでは「poodle と maltese は同じ小型犬系で近い」といった粒度まで扱えます。

**多言語対応**：モデルによって日本語の扱いが変わります。nomic-embed-text は主に英語向けで、日本語テキストの精度は落ちます。多言語対応モデルを使えば日英混在のドキュメントも精度よく扱えます。

**モデルを変えたらデータを全て再作成する必要があります。** モデルが違えばベクトルの空間が別物になるため、保存済みのベクトルと新モデルのクエリベクトルを比較しても意味をなさない結果が返ってきます。モデルを変える場合は、保存済みの全データを新しいモデルで再度ベクトル化してから保存し直す必要があります。

なお、LanceDB 側の検索ロジック自体は変わりません。変わるのは「テキストの意味をどれだけ正確にベクトルへ落とし込めるか」という埋め込みの質だけです。

## RAG への応用

このデータ保存 → ベクトル検索の流れは、RAG（Retrieval-Augmented Generation：検索拡張生成）の基礎部分です。RAG は、LLM が回答を生成する前に関連情報を検索して渡すことで、回答の精度を高める手法です。

### チャンクとは

RAG ではまず、ドキュメントを「チャンク」と呼ばれる小さな単位に分割します。1つのドキュメントをそのままベクトル化すると情報が大雑把になり検索精度が落ちるため、段落や一定の文字数ごとに区切って、それぞれをベクトル化して保存します。

今回のサンプルで言えば、単語4件（dog・cat・wolf・fish）がそれぞれ1チャンクに相当します。実際のRAGでは、これがドキュメントの断片に置き換わります。

```typescript
// 実際の RAG では単語ではなくドキュメントのチャンクを保存する
const data = [
  { id: "1", text: "猫は独立心が強く、単独行動を好む動物です...", vector: [...] },
  { id: "2", text: "犬は群れで生活する習性があり、人間との...",   vector: [...] },
  // ...
];
```

### RAG の流れ

```
【事前準備】
ドキュメント → チャンクに分割 → 埋め込みモデルでベクトル化 → LanceDB に保存

【質問時】
ユーザーの質問
  ↓ 埋め込みモデルでベクトル化
  ↓ LanceDB で意味的に近いチャンクを検索
  ↓ 該当テキストを LLM へ渡す（コンテキストとして追加）
  ↓ LLM が回答を生成
```

### なぜ精度が上がるのか

LLM にドキュメント全文をそのまま渡す場合、大量のテキストの中に埋もれた情報を拾い損ねることがあります。RAG では質問と意味的に近いチャンクだけを事前に絞り込んでから LLM に渡すため、LLM が参照すべき情報が明確になり、回答の精度が上がります。冒頭で触れた NotebookLM の体験も、この仕組みが働いています。

## まとめ

- LanceDB は組み込み型（Embedded）のベクトルDB。別途 DB サーバーの起動不要で、ローカルファイルに保存される
- ベクトルの数値は「意味の表現」と「空間上の位置」の両方を指す。各次元の値自体には意味はなく、ベクトル間の距離だけが重要
- ベクトル検索は特定の次元値でフィルタリングするのではなく、全次元まとめた距離が小さい順に返す
- 実際のユースケースでは埋め込みモデルがベクトルを自動生成し、「似た意味」は学習データの統計から自然に生まれる


今回はテキストのベクトル検索を中心に触れましたが、LanceDB の特徴のひとつにマルチモーダル対応があります。次回はテキストだけでなく画像なども同じテーブルで扱えるマルチモーダル検索の仕組みを検証していきたいと思います。

「RAG は知っているけれどベクトル検索の中身がよくわからない」という方の参考になれば嬉しいです。

## 参考

- [NotebookLM: An LLM with RAG for active learning and collaborative tutoring](https://arxiv.org/html/2504.09720v2)
- [Long Context vs. RAG for LLMs: An Evaluation and Revisits](https://arxiv.org/pdf/2501.01880)
- [LanceDB 公式ドキュメント](https://docs.lancedb.com/)
- [LanceDB SDK リファレンス](https://lancedb.github.io/lancedb/)
- [lancedb/lancedb - GitHub](https://github.com/lancedb/lancedb)
- [nomic-embed-text - Ollama](https://ollama.com/library/nomic-embed-text)
- [Generate Embeddings - Ollama API](https://docs.ollama.com/api/embed)
- [Ollama API ドキュメント - GitHub](https://github.com/ollama/ollama/blob/main/docs/api.md)
- [Embedding models - Ollama Blog](https://ollama.com/blog/embedding-models)
- [Embeddings - OpenAI](https://platform.openai.com/docs/guides/embeddings)
