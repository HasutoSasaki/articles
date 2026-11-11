# 画像の作り方

- `architecture.png`: `architecture.drawio`（AWS アイコン）を `drawio -x -f png -s 2 -b 10 -o architecture.png architecture.drawio` で書き出したもの
- `job-a-executions.png`: IoT コンソールのジョブ `fw-110-a-console` の「ジョブの実行」タブ（2026-11-04）。左のメニューを閉じ、doc-screenshot スキルの手順で `screencapture` でウィンドウを撮り、アカウント名が出るヘッダーを外して切り出した。加工前は `_originals/`（git 管理外）
- `create-job-s3.png`: カスタムジョブの作成画面のステップ 2（2026-11-04）。S3 URL はページ上で `s3://<バケット名>/document.json` に置き換えてから撮った。フォームは送信していない。撮り方は上と同じ
