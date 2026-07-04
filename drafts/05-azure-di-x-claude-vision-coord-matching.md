# [Draft] Azure Document Intelligence × Claude Vision を「座標マッチング」で組み合わせる OCR 設計

## この記事の狙い

- 表構造の複雑なPDFを、単一のOCR/LLMで精度100%には届かない現実に対して、**「座標で土台を取る OCR」 + 「意味で中身を取る LLM」** を組み合わせる設計を紹介
- 片方だけでやろうとしたときの失敗例を踏まえ、役割分担の思想を言語化する

## 想定読者

- Azure Document Intelligence や Claude / GPT-4o Vision を触ったことはあるが、精度が詰められず悩んでいる人
- 業務系PDF（帳票・伝票・表形式）のOCRを仕事で触っている人
- LLM単体でOCRを試して「表の行ズレ」「読み飛ばし」「幻覚」に苦しんだ経験がある人

## 骨子（想定6〜8章）

### 1. はじめに
- 業務PDF（帳票・伝票）の表OCRは難しい。なぜなら…
  - 行数・列数が動的
  - 罫線が欠けている、結合セルが混ざる
  - スキャン由来の歪みやノイズがある
- 「単一LLMに投げて全部取る」ではどこが壊れるのか（具体例: 行の取りこぼし、幻覚、数値誤認）

### 2. Azure Document Intelligence の強み/弱み
- 強み: 表構造を**座標＋ボックス単位**で安定して拾える
- 弱み: 「このセルは何を意味するか」は取ってくれない（OCRであって理解ではない）
- 読み取り結果の例（抽象化した表データ）

### 3. Claude Vision (or GPT-4o Vision) の強み/弱み
- 強み: セルの意味的な解釈・見出しと値の対応付けに強い
- 弱み: 行数が多くなると**取りこぼし**や**順序乱れ**が起きる。幻覚リスクあり

### 4. 役割分担の設計 — 「座標で土台、LLM で意味」
- Azure の表セルを **"座標付きの空の枠"** として先に確定
- Claude Vision の抽出結果を、**同じページ画像の座標**で Azure 側セルにマッチング
- マッチしなかった LLM 出力は**幻覚の可能性が高い**ので棄却または保留
- 図（Mermaid）で流れを書く

### 5. 座標マッチングの実装指針
- ページ画像の座標系を揃える（DPI、スケール、回転の正規化）
- セル bounding box と LLM が返した要素 bounding box の IoU で対応付け
- 曖昧な場合のタイブレーク戦略（近接度 + 文字列類似度）
- 擬似コードで示す（20〜30行想定）

```python
def match_by_coord(azure_cells, llm_items, iou_threshold=0.3):
    matched = []
    for cell in azure_cells:
        best = None
        best_iou = 0
        for item in llm_items:
            iou = compute_iou(cell.bbox, item.bbox)
            if iou > best_iou:
                best, best_iou = item, iou
        if best_iou >= iou_threshold:
            matched.append((cell, best))
    return matched
```

### 6. ハマりどころ
- **DPIがズレる**: Azureが想定する座標と、LLMに食わせた画像のDPIが違うと全滅
- **ページ回転の吸収**: Azureは自動回転補正するがLLMはしないことがある
- **Rate limit**: ページ並列で投げるとClaudeの同時実行上限にぶつかる。`ParallelCoordinator` 的な同時数制御が必要
- **プロンプト変更でキャッシュ失効**: キャッシュキーにプロンプトバージョンを含めないと古い結果を使い続ける

### 7. 精度評価の考え方
- 行単位の Precision / Recall で両モデル単独 vs 組み合わせを比較
- サンプルサイズはページ単位（100ページ程度で傾向が見える）

### 8. まとめ
- 「LLMだけ」「OCRだけ」より、**座標を接着剤にする** 多段設計が安定する
- 次の一歩: 多モデル化（Gemini / 他LLM）を切替可能にするインターフェース設計（別記事で）

## 補足メモ

- 実コードは業務プロジェクト由来なので、公開可能な最小再現（PublicなPDF 1枚 + Azure DI 公式サンプル + Claude API）で手元検証コードを別途書く
- 参考文献:
  - Azure Document Intelligence の table extraction ドキュメント
  - Anthropic Vision ドキュメント
  - 「表OCRの評価指標」に関する論文1つ

## 書く前のTODO

- [ ] 公開可能な検証用PDFを用意（請求書テンプレなど）
- [ ] IoUマッチングのコードを30行以内で書き切る
- [ ] 座標正規化（DPI/回転）の落とし穴を自分で再現して手順化
- [ ] 精度比較の小さな実測データ（単独 vs 組み合わせ）
