# LanceDB と OpenCLIP でテキストから画像を検索してみた

こんにちは 人材育成室 育成メンバーチームで 研修中の はすと です。

前回は LanceDB を使ってテキストのベクトル検索の基礎を触りました。テキストを数値に変換して検索する仕組みがわかったところで、画像の方も同じように仕組みが気になったので、今回は LanceDB と OpenCLIP を使ってテキストから画像を検索する仕組みを試してみます。

本記事では、テキストで画像を検索する・画像で画像を検索するという2パターンを Python で動かした結果をまとめます。

## CLIP と OpenCLIP とは

**CLIP**（Contrastive Language-Image Pre-Training）は OpenAI が開発したモデルで、**テキストエンコーダー**と**画像エンコーダー**の2つを持ちます。両者が同じベクトル空間に出力するよう学習されているため、テキストと画像を直接比較できます。

ただし、テキストエンコーダーと画像エンコーダーは用途が分かれています。

- **保存時**：画像を**画像エンコーダー**でベクトル化 → LanceDB に保存
- **検索時**：クエリのテキストを**テキストエンコーダー**でベクトル化 → 保存済みの画像ベクトルと距離を比較

同じ空間に出力されるため、両者を直接比較できます。スキーマの `label` はどちらのエンコーダーも通らず、ただのメタデータです。

これにより、テキストをクエリにして画像を検索したり、画像をクエリにして似た画像を検索したりできます。

**OpenCLIP** はその OSS 再実装版で、LAION という大規模データセット（OpenAI の学習データより規模が大きい）で学習されており、画像検索の精度が元の CLIP より高いとされています。LanceDB は OpenCLIP との統合を公式にサポートしており、`get_registry().get("open-clip")` 一行で呼び出せます。

## LanceDB とマルチモーダルの関係

前回の補足で触れましたが、改めて整理します。

```mermaid
flowchart LR
  subgraph 保存時
    A[画像ファイル] -->|画像エンコーダー| B[ベクトル]
    B --> DB[(LanceDB)]
  end

  subgraph 検索時
    Q["クエリテキスト\n「dog」"] -->|テキストエンコーダー| QV[クエリベクトル]
    QV -->|距離比較| DB
    DB --> R[検索結果]
  end
```

LanceDB 自体はベクトルの保存と検索を担うだけです。保存時は画像エンコーダー、検索時はテキストエンコーダーと使い分けますが、両者が同じ空間に出力するため比較が成立します。

## セットアップ

```bash
pip install lancedb open-clip-torch Pillow pandas requests
```

## 実際に動かしてみた

### データの準備と保存

cat・dog・horse の画像をローカルに用意して LanceDB に保存します。

```python
from pathlib import Path

import lancedb
import pandas as pd
from lancedb.embeddings import get_registry
from lancedb.pydantic import LanceModel, Vector
from PIL import Image

IMAGE_DIR = Path("sample-images")

# LanceDB の埋め込みモデル登録簿から OpenCLIP を取得して初期化
# デフォルトは ViT-B-32（512次元）
func = get_registry().get("open-clip").create()

class Images(LanceModel):
    label: str
    image_uri: str = func.SourceField()          # ベクトル変換の入力元
    vector: Vector(func.ndims()) = func.VectorField()  # type: ignore[valid-type]

db = lancedb.connect("sample-lancedb-multimodal")
table = db.create_table("animals", schema=Images, mode="overwrite")

labels = ["cat", "cat", "dog", "dog", "horse", "horse"]
uris = [str(IMAGE_DIR / f) for f in [
    "cat_1.jpg", "cat_2.jpg",
    "dog_1.jpg", "dog_2.jpg",
    "horse_1.jpg", "horse_2.jpg",
]]

# add() 時に image_uri の画像を OpenCLIP で自動ベクトル化して保存
table.add(pd.DataFrame({"label": labels, "image_uri": uris}))
```

`func.SourceField()` を指定した `image_uri` フィールドが埋め込み元として扱われ、OpenCLIP が自動でベクトルに変換して保存します。

実際のユースケースでは手書きのラベルは不要で、商品名・ファイル名・URL など既存のメタデータをそのまま入れるのが自然です。

