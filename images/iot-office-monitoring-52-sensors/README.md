# 画像の作り方

- `mote-01-overview.png`: 同じフォルダの HTML を `agent-browser open <file> && agent-browser screenshot --full <png>` で撮ったもの
- `architecture.png`: `architecture.drawio`（AWS アイコン）を diagrams.net で開いて PNG に書き出す。今回は viewer-static.min.js を埋め込んだページを agent-browser で撮り、Pillow で余白を切り詰めた
- `current-values.png` / `floor-map.png`: ローカル Grafana のパネルを 1 つずつ表示（viewPanel）して `screencapture` でウィンドウを撮り、パネルの枠で切り出したもの（doc-screenshot スキルの手順）。全期間を 600 倍で流した途中、元データの 2004-03-09 ごろにあたる時点。加工前は `_originals/`（git 管理外）
- `influx-cpu.png` / `lambda-concurrency.png`: CloudWatch の `get-metric-data`（5 分ごと）を matplotlib で描いたもの。InfluxDB の CPU は 10/6 15:39〜（1 件ずつ）と 10/21 12:51〜（SQS）、Lambda は 10/3 18:30〜21:55 の同時実行数（アカウント全体）と電池警告の Lambda の起動回数
- `voltage-vs-anomaly.png`: 電池電圧ごとの温度異常の割合（記事中の数値）を matplotlib で描いたもの
- `athena-monthly.png`: Athena のクエリエディタで月次レポートを実行した結果（2026-11-03）。claude-in-chrome のスクリーンショットから、アカウント名が出るヘッダーを外して切り出した。加工前は `_originals/`
- `dns-before.png` / `dns-after.png`: `dns-resolve.drawio`（AWS アイコン、2 ページ）を `drawio -x -f png -s 2 -b 10 -p <1|2>` で書き出したもの
- `glue-schema.png` / `glue-projection.png`: Glue コンソールの `office_monitoring.raw` の詳細画面（2026-11-03）。バケット名とアカウント ID をページ上で伏せ、左のメニューを閉じ、Table properties の列を広げてから、claude-in-chrome の zoom（save_to_disk）で切り出した
