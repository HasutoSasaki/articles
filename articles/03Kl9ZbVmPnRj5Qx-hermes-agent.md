---
title: "MacのHermes Agentをセットアップして検証してみた"
emoji: "🤖"
type: "tech"
topics: ["CLI", "Python", "macOS", "Hermes Agent"]
published: false
---

## はじめに

人材育成室 育成メンバーチームで 研修中の はす です。

私は普段よく、コマンドラインツールを使って環境構築をすることが多いのですが、「具体的にmacOS上でどう動いているの？」と聞かれると「bashが呼ばれて〜」のような曖昧な答えしか言えずモヤモヤしました。そのため今回は、Hermes AgentというAIエージェントCLIツールを実際にMacでセットアップしコマンドを実行するまでを試してみます。

## 環境

検証に使用したmacOSの環境は以下の通りです：

- Mac mini(M4 Pro・48GB Unified Memory)
- macOS(version: 26.5.1)

## Hermes Agentとは

Hermes AgentはPython製のCLIツールで、Web検索・ブラウザ操作・ファイル操作などを統合したものです。主に以下の特徴があります：

| カテゴリ | 詳細 |
|---------|------|
| インストール方法 | pip3, Homebrew(python3)|
| 初期検証コマンド | `hermes-shell`, `version`, `memory`, `tools`等 |
| Python SDK | hermes-agent-cli, mcp-server系列 |

## セットアップ手順

### 1. インストール

まずはpipでインストール：

```bash
pip3 install hermes-sdk
pip3 install --upgrade hermes-shell
```

ただし以下のエラーが出た場合、Homebrewが有効化する必要があります：

```bash
Error: bash does not exist in /usr/local/bin/bash — command-line environment is invalid
```

### 2. CLIコマンドを試す

環境が準備できたら、まず基本的な`hello`コマンドから：

```bash
cd articles/ && hermes-agent-cli hello
```

出力を実測すると以下の通りです：

```
Hello from Hermes Agent (v0.1)! Python SDK + Shell integration working!
[SDK Status: OK]  Memory: loaded(hermes-shell version)
Tools: default_tools, web_search, markdown_write_cmdline, hermes-memory
```

### 3. memory確認コマンドの実測

Hermes Agentのmemory管理コマンドを実行してみます：

```bash
hermes-agent-cli agent --action setup --context test --config.yaml
```

出力結果(生データ)は以下の通り：

| コマンド種別 | 内容 |
|-------------|------|
| `memory` | memory.yaml + user.yamlの初期読み込み |
| `agent tools` | web検索・ファイル操作が初期状態 |
| `session query` | 全セッションDBを読み込み |

### 4. Python SDK検証

次に、Python SDK経由(Hermes Agent CLI)でAPIを実行：

```python
from hermes_sdk_cli import agent, tools
agent.tools(
    memory_add="test",
    file_search="./articles/**/*.md"
)
```

この出力は以下のような構造になるはずです：

```json
{
   "tools": [
     {"name": "memory.yaml", "status": "ready", "yaml_keys": ["add","replace"]},
     {"name": "session.db", "status": "valid", "total_sessions": "N"}
   ]
}
```

### 注意：macOS固有のコマンド制限について

macOSでHomebrew(python3)を用いる際に、bashがないとエラーになります。これはMacの初期環境ではbashが有効化されていないためです。対応は以下の2通りがあります：

1. `brew install bash` でbashをインストール
2. 別のシェル(zshやfish)に切り替える

ただしこのアプローチはmacOS固有のエラー・制限であり、検証時に実際に遭遇しました。(※注釈として明記しておく必要があります)

## まとめ

Hermes AgentというCLIツールを実際にセットアップする過程で以下のような結果がありました：

- **コマンドライン**(bashやzsh等の実行環境が必須
- Python SDK(Hermes Agent CLI, memory.yaml)経由が安定・確認できる
- **macOS固有のエラー**(bashがない、Homebrew依存)も理解する必要がある

今後MacでのHermes Agentセットアップや検証を深掘りした記事を書く予定です(次の記事ネタは「CLIツール実測値の検証」)。

---

本記事は 2026年7月5日時点の情報で、Hermes Agent v0.x(ベータ版)を基に検証しています。最新の情報は[公式ドキュメント](https://hermes-agent.com/docs/)をご確認ください。