```python
# ECサイトなら商品データをそのまま入れる
{ "product_id": "SKU-001", "name": "白いTシャツ", "price": 2980, "image_uri": "..." }

# 画像→画像の類似検索だけなら image_uri だけでも十分
{ "image_uri": "..." }
```

また「画像にテキスト説明を持たせたいが手書きはしたくない」場合は、画像キャプション生成モデルで自動生成する方法もあります。キャプションを保存しておくとテキスト検索の精度が上がる利点もあります。

代表的なモデルとして以下の2つがあります。

- **LLaVA**（Large Language-and-Vision Assistant）：視覚エンコーダと LLM を組み合わせたマルチモーダルモデル。画像の説明・Visual QA・OCR などに対応。Ollama で `ollama pull llava` と叩くだけでローカル実行できます
- **BLIP-2**（Salesforce）：凍結した画像エンコーダと LLM を Q-Former と呼ぶ軽量ブリッジで繋いだモデル。画像キャプション生成と Visual QA が主な用途で、HuggingFace から利用できます

### テキストで画像を検索する

まず直接的なクエリを試します。

```python
for query in ["dog", "cat", "horse"]:
    results = table.search(query).limit(6).to_list()
    top = results[0]
    print(f"クエリ: {query!r:10} → {top['label']} (_distance: {top['_distance']:.4f})")
```

実行結果：

```
クエリ: 'dog'      → dog (_distance: 1.4740)
クエリ: 'cat'      → cat (_distance: 1.4347)
クエリ: 'horse'    → horse (_distance: 1.4731)
```

続いて、間接的・比喩的なクエリを試します。意味を理解しているモデルならば「dog」と直接書かなくても犬の画像が返るはずです。

```python
queries = [
    ("man's best friend",    "dog"),   # 犬の慣用表現
    ("loyal companion",      "dog"),   # 忠実な仲間
    ("barking animal",       "dog"),   # 吠える動物
    ("feline creature",      "cat"),   # ネコ科の生き物
    ("farm animal with mane","horse"), # たてがみのある家畜
    ("purring pet",          "cat"),   # ゴロゴロ鳴くペット
]

for query, expected in queries:
    result = table.search(query).limit(1).to_list()[0]
    mark = "✓" if result["label"] == expected else "✗"
    print(f"{mark} {query!r:30} → {result['label']} ({result['_distance']:.4f})  [期待: {expected}]")
```

実行結果：

```
✓ "man's best friend"            → dog (1.5389)  [期待: dog]
✓ 'loyal companion'              → dog (1.5486)  [期待: dog]
✓ 'barking animal'               → dog (1.6157)  [期待: dog]
✓ 'feline creature'              → cat (1.4679)  [期待: cat]
✗ 'farm animal with mane'        → cat (1.6486)  [期待: horse]
✓ 'purring pet'                  → cat (1.4665)  [期待: cat]
```

5/6 が正解でした。`"farm animal with mane"` だけ外れています。これはモデルの限界か表現の問題か、後述のモデルサイズ比較で確認します。

### 距離スコアで「近さ」を確認する

テキストクエリと各画像の距離を全件表示して、ベクトル空間上の位置関係を確認します。

```python
for query in ["dog", "cat", "horse"]:
    results = table.search(query).limit(6).to_list()
    print(f"\nクエリ: '{query}'")
    for r in results:
        print(f"  {r['label']}: {r['_distance']:.4f}")
```

実行結果：

```
クエリ: 'dog'
  dog: 1.4740
  dog: 1.5131
  cat: 1.5637
  cat: 1.5687
  horse: 1.6197
  horse: 1.6550

クエリ: 'cat'
  cat: 1.4347
  cat: 1.4495
  dog: 1.6168
  dog: 1.6347
  horse: 1.6560
  horse: 1.7051

クエリ: 'horse'
  horse: 1.4731
  horse: 1.5661
  cat: 1.6501
  cat: 1.6569
  dog: 1.6912
  dog: 1.7389
```

どのクエリでも同じラベルの画像が上位2件に来ており、ラベルをまたいで明確に距離が開いています。

