# 画像の作り方

- `architecture.png`: `architecture.drawio`（AWS アイコン）を viewer-static.min.js の埋め込みページで表示し、agent-browser で撮って余白を切り落としたもの
- `cloudwatch-alarm.png`: CloudWatch のアラーム画面を Claude in Chrome で表示し、ALARM の帯（グラフの iframe 内の要素）に合わせて赤枠を置いて撮ったもの。ヘッダーのアカウント情報は切り落としている
- `webapp-incident-list.png` / `webapp-timeline.png` / `root-cause.png` / `webapp-mitigation.png`: DevOps Agent の Web App を Claude in Chrome で表示し、注目箇所にページ側で赤枠を入れて撮ったもの。アカウント ID、ECS のサービス名とクラスター名、タスク定義名、タスク ID はページ上で伏せてから撮影。左メニュー下部のユーザー名は切り落としている
- 加工前の画像は `_originals/`（コミット対象外）
