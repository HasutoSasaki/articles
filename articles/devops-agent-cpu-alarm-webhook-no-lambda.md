---
title: "CloudWatchアラームからLambdaなしでAWS DevOps Agentの調査を起動し、コードの改善案まで出るか試してみた"
emoji: "🔍"
type: "tech"
topics: ["aws", "devopsagent", "cdk", "eventbridge", "cloudwatch"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

CPUのアラームが鳴ったときの調査は、「処理件数が増えたから」というメトリクスの話で止まりがちですよね。
本当に知りたいのは、どのコードが重いのか、どう直せばよいのかのほうです。
AWS DevOps AgentはGitHubのリポジトリを読めるので、アラームを起点にコードの改善案まで出してくれるのでは？と気になりました。

あわせて、アラームから調査を起動する部分も気になっていました。
既存の検証記事では、CloudWatchアラームとDevOps AgentのWebhookのあいだにLambdaを挟む構成が多く見られます。
LambdaなしでCloudWatchから直接つなげられれば、そのほうが構成はシンプルです。

本記事では、わざと重い処理を入れたワーカーをECS Fargateで動かし、CPUアラームからLambdaなしで調査を起動して、コード単位の改善案が出るかを試した結果をまとめます。
結論から書くと、Lambdaなしで調査は起動でき、重い関数と行番号まで特定されました。
ただし、今回の環境には答えを見つけやすくするヒントが残っていたので、その点もあわせて書きます。

## 検証環境

- aws-cdk-lib 2.272.0
- AWS CDK CLI 2.1144.0
- リージョン: ap-northeast-1（Agent Spaceもワーカーも東京）
- GitHub: 個人アカウントのプライベートリポジトリ

## 構成

以下のような流れになります。

```
ECS Fargate のワーカー（CPU が上がる）
  └─ CloudWatch アラーム（70% を 3 分連続で超えたら ALARM）
       └─ EventBridge ルール（アラームの状態変化イベントを拾う）
            └─ API 送信先（Webhook に POST）
                 └─ DevOps Agent の調査
                      ├─ CloudWatch のメトリクスとログを読む
                      └─ GitHub のソースコードを読む
```

Agent Space、GitHubとの関連付け、ECS、アラーム、EventBridgeは、すべて1つのCDKスタックで作りました。
ただし、CDKで作れない部分が3つあり、そこはコンソールで操作しています。

| 操作 | 理由 |
|---|---|
| GitHubの登録 | GitHub Appのインストールにブラウザでの承認が必要 |
| 汎用Webhookの作成 | CloudFormationにWebhookのリソースがない |
| 週次評価の停止 | Agent Spaceのリソースに設定項目がない |

いずれも2026年10月時点のCloudFormationのスキーマで確認した内容です。

## LambdaなしでWebhookを呼べる理由

DevOps Agentの汎用Webhookは、作成時に認証方式を選べます。

> Choose an authentication method: HMAC or API key (bearer token).
> — [Invoking DevOps Agent through Webhook - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-invoking-devops-agent-through-webhook.html)

和訳すると「認証方式を選んでください。HMACか、APIキー（Bearerトークン）です」となります。

HMAC方式だと、リクエストごとにタイムスタンプと本文から署名を計算して付ける必要があります。
EventBridgeだけでは署名を計算できないので、この方式ではLambdaが必要です。

一方、APIキー方式なら、固定のトークンを `Authorization: Bearer <トークン>` ヘッダに付けるだけです。
EventBridgeのAPI送信先（API Destination）は、接続（Connection）にAPIキーを持たせてヘッダを付けられます。
そのため、EventBridgeルールのターゲットにAPI送信先を直接指定すれば、Lambdaを挟まずにWebhookを呼べます。

## デモ用のワーカー

ワーカーは、注文データをまとめて処理する想定にしました。
1秒ごとに注文を作り、重複を取り除いてから種別を振り分けます。
1回に処理する件数は、環境変数で毎分少しずつ増えるようにしています。

重複除去は、配列を毎回先頭から探す書き方にしています。
件数をnとすると、計算量はO(n²)です。

```js:app/worker.js
// 重複した注文を取り除く
function dedupeOrders(orders) {
  const unique = [];
  for (const order of orders) {
    if (!unique.some((o) => o.orderId === order.orderId)) {
      unique.push(order);
    }
  }
  return unique;
}

// 注文 ID から種別を取り出す
function classifyOrders(orders) {
  return orders.map((order) => {
    const pattern = new RegExp('^(\\d{10})_(\\d+)_([A-Za-z]+)$');
    const match = pattern.exec(order.orderId);
    return { ...order, category: match ? match[3] : 'unknown' };
  });
}
```

ログには、1回の処理にかかった時間を処理ごとに出しています。

```js:app/worker.js
log({
  msg: 'batch processed',
  batchSize,
  uniqueCount: classified.length,
  durationMs: t3 - started,
  stepMs: { generateOrders: t1 - started, dedupeOrders: t2 - t1, classifyOrders: t3 - t2 },
});
```

手元のMacで動かすと、件数が3,000件で20ミリ秒、15,000件で240ミリ秒でした。
件数が5倍になると時間は約12倍になり、O(n²)らしい増え方をしています。

## CDKで定義したもの

### Agent Spaceと関連付け

Agent Spaceには、DevOps Agentが引き受けるIAMロールが2つ必要です。
1つは監視対象のアカウントを読むためのロールで、もう1つはWeb App（Operator App）用のロールです。
Agent SpaceのARNは作成後に決まるので、信頼ポリシーの条件はワイルドカードにしています。

```ts:lib/cpu-demo-stack.ts
const agentSpaceArnPattern = `arn:aws:aidevops:${this.region}:${this.account}:agentspace/*`;

const agentRole = new iam.Role(this, 'AgentSpaceRole', {
  assumedBy: new iam.ServicePrincipal('aidevops.amazonaws.com', {
    conditions: {
      StringEquals: { 'aws:SourceAccount': this.account },
      ArnLike: { 'aws:SourceArn': agentSpaceArnPattern },
    },
  }),
  managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsAgentAccessPolicy')],
});

const operatorRole = new iam.Role(this, 'OperatorAppRole', {
  assumedBy: new iam.ServicePrincipal('aidevops.amazonaws.com', {
    conditions: {
      StringEquals: { 'aws:SourceAccount': this.account },
      ArnLike: { 'aws:SourceArn': agentSpaceArnPattern },
    },
  }).withSessionTags(),
  managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AIDevOpsOperatorAppAccessPolicy')],
});

const agentSpace = new devopsagent.CfnAgentSpace(this, 'AgentSpace', {
  name: 'cpu-demo-space',
  locale: 'ja',
  operatorApp: { iam: { operatorAppRoleArn: operatorRole.roleArn } },
});
```

監視対象のアカウントとGitHubのリポジトリは、どちらも `CfnAssociation` で関連付けます。
AWSアカウントの `serviceId` は `'aws'` 固定です。
GitHubの `serviceId` は、コンソールでGitHubを登録したときに発行されるIDを使います。

```ts:lib/cpu-demo-stack.ts
new devopsagent.CfnAssociation(this, 'AwsMonitorAssociation', {
  agentSpaceId: agentSpace.attrAgentSpaceId,
  serviceId: 'aws',
  configuration: {
    aws: { accountId: this.account, accountType: 'monitor', assumableRoleArn: agentRole.roleArn },
  },
});

new devopsagent.CfnAssociation(this, 'GitHubAssociation', {
  agentSpaceId: agentSpace.attrAgentSpaceId,
  serviceId: '<GitHub 登録時に発行された ID>',
  configuration: {
    gitHub: {
      owner: '<GitHub のユーザー名>',
      ownerType: 'user',
      repoName: '<リポジトリ名>',
      repoId: '<リポジトリの数値 ID>',
    },
  },
});
```

リポジトリの数値IDは `gh` コマンドで取れます。

```bash
gh api repos/<ユーザー名>/<リポジトリ名> --jq '{id, private}'
```

実行結果です。

```json
{"id":<リポジトリの数値 ID>,"private":true}
```

### アラームからWebhookまで

CPUアラームは、ECSサービスのCPU使用率が70%を3分連続で超えたらALARMになるようにしました。

```ts:lib/cpu-demo-stack.ts
const cpuAlarm = new cloudwatch.Alarm(this, 'WorkerCpuHighAlarm', {
  alarmName: 'devops-agent-cpu-demo-worker-cpu-high',
  metric: service.metricCpuUtilization({ period: cdk.Duration.minutes(1) }),
  threshold: 70,
  evaluationPeriods: 3,
  datapointsToAlarm: 3,
  comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
  treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
});
```

Webhookのトークンは、コードには書かずSecrets Managerに保存しました。
`Bearer ` を付けた形で保存しておくと、接続がそのままAuthorizationヘッダに入れて送ります。

```bash
read -s "TOKEN?API key: " && aws secretsmanager create-secret --region ap-northeast-1 --name devops-agent-cpu-demo/webhook-token --secret-string "Bearer $TOKEN" && unset TOKEN
```

EventBridgeルールは、対象のアラームがALARMになったイベントだけを拾います。
入力トランスフォーマーで、アラームのイベントをWebhookの形式に組み替えています。

```ts:lib/cpu-demo-stack.ts
const connection = new events.Connection(this, 'DevOpsAgentWebhookConnection', {
  authorization: events.Authorization.apiKey(
    'Authorization',
    cdk.SecretValue.secretsManager('devops-agent-cpu-demo/webhook-token'),
  ),
});

const destination = new events.ApiDestination(this, 'DevOpsAgentWebhookDestination', {
  connection,
  endpoint: '<Webhook の URL>',
  httpMethod: events.HttpMethod.POST,
  rateLimitPerSecond: 1,
});

new events.Rule(this, 'CpuAlarmToDevOpsAgentRule', {
  eventPattern: {
    source: ['aws.cloudwatch'],
    detailType: ['CloudWatch Alarm State Change'],
    detail: { alarmName: [cpuAlarm.alarmName], state: { value: ['ALARM'] } },
  },
  targets: [
    new targets.ApiDestination(destination, {
      event: events.RuleTargetInput.fromObject({
        eventType: 'incident',
        incidentId: events.EventField.eventId, // アラームごとに一意になる
        action: 'created',
        priority: 'MEDIUM',
        title: `CPU 使用率の上昇: ${events.EventField.fromPath('$.detail.alarmName')}`,
        description:
          `ECS サービス ${service.serviceName} の CPU 使用率がしきい値を超えました。` +
          `アラーム理由: ${events.EventField.fromPath('$.detail.state.reason')}。` +
          'CloudWatch Logs のワーカーログと GitHub リポジトリのソースコードを突き合わせ、' +
          'CPU を消費している関数とコード箇所を特定してください。そのうえで、具体的なリファクタリング案（修正後のコード例を含む）を提示してください。',
        timestamp: events.EventField.time,
        service: 'devops-agent-cpu-demo',
      }),
    }),
  ],
});
```

コードを見て改善案を出すよう指示する文は、`description` に入れています。
Webhookのペイロードには `data` という自由欄もありますが、ここに書いてもエージェントには届きません。

> The webhook accepts data, but doesn't include its contents in the investigation context. Only title, description, priority, and the incident reference reach the agent.
> — [Invoking DevOps Agent through Webhook - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-invoking-devops-agent-through-webhook.html)

和訳すると「Webhookは `data` を受け付けますが、その中身は調査の文脈に含めません。エージェントに届くのは、title、description、priorityと、インシデントの参照だけです」となります。
なお、Webhook作成画面に表示されるスキーマの説明では、`data` は「元のイベントを添付する欄」と書かれていて、ドキュメントとは書き方が違いました。

## 疎通を確認してから配線する

いきなりアラームとつなぐ前に、Webhookを `curl` で1回叩きました。
APIキー方式のドキュメントの例には `x-amzn-event-timestamp` ヘッダが付いていますが、EventBridgeのAPI送信先はこのヘッダを付けません。
ヘッダなしで通るかを先に確かめておきたかったためです。

```bash
AUTH=$(aws secretsmanager get-secret-value --region ap-northeast-1 --secret-id devops-agent-cpu-demo/webhook-token --query SecretString --output text) && curl -sS -w "\nHTTP %{http_code}\n" -X POST "<Webhook の URL>" -H "Content-Type: application/json" -H "Authorization: $AUTH" -d "{\"eventType\":\"incident\",\"incidentId\":\"curl-test-$(date +%s)\",\"action\":\"created\",\"priority\":\"LOW\",\"title\":\"Webhook 疎通テスト\",\"description\":\"Webhook の疎通確認です。\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"service\":\"devops-agent-cpu-demo\"}"; unset AUTH
```

実行結果です。

```
{"message": "Webhook received"}
HTTP 200
```

Web Appの「インシデントレスポンス」にも、「Webhook 疎通テスト」という調査が作られました。
タイムスタンプのヘッダがなくても、APIキー方式なら調査が始まることが確認できました。

### ワーカーを先に動かすとアラームが鳴りっぱなしになる

CDKの最初のデプロイでは、ECSサービスのタスク数を0にしておきました。
EventBridgeルールが拾うのは、アラームがALARMに「変わった」イベントだけです。
配線より先にワーカーが動いてCPUが上がると、アラームはALARMのまま止まり、配線後に状態が変わらないので調査が起動しません。
Webhookの疎通を確かめてから、タスク数を1にしてデプロイしました。

## 実際に動かしてみた

CPUは毎分少しずつ上がり、20分ほどかけてしきい値を超える想定でした。

実際には、タスクが動き始めて2分ほどでCPUが100%に達しました。

| 時刻 | CPU使用率（1分平均） |
|---|---|
| 13:23 | 34% |
| 13:24 | 85% |
| 13:25 | 94% |
| 13:26 | 100% |
| 13:27 | 100% |

Fargateの0.25vCPUは、手元のMacよりかなり遅いようです。
件数が増え始めてすぐの6,000件台の段階で、CPUが上限に達していました。

そこからの流れは、次のとおりです。

| 時刻 | 出来事 |
|---|---|
| 13:29:53 | アラームがALARMになる |
| 13:29:54 | EventBridgeルールが1回動き、Webhookを呼ぶ（失敗0件） |
| 13:29:54 | 調査「CPU 使用率の上昇: devops-agent-cpu-demo-worker-cpu-high」が始まる |
| 13:42:49 | 調査が終わる |

アラームがALARMになってから1秒で調査が始まり、約13分で終わりました。

![インシデントレスポンスの一覧。アラーム起点の調査が Event Channel から起動され、完了している](/images/devops-agent-cpu-alarm-webhook-no-lambda/incident-list.png)

## 調査レポートの中身

エージェントは、メトリクスとログを読むサブエージェントと、デプロイ履歴とコードを読むサブエージェントを並行して動かしていました。
両方の結果から、根本原因は重複除去の関数だと特定しています。

![調査レポートの概要。根本原因として重複除去の関数と行番号が挙がっている](/images/devops-agent-cpu-alarm-webhook-no-lambda/root-cause.png)

レポート内の関数名は `dedupeUploads` になっています。
検証時のコードではこの名前で、記事のコードでは一般的な名前に置き換えています。

レポートに挙がったCPU消費箇所は、優先度の順に次の4つです。

| 箇所 | 内容 |
|---|---|
| 重複除去の関数（36〜44行目） | O(n²)。ログ上、処理時間のほぼ100%を占める |
| 件数を決める関数（14〜17行目） | 毎分300件ずつ件数が増える |
| 種別の振り分け（47〜53行目） | 要素ごとに `new RegExp()` を作り直している |
| `setInterval`（76行目） | 重い処理を1秒ごとに実行し続ける |

行番号は、リポジトリのコードと一致していました。
ログの裏付けとして、件数が8,167件のバッチで、全体1,526ミリ秒のうち重複除去が1,521ミリ秒だったことが挙げられています。

改善案は、すぐできる緩和策と恒久対策の2段に分かれていました。
緩和策は、環境変数で件数の増加を止めつつCPUを増やす案で、準備、事前確認、適用、事後確認、切り戻しのECSのコマンドまで付いています。
恒久対策には、修正後のコードが示されていました。

```js
function dedupeOrders(orders) {
  const seen = new Set();
  const unique = [];
  for (const order of orders) {
    if (!seen.has(order.orderId)) {
      seen.add(order.orderId);
      unique.push(order);
    }
  }
  return unique;
}
```

受け入れ基準として、「重複除去の結果（件数と順序）が従来の実装と一致すること」も添えられていました。
また、commitが1件しかないことから、デプロイが引き金ではないとしてロールバックは不適と判断しています。

### 答えを見つけやすくするヒントが残っていた

この結果は、そのまま実際のサービスに当てはまるとは言えません。
理由が2つあります。

1つめは、コードのコメントです。
ワーカーのコードからは意図的な実装と分かるコメントを消していましたが、CDKスタックの冒頭に「わざとCPUを使うワーカー」というコメントが残っていました。
レポートの所見は、このコメントを根拠の1つに挙げています。
ただし、根本原因の特定はログとコードの分析から先に出ており、コメントは補足として使われていました。

2つめは、ログの粒度です。
今回のワーカーは処理ごとの所要時間をログに出しているので、どの関数が重いかがログだけでほぼ分かります。
実際のサービスで、ここまで細かいログを出していることは多くないと思います。

コメントはすでに消したので、同じ条件でもう一度調査を流せば、コメントなしでも同じ結論になるかを確かめられます。
今回は試していません。

## 気をつけること

- **CloudFormationで作れない部分がある**: GitHubの登録、汎用Webhookの作成、週次評価の停止はコンソールで操作します。カスタムエージェントのイベントトリガーも、CloudFormationの `AWS::DevOpsAgent::Trigger` は定期実行（`TIME_BASED`）にしか対応していませんでした（2026年10月時点）
- **週次評価は既定で有効**: Agent Spaceを作ると、週1回の評価が自動で登録されます。検証用のスペースなら、Web Appの「改善事項」ページで「スケジュールを一時停止」にしておくと、意図しない課金を防げます
- **GitHub Appのリポジトリ範囲**: GitHub Appのインストール時に「All repositories」を選ぶと、すべてのリポジトリへの読み書きを許可することになります。あとからGitHubのSettings > Applications > Installed GitHub Appsで絞れます
- **CloudTrailはこの環境では使えなかった**: 前のタスクが入れ替わった理由をエージェントがCloudTrailで調べようとしましたが、この環境では使えず、レポートには「不明」として残りました。根本原因の判断には影響していません

## まとめ

CloudWatchアラームから、LambdaなしでDevOps Agentの調査を起動できました。
APIキー方式のWebhookを選べば、EventBridgeのAPI送信先から直接呼べます。
調査はGitHubのコードとログを突き合わせ、重い関数を行番号まで特定し、修正後のコードまで出してくれました。

一方で、今回はログが細かく、コメントにもヒントが残っていたので、条件はかなり有利でした。
CPUがじわじわ上がる傾向をつかめるか、カスタムエージェントのイベントトリガーで受けるとどう変わるかも、まだ試せていません。
次は、ヒントを消した状態で、もう少し現実に近いログの粒度で試してみたいと思います。

アラームの調査をコードまでつなげたい方の参考になれば嬉しいです。

## 参考

- [Invoking DevOps Agent through Webhook - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-invoking-devops-agent-through-webhook.html)
- [Connecting GitHub - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/connecting-to-cicd-pipelines-connecting-github.html)
- [Executing custom agents - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/custom-agents-executing-custom-agents.html)
- [Proactive incident prevention - AWS DevOps Agent](https://docs.aws.amazon.com/devopsagent/latest/userguide/production-operations-proactive-incident-prevention.html)
- [Amazon EventBridge API destinations - Amazon EventBridge](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-api-destinations.html)