### 画像で画像を検索する

今度は保存済みの犬の画像をクエリにして、似た画像を探してみます。

```python
query_image = Image.open(IMAGE_DIR / "dog_1.jpg")
results = table.search(query_image).limit(3).to_list()

print("クエリ: dog_1.jpg（犬の画像）")
for r in results:
    print(f"  {r['label']}: {r['_distance']:.4f}")
```

実行結果：

```
クエリ: dog_1.jpg（犬の画像）
  dog: 0.0000
  cat: 0.9202
  cat: 1.1078
```

1位の距離が `0.0000` なのは自分自身（`dog_1.jpg`）がヒットしているためです。画像をクエリにしても同じ `table.search()` で動き、LanceDB の検索ロジックはテキストのときと変わっていません。

### モデルサイズで精度はどう変わるか

デフォルトの `ViT-B-32`（軽量・512次元）と `ViT-L-14`（高精度・768次元）で間接クエリの正解率を比べます。

```python
for model_name, pretrained in [
    ("ViT-B-32", "laion2b_s34b_b79k"),
    ("ViT-L-14", "laion2b_s32b_b82k"),
]:
    func = get_registry().get("open-clip").create(
        name=model_name, pretrained=pretrained
    )
    # モデルが変わるとベクトルの空間が別物になるためテーブルを作り直す
    ...
```

実行結果：

```
モデル: ViT-B-32
✓ "man's best friend"            → dog (1.5389)  [期待: dog]
✓ 'loyal companion'              → dog (1.5486)  [期待: dog]
✓ 'barking animal'               → dog (1.6157)  [期待: dog]
✓ 'feline creature'              → cat (1.4679)  [期待: cat]
✗ 'farm animal with mane'        → cat (1.6486)  [期待: horse]
✓ 'purring pet'                  → cat (1.4665)  [期待: cat]
正解: 5/6

モデル: ViT-L-14
✓ "man's best friend"            → dog (1.5088)  [期待: dog]
✓ 'loyal companion'              → dog (1.5806)  [期待: dog]
✓ 'barking animal'               → dog (1.6212)  [期待: dog]
✓ 'feline creature'              → cat (1.5574)  [期待: cat]
✓ 'farm animal with mane'        → horse (1.7316)  [期待: horse]
✓ 'purring pet'                  → cat (1.5174)  [期待: cat]
正解: 6/6
```

`ViT-B-32` で外れていた `"farm animal with mane"` が `ViT-L-14` では正解になりました。大きいモデルほど言葉の細かいニュアンスを捉えられています。

### 保存されたデータを確認する

前回と同様に、`.lance` ファイルの中身を API で確認します。

```python
rows = table.search().limit(6).to_list()
for r in rows:
    vec = list(r["vector"])
    print(f"label: {r['label']}, vector: [{vec[0]:.4f}, {vec[1]:.4f}, {vec[2]:.4f}, ...] ({len(vec)}次元)")
```

実行結果：

```
label: cat, vector: [0.0266, 0.0204, -0.0307, ...] (512次元)
label: cat, vector: [0.0063, 0.0649, 0.0201, ...] (512次元)
label: dog, vector: [-0.0088, 0.0555, -0.0616, ...] (512次元)
label: dog, vector: [-0.0209, 0.1589, -0.0550, ...] (512次元)
label: horse, vector: [-0.0041, 0.2073, 0.0140, ...] (512次元)
label: horse, vector: [-0.0172, 0.2046, -0.1036, ...] (512次元)
```

テキストのときと同じく512次元のベクトルが保存されています。各次元の数値自体に意味はなく、ベクトル間の距離だけが重要なのも変わりません。

## 日本語クエリは使えるのか

デフォルトの `ViT-B-32` は英語テキストで学習されており、日本語クエリはほぼ機能しません。`"犬"` で検索してもランダムに近い結果が返ってきます。

ただし OpenCLIP には多言語対応モデルも用意されています。`XLM-Roberta` をテキストエンコーダーとして使ったモデル（`xlm-roberta-base-ViT-B-32`）は LAION-5B の多言語データで学習されており、日本語 ImageNet での精度が英語版の約1%から37%まで改善されています。

