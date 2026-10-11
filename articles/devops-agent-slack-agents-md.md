---
title: "AWS DevOps AgentのSlackの返答形式をAGENTS.mdで変えてみた"
emoji: "💬"
type: "tech"
topics: ["aws", "devopsagent", "slack", "agentsmd"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

AWS DevOps AgentをSlackから使っていると、返答に絵文字付きの見出しや表が並び、時刻もUTCのままで読みにくいと感じることがありました。
DevOps Agentには、毎回読ませる指示を書いておけるAGENTS.md（Agent instructions）があります。
これで返答の形式を変えられるのか試してみたところ、Web Appでは反映されたのに、Slackでは反映されませんでした。
ただし、AGENTS.mdに「この書式を優先する」と書き足すと、Slackでも反映されるようになりました。

本記事では、Slackで反映されなかった理由と、反映させるために書き足した内容をまとめます。

## 検証環境

- 2026年10月時点
- リージョン: ap-northeast-1
- Slackアプリ: AWS DevOps Agent - AP (Tokyo)（プライベートチャンネル、双方向通信あり）
- AGENTS.mdの登録: aws-cdk-lib 2.269.0 の `CfnAsset`

## AGENTS.md（Agent instructions）とは

DevOps Agentに常に守ってほしい方針を書いておくファイルです。
Agent SpaceのWeb AppのKnowledgeページにあるInstructionsタブで設定します。
CLIやCloudFormation（`AWS::DevOpsAgent::Asset`）からも登録できます。

公式ドキュメントでは、次のように説明されています。

> instructions are always present from the start of every session
>
> （指示は、すべてのセッションの最初から常に読み込まれています）
>
> [Agent instructions - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-agent-instructions.html)

Skillのように、Agentが必要に応じて読むかどうかを決めるものではありません。
AGENTS.mdは、全エージェント共通のものと、エージェントの種類ごとのものを置けます。
種類には、チャットを担当するChatや、調査結果の投稿を作るIncident UIなどがあります。
1回のセッションでは、共通のものと、その種類のものの両方が読み込まれます。

## 書いたAGENTS.md

共通のAGENTS.mdには、言語や時刻など、どのエージェントにも守ってほしいことを書きました（一部抜粋）。

```markdown
# 共通の方針

## 言語と時刻

- 日本語で書く。AWS のサービス名、リソース名、メトリクス名、エラーメッセージは原文のまま書く
- 時刻は日本時間（JST）で書く。ログや CloudWatch の UTC の時刻は JST に直す
```

Chat用のAGENTS.mdには、Slackのチャットでの答え方を書きました（一部抜粋）。

```markdown
# チャットでの答え方

チャットの回答は Slack のチャンネルに投稿され、チームのメンバーが読みます。

## 構成

- 最初の 1〜2 文で結論を書く
- そのあとに根拠を書く
- 最初の回答は 15 行以内にする。詳細は聞かれたら答える

## Slack での表示

- 見出し（`#`、`##`）と表は使わない
- 箇条書きは 1 つの項目を 1 行に収め、5 項目までにする
- 強調（太字）は 1 回の回答で 1 か所までにする
- リソース名、アラーム名、コマンドは `バッククォート` で囲む
- 絵文字と感嘆符は使わない
```

今回はCDKの`CfnAsset`で登録しました。

```typescript
new devopsagent.CfnAsset(this, "AgentsMdChat", {
  agentSpaceId: "<Agent SpaceのID>",
  assetType: "agents_md",
  metadata: { agent_type: "CHAT" }, // 共通のものは GENERIC
  files: [
    { path: "AGENTS.md", contentText: fs.readFileSync("agents-md/CHAT/AGENTS.md", "utf-8") },
  ],
});
```

## Slackで試してみた

Slackのチャンネルで、DevOps Agentに直近24時間にALARMになったアラームを聞いてみました。
AGENTS.mdを読んでいれば、JSTの時刻で、見出しも表も絵文字もない返答になるはずです。

返答です（アラーム名などは置き換えています。以降の画像とテキストも同じです）。

![Slackでの返答。絵文字付きの見出し、コードブロックに入った表、UTCの時刻が並び、「*6 件*」のようにアスタリスクがそのまま表示されている](/images/devops-agent-slack-agents-md/01-before.png)

実際には、AGENTS.mdに書いたことがほとんど守られていませんでした。

| AGENTS.mdに書いたこと | 返答 |
|---|---|
| 時刻はJSTで書く | UTCのまま |
| 見出しと表は使わない | 絵文字付きの見出しと、コードブロックに入った表がある |
| 絵文字は使わない | 使っている |

あわせて、`*6 件*`のようにアスタリスクがそのまま表示されています。
太字の記号が日本語と隙間なく並んでいるため、太字として扱われなかったと見られます。

同じ質問をWeb Appのチャットでもしてみました。
返答です。

```text
直近 24 時間で ALARM に遷移したアラームは PRD 環境で **2 件**、いずれも短時間で回復しています。

1. `app-api-4xx-rate-alarm`
   - 遷移: 2026-10-09 11:34 JST（OK → ALARM → OK 11:39 JST）
   - API Gateway の 4xx エラー率が一時的に 14.3% に上昇（閾値 10%）

2. `app-converter-priority-queue-messages-visible`
   - 遷移: 2026-10-09 14:03 JST（OK → ALARM → OK 14:04 JST）
   - SQS priority queue の可視メッセージ数が一時的に閾値（1 以上）に達した（最大 6 件）

現時点で ALARM が継続しているものはありません。いずれも数分以内に自動回復した単発の事象です。詳細を調べたい場合はお知らせください。
```

こちらはJSTの時刻で、見出しや表もありません。
Web Appでは、AGENTS.mdが反映されていました。

## なぜSlackでは反映されないのか

まず、SlackのセッションでAGENTS.mdが読み込まれているのかが気になりました。
同じスレッドで、読み込んでいるAGENTS.mdの内容を聞いてみました。

![Slackでの返答。共通の方針とチャットでの答え方の2つのAGENTS.mdを読み込んでいるとして、それぞれの要点を挙げている](/images/devops-agent-slack-agents-md/02-loaded.png)

共通とChatの2つを読み込んでいると答え、中身も書いたとおりでした。
読み込まれていないわけではなさそうです。

では、読み込んでいるのに、なぜ守らなかったのでしょうか。
続けて、従わなかった理由と、Slackへの投稿で別に従っている書式があるかを聞いてみました。

![Slackでの返答。従っていなかった点を挙げたうえで、AGENTS.md以外に自身の動作ルール（UXガイド）があり、見出しや表、絵文字を使うよう推奨されているため、そちらを優先したと答えている](/images/devops-agent-slack-agents-md/03-reason.png)

DevOps Agentには、AGENTS.mdとは別に組み込みの動作ルール（UXガイド）があり、そこでは見出しや表、絵文字で整理することが推奨されている、という答えでした。
Slackへの返答では、そちらを優先していたようです。

この答えはDevOps Agent自身の説明なので、正しいとは言い切れません。
ただ、絵文字付きの見出しや、表をコードブロックで囲む形は、Slackに見やすく出すための書式に見えます。
実際の返答の崩れ方とも合っているので、この説明を手がかりに対策を考えることにしました。

## Slackでも反映させる方法

組み込みの書式より、AGENTS.mdの書式を優先するように書き足しました。
あわせて、記号がそのまま出てしまう太字も使わないようにしました。

```diff
 # チャットでの答え方

 チャットの回答は Slack のチャンネルに投稿され、チームのメンバーが読みます。

+## この指示の優先順位
+
+- 回答の書式は、この指示に従う。組み込みの書式のガイド（見出し・表・絵文字で整理する、など）と食い違うときも、この指示を優先する
+- Slack に投稿するときも同じ
+
 ## Slack での表示

 - 見出し（`#`、`##`）と表は使わない
-- 強調（太字）は 1 回の回答で 1 か所までにする
+- 太字は使わない。Slack では、太字の記号がそのまま表示されることがある
```

前のスレッドのやり取りが影響しないように、新しいスレッドで同じ質問をしました。

![Slackでの返答。JSTの時刻で、見出しや表、絵文字がなく、アラーム名はバッククォートで囲まれている](/images/devops-agent-slack-agents-md/04-after.png)

今度は、時刻がJSTになり、絵文字付きの見出しや表もなくなりました。
アラーム名もバッククォートで囲まれています。

| AGENTS.mdに書いたこと | 前 | 後 |
|---|---|---|
| 時刻はJSTで書く | UTCのまま | JST |
| 見出しと表は使わない | ある | ない |
| 絵文字は使わない | 使っている | 使っていない |

新しいスレッドで、同じ質問をあと2回してみました。
3回の結果は次のとおりです（画像は1回目です）。

| AGENTS.mdに書いたこと | 1回目 | 2回目 | 3回目 |
|---|---|---|---|
| 時刻はJSTで書く | 守られた | 守られた | 守られた |
| 見出し、表、絵文字は使わない | 守られた | 守られた | 守られた |
| 太字は使わない | 見出しの代わりに太字の行がある | 守られた | 守られた |
| 最初の回答は15行以内 | 約20行 | 約9行 | 約8行 |
| 最初の1〜2文で結論を書く | 1行目が前置き | 1行目が前置き | 1行目が前置き |

書き足す前のSlackの返答は1回だけ試した結果ですが、書き足したあとの3回では、時刻と見出し、表、絵文字のルールが毎回守られました。
一方で、1行目に結論を書くルールは、3回とも守られませんでした。
1行目は毎回「直近24時間のアラームを調べます。」のような前置きです。

返答の形式は大きく変わりましたが、細かいルールまですべて守らせるには、もう少し書き方の工夫が要りそうです。

なお、Incident UI（調査結果の投稿）用のAGENTS.mdも同じように書き足しましたが、調査結果の投稿での反映のされ方は今回は試していません。

## まとめ

AGENTS.mdは、Web Appでは書いたとおりに反映されましたが、Slackでは書式のルールが守られませんでした。
DevOps Agent自身は、組み込みの書式のガイドを優先していたと説明しています。
「この書式を組み込みの書式より優先する」と書き足すと、Slackでも時刻や見出し、表、絵文字のルールが守られるようになりました。
書き足しただけで返答が変わったので、SlackのセッションでもAGENTS.mdは読み込まれていると考えられます。

Web Appでは反映されるのにSlackでは反映されない、と困っている方の参考になれば嬉しいです。

## 参考

- [Agent instructions - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-agent-instructions.html)
- [Managing assets - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-managing-assets.html)
- [Slack setup - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-capabilities-connecting-ticketing-and-chat-slack.html)
- [【アップデート】AWS DevOps Agent の Slack連携に双方向コミュニケーション機能が追加されました - DevelopersIO](https://dev.classmethod.jp/articles/devops-agent-slack-bidirectional-communication/)
