---
title: "【1分で解決】npm install -g で権限エラーが出た時の正しい対処法"
emoji: "🔧"
type: "tech"
topics: ["npm", "node", "linux", "権限", "エラー解決", "初心者向け"]
published: false
---

## TL;DR（結論）
- `sudo npm install -g` は**絶対NG**
- `~/.npm-global`ディレクトリを作成してnpmに指定する
- PATHを通せば完了

## 問題：よくある権限エラー

```bash
npm install -g @anthropic-ai/claude-code

# エラー例
The operation was rejected by your operating system.
npm error It is likely you do not have the permissions to access this file
```

## 間違った解決方法（やってはいけない）

```bash
# ❌ 絶対にダメ！
sudo npm install -g パッケージ名

# 理由：
# - セキュリティリスク
# - ファイル所有権が混乱
# - 後々別の権限問題を引き起こす
```

## 正しい解決方法（3ステップ）

### Step 1: グローバル用ディレクトリ作成
```bash
mkdir -p ~/.npm-global
```

### Step 2: npmに新しいディレクトリを指定
```bash
npm config set prefix '~/.npm-global'
```

### Step 3: PATHを通す
```bash
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

### 完了：パッケージインストール
```bash
# これで権限エラーなしでインストール可能
npm install -g @anthropic-ai/claude-code
```

## なぜこの方法が良いのか？

### 従来（問題のある構造）
```
/usr/local/lib/node_modules  ← root権限が必要
└── グローバルパッケージ
```

### 改善後（安全な構造）
```
~/.npm-global/
├── lib/node_modules/  ← あなたの権限
└── bin/               ← 実行ファイル
```

## 設定確認方法

```bash
# npm設定確認
npm config get prefix
# 結果: /home/username/.npm-global

# PATHの確認
echo $PATH | grep npm-global
# 結果: ~/.npm-global/bin が含まれていればOK

# インストール済みパッケージ確認
npm list -g --depth=0
```

## よくある質問

### Q: 既存のグローバルパッケージはどうなる？
A: `/usr/local`に残るので、必要に応じて再インストールしてください。

### Q: チーム開発での共有方法は？
A: この設定を`.bashrc`や`.zshrc`でチーム共有するか、プロジェクト単位で`package.json`を使用。

### Q: Windowsでも同じ？
A: 概念は同じですが、パスやコマンドが異なります。WSLの使用を推奨。

## Docker環境での代替案

```dockerfile
# Dockerfileでのベストプラクティス
FROM node:18-slim
USER node
WORKDIR /home/node
RUN npm config set prefix /home/node/.npm-global
ENV PATH=/home/node/.npm-global/bin:$PATH
RUN npm install -g your-package
```

## まとめ

npm権限問題は**システム設計の問題**です。sudoで強引に解決するのではなく、適切なディレクトリ設計で根本解決しましょう。

## 参考リンク

- [npm公式：グローバルパッケージの権限修正](https://docs.npmjs.com/resolving-eacces-permissions-errors-when-installing-packages-globally)
- [Node.js公式：権限について](https://nodejs.org/en/download/package-manager/)
- [Claude Code公式ドキュメント](https://docs.claude.com/en/docs/claude-code/setup)
- [Ubuntu権限管理ガイド](https://help.ubuntu.com/community/FilePermissions)

---

**次回予告**: package.jsonとnpm scriptsでプロジェクト管理を効率化する方法