```python
# 多言語モデルに切り替える場合
func = get_registry().get("open-clip").create(
    name="xlm-roberta-base-ViT-B-32",
    pretrained="laion5b_s13b_b90k"
)
```

このように、モデルを変えるだけで日本語対応できますが、データを全て再ベクトル化し直す必要がある点は前回記事で触れた制約と同じです。

## なぜテキストと画像が同じ空間で比較できるのか

CLIP は大量の「画像とキャプション（テキスト）のペア」を使って学習しています。学習時のタスクは「この画像に対応するキャプションはどれか」という照合で、テキストエンコーダーと画像エンコーダーの2つが同時に学習されます。

```mermaid
flowchart LR
  subgraph train["学習データ（画像とテキストのペア）"]
    I1["犬が走っている画像"] -->|対応| T1["a dog running in the park"]
    I2["猫が眠っている画像"] -->|対応| T2["a sleeping cat on the sofa"]
  end

  subgraph space["学習後のベクトル空間"]
    V1["犬の画像ベクトル"] -. 近い .- V2["dog のテキストベクトル"]
    V3["猫の画像ベクトル"] -. 近い .- V4["cat のテキストベクトル"]
  end
```

この学習を大量に繰り返すことで、意味的に対応するテキストと画像が同じベクトル空間の近い位置に収束していきます。「man's best friend」と犬の画像が近い位置に来るのも、このような対応関係が統計的に学習された結果です。

## `"farm animal with mane"` が ViT-B-32 で外れた理由

`"farm animal with mane"`（たてがみのある家畜）は horse を期待しましたが、ViT-B-32 では cat が返ってきました。

これはモデルの表現力の問題と考えられます。ViT-B-32 は比較的小さいモデルのため、「farm animal」「mane」という複合的な手がかりを組み合わせて horse に辿り着くほどの解像度がなかった可能性があります。ViT-L-14 では正解したことから、モデルが大きいほど細かい意味の組み合わせを扱えるようになるのがわかります。

また、学習データに「farm animal with mane」という表現と馬の画像を結びつけるキャプションが少なかった場合も、ベクトルが horse から離れた位置に配置されます。CLIP の弱点として「コンポジション（複数概念の組み合わせ）への対応」が挙げられており、今回の結果はその一例として見ることができます。

## まとめ

- OpenCLIP はテキストと画像を同じベクトル空間に変換するモデル。これにより、テキストで画像を検索したり、画像で画像を検索したりできる
- LanceDB 側の保存・検索ロジックは前回と変わらない。変わるのは埋め込みモデルが「テキストだけでなく画像も扱える」点だけ
- `"man's best friend"` のように「dog」と直接書かなくても犬の画像が返るのは、CLIP がテキストの意味を統計的に学習しているため
- モデルが大きいほど細かいニュアンスを扱える。ViT-B-32（5/6正解）より ViT-L-14（6/6正解）の方が複合的な表現に強い
- デフォルトは英語のみ対応。日本語クエリを使う場合は `xlm-roberta-base-ViT-B-32` など多言語モデルへの切り替えが必要
- 動画・音声への応用は Meta の ImageBind で同じ仕組みが6モダリティに拡張されている

次回は ImageBind を使って動画や音声も含めたマルチモーダル検索を試してみたいと思います。

私と同じように「マルチモーダル検索の仕組みが気になっている」という方の参考になれば嬉しいです。

## 参考

- [OpenCLIP - LanceDB 公式ドキュメント](https://docs.lancedb.com/integrations/embedding/openclip)
- [GitHub - mlfoundations/open_clip](https://github.com/mlfoundations/open_clip)
- [Learning Transferable Visual Models From Natural Language Supervision（CLIP 論文）](https://arxiv.org/abs/2103.00020)
- [LLaVA 公式サイト](https://llava-vl.github.io/)
- [BLIP-2 - Salesforce / HuggingFace](https://huggingface.co/Salesforce/blip2-opt-2.7b)
- [BLIP-2 論文](https://arxiv.org/pdf/2301.12597)
