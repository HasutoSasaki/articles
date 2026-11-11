---
title: "なぜ青い箱だけ動き続けるのか"
emoji: "🟦"
type: "tech"
topics: ["css", "animation", "javascript", "browser"]
published: false
---

![Chromeの録画。青い箱は動き続け、赤い箱とカウンターは止まっている](/images/hasuto-css-animation-main-thread-sample/chrome-blocked.gif)

JavaScriptが `while` ループを回している間、青い箱だけが往復を続けています。赤い箱は途中で止まり、画面の `requestAnimationFrame` のカウンターも進みません。

こんにちは、製造ビジネステクノロジー部のはすとです。フロントエンドカンファレンス東京2026のショートセッションに向けて、メインスレッドを止めたときのブラウザの動きを調べています。青はCSSの `transform: translateX()`、赤はCSSの `left` で動かしています。どちらも `@keyframes` で、370pxの距離を片道1秒で往復します。

## 同じ `transform` をJavaScriptで更新する

ページのボタンを押すと、**メインスレッド**（このページのJavaScriptやレイアウトの計算を担当するスレッド）がループでふさがります。ループを抜けるまで、次の描画に合わせて呼ばれる `requestAnimationFrame` のコールバックには実行の順番が回りません。冒頭のカウンターは、そのコールバックが呼ばれるたびに1ずつ増えます。

では、青と同じ `transform` をコールバックの中で更新したらどうなるでしょうか。検証コード `browser-render-thread-lab/index.html` のコピーに緑の箱を足し、青と同じ距離と周期で動かしました。緑にはCSSアニメーションを指定せず、コールバックが受け取った時刻から位置を計算して `box.style.transform` に代入します。

```js
let start;
requestAnimationFrame(function move(now) {
  start ??= now;
  const phase = ((now - start) % 2000) / 1000;
  const x = 370 * (phase <= 1 ? phase : 2 - phase);
  box.style.transform = `translateX(${x}px)`;
  requestAnimationFrame(move);
});
```

macOS 26.7.1のヘッドレスChrome 156.0.8078.80で、5秒間のループの直前と直後に値を読み取りました。緑の `transform` はどちらも `translateX(258.963px)`、カウンターはどちらも20でした。ループを抜けた後のコールバックで位置が変わり、カウンターは21になりました。

## 箱を描き直す処理と、位置を更新する処理

ブラウザは要素の大きさや位置を**レイアウト**で決め、**ペイント**で何を描くかを記録します。描画済みのレイヤーを組み合わせて1枚の画面にする処理が**合成**です。今回の3つの箱について、位置が変わるときに必要な処理を並べるとこうなります。

```text
赤  CSS left
    → レイアウト → ペイント → 合成

青  CSS transform
    → 描画済みのレイヤーを移動して合成

緑  JavaScript transform
    → コールバックが次の位置を書き込む
    → 描画済みのレイヤーを移動して合成できる
```

赤の `left` は、絶対配置した箱のレイアウト上の位置を変えます。青の `translateX()` は、レイアウトで決めた位置から見た目をずらします。今回の青のように合成側で実行できるCSSアニメーションなら、ブラウザはキーフレームをもとに次の位置を求め、描画済みのレイヤーを動かせます。緑も同じプロパティを使いますが、次の位置が届くにはJavaScriptの実行が必要です。

動き続けた青い箱の次の値は、実際にはどこで計算されているのでしょうか。次の記事では、macOSの `sample` でChrome、Safari、Firefoxの実行中の処理を記録し、その場所を探ります。

## 参考

- [RenderingNG architecture - Chrome for Developers](https://developer.chrome.com/docs/chromium/renderingng-architecture#rendering_pipeline_structure)
- [Animation frames - HTML Standard](https://html.spec.whatwg.org/multipage/imagebitmap-and-animations.html#animation-frames)
