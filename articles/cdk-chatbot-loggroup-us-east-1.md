---
title: "us-east-1 に作られる AWS Chatbot のロググループに、CDK で保持期間を入れる方法を確かめてみた"
emoji: "🌎"
type: "tech"
topics: ["aws", "cdk", "cloudwatchlogs", "chatbot"]
published: false
---

こんにちは、クラスメソッド製造ビジネステクノロジー部のはすとです。

CloudWatch Logs の保持期間を揃える作業をしていて、AWS Chatbot のロググループだけが見つからないということがありました。CDK のコードは ap-northeast-1 のスタックに書いてあるのに、東京リージョンのロググループ一覧に出てきません。

探してみると us-east-1 にありました。しかも保持期間は無期限のままです。

公式にも明記されていました。

> Your Amazon Q Developer in chat applications logs will be sent to CloudWatch under a designated CloudWatch Logs group for your configuration. The group name is `/aws/chatbot/configuration-name`.
> You can view your logs in the Amazon CloudWatch console. Note that you must specify **US East (N. Virginia)** for the Region.
> — [Accessing Amazon CloudWatch Logs for Amazon Q Developer in chat applications](https://docs.aws.amazon.com/chatbot/latest/adminguide/cloudwatch-logs.html)

本記事ではこれを実際に再現して、CDK からどう保持期間を入れるのかを確認してきます。

## 検証環境

- aws-cdk-lib 2.269.0
- AWS CDK CLI 2.1141.0
- スタックのリージョン: ap-northeast-1

Slack ワークスペースの認可（AWS コンソールでの OAuth）は済んでいる前提とします。

## 何を確かめるか

1. Chatbot の設定を ap-northeast-1 にデプロイする
2. 通知を 1 回飛ばして、ロググループがどのリージョンにできるかを見る
3. リージョンを指定せずに保持期間を入れてみる
4. 公式のとおり us-east-1 を指定して入れ直す
5. `removalPolicy: DESTROY` を渡して削除してみる

## 検証に使用する CDK のコード

`chatbot.CfnSlackChannelConfiguration` で定義します。IAM ロールは自分で作り、ARN を渡します。

```typescript
export const CONFIGURATION_NAME = "verify-chatbot-logs";

export class ChatbotLogsStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const topic = new sns.Topic(this, "Topic", {
      topicName: "verify-chatbot-logs-topic",
    });

    const chatbotRole = new iam.Role(this, "ChatbotRole", {
      assumedBy: new iam.ServicePrincipal("chatbot.amazonaws.com"),
    });

    new chatbot.CfnSlackChannelConfiguration(this, "SlackChannel", {
      configurationName: CONFIGURATION_NAME,
      iamRoleArn: chatbotRole.roleArn,
      slackChannelId: SLACK_CHANNEL_ID,
      slackWorkspaceId: SLACK_WORKSPACE_ID,
      snsTopicArns: [topic.topicArn],
      loggingLevel: "INFO",
    });
  }
}
```

`loggingLevel` を指定しているのには理由があります。**既定は `NONE` で、書かないとログが出ません。** ロググループもできないので、探しても見つからないことになります。

スタックは ap-northeast-1 に置きます。

```typescript
// bin/app.ts
new ChatbotLogsStack(app, "VerifyChatbotLogs", {
  env: { region: "ap-northeast-1" },
});
```

この時点でロググループの定義はどこにも書いていません。

## 1. デプロイしただけではロググループはできない

```bash
pnpm exec cdk deploy VerifyChatbotLogs --require-approval never
```

デプロイ後に両方のリージョンを見ても、ロググループはありません。

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/chatbot --region ap-northeast-1
aws logs describe-log-groups --log-group-name-prefix /aws/chatbot --region us-east-1
```

```text
ap-northeast-1   []
us-east-1        []
```

設定を作った時点では作られない、ということです。

## 2. 通知を 1 回飛ばすと us-east-1 にできる

SNS に publish して、Chatbot に処理させます。Chatbot は受け取ったメッセージを解釈して Slack 向けに整形するので、対応している形式で送ります。ここでは CloudWatch アラームの通知と同じ形の JSON を用意しました。

```json
{
  "AlarmName": "verify-chatbot-logs-alarm",
  "AlarmDescription": "us-east-1 にログが出るかの検証用",
  "AWSAccountId": "<account>",
  "NewStateValue": "ALARM",
  "NewStateReason": "Threshold Crossed: 1 datapoint [1.0] was greater than the threshold (0.0).",
  "StateChangeTime": "2026-09-18T13:35:00.000+0000",
  "Region": "Asia Pacific (Tokyo)",
  "AlarmArn": "arn:aws:cloudwatch:ap-northeast-1:<account>:alarm:verify-chatbot-logs-alarm",
  "OldStateValue": "OK",
  "Trigger": {
    "MetricName": "Errors",
    "Namespace": "AWS/Lambda",
    "Statistic": "SUM",
    "Dimensions": [],
    "Period": 300,
    "EvaluationPeriods": 1,
    "ComparisonOperator": "GreaterThanThreshold",
    "Threshold": 0.0
  }
}
```

```bash
aws sns publish \
  --topic-arn arn:aws:sns:ap-northeast-1:<account>:verify-chatbot-logs-topic \
  --subject "ALARM: verify-chatbot-logs-alarm" \
  --message file://alarm.json \
  --region ap-northeast-1
```

Slack に通知が届きました。

![Slack に届いた Amazon Q Developer からの CloudWatch アラーム通知](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789869572/2026/09/20/nyz0eqcyjpzrz5greimz.png)

タイトルに `ap-northeast-1` と入っているとおり、東京リージョンのアラームとして届いています。

改めて両方のリージョンを見ます。東京は空のままですが、バージニア北部に切り替えると出てきます。保持は **失効しない** です。

![バージニア北部のロググループ一覧。1 match で保持が「失効しない」](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789869585/2026/09/20/kbbf46r9qhjbzvt4hz1q.png)

**スタックは ap-northeast-1 にあるのに、ロググループは us-east-1 にできています。** 公式の記述どおりです。

ログの中身も見てみます。

```bash
aws logs get-log-events --log-group-name /aws/chatbot/verify-chatbot-logs \
  --log-stream-name <ストリーム名> --region us-east-1
```

```text
Sending message to Slack (Workspace: <workspace-id>, Channel: aws-test) with title:
🚨 CloudWatch Alarm | verify-chatbot-logs-alarm | ap-northeast-1 | Account: <account>
```

ログの本文には `ap-northeast-1` と書いてあるのに、その記録自体は us-east-1 に置かれている、という状態です。

## 3. リージョンを指定せずに保持期間を入れてみる

ここからが本題です。ロググループを作るのは Chatbot であって CloudFormation ではないので、`AWS::Logs::LogGroup` としては定義できません。なので、保持期間を入れるため `logs.LogRetention` を使います。

ログの出力先は us-east-1 だと分かっているので、リージョンを指定しなくてもそのロググループに入りそうです。まずはそのまま書いてみます。

```typescript
new logs.LogRetention(this, "ChatbotLogRetention", {
  logGroupName: `/aws/chatbot/${CONFIGURATION_NAME}`,
  retention: logs.RetentionDays.TWO_WEEKS,
  // logGroupRegion を指定しない
});
```

`cdk diff` で増えるのは 4 つです。

```text
Resources
[+] Custom::LogRetention ChatbotLogRetention
[+] AWS::IAM::Role LogRetention.../ServiceRole
[+] AWS::IAM::Policy LogRetention.../ServiceRole/DefaultPolicy
[+] AWS::Lambda::Function LogRetention...
```

`Custom::LogRetention` は CloudFormation の標準のリソースタイプではありません。CloudFormation 自身は処理のしかたを知らないので、代わりに Lambda を呼び出して任せます。この Lambda が CDK に組み込まれていて、`logs.LogRetention` を書くとスタックに自動で追加されます。差分に出ている残り 3 つ（Lambda・実行ロール・ポリシー）がそれです。以降この Lambda を**ハンドラ**と呼びます。

ハンドラはスタックの作成・更新・削除のたびに CloudFormation から呼ばれ、CloudWatch Logs の API を直接叩きます。今回であれば `CreateLogGroup`（既にあれば無視）を呼んだあと `PutRetentionPolicy` を呼ぶ、という動きです。保持期間を入れる作業を CloudFormation の外に出している、と考えると分かりやすいと思います。

**デプロイは成功します。** エラーは一切出ません。

```bash
pnpm exec cdk deploy VerifyChatbotLogs --require-approval never
```

ところが結果はこうなりました。保持期間に加えて、ログの保存量（`storedBytes`）も一緒に見ます。

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/chatbot --region ap-northeast-1 \
  --query 'logGroups[].{logGroupName:logGroupName,retentionInDays:retentionInDays,storedBytes:storedBytes}'
```

```json
// ap-northeast-1
[
    {
        "logGroupName": "/aws/chatbot/verify-chatbot-logs",
        "retentionInDays": 14,
        "storedBytes": 0
    }
]

// us-east-1
[
    {
        "logGroupName": "/aws/chatbot/verify-chatbot-logs",
        "retentionInDays": null,
        "storedBytes": 0
    }
]
```

**東京に同名のロググループが新しく作られ、そちらに 14 日が入りました。** コンソールでもそう見えます。

![東京リージョンのロググループ一覧。保持が「2 週間」になっている](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789869591/2026/09/20/ecm5jhailjzgm9odgfch.png)

一見うまくいったように見えますが、東京側の `storedBytes` が 0 です。ログが 1 バイトも入っていません。Chatbot が書いているのは us-east-1 のほうなので、**このロググループには今後も誰も書き込みません。** そして本物の保持期間は無期限のままです。

原因はカスタムリソースのハンドラにあります。

```javascript
let r = e.ResourceProperties.LogGroupRegion;            // 未指定なら undefined
let c = new i.CloudWatchLogsClient({ logger: console, region: r });
// Create / Update で CreateLogGroup（既存なら無視）→ PutRetentionPolicy
```

`logGroupRegion` を省くと SDK クライアントがスタックのリージョンになります。そして `CreateLogGroup` を先に呼ぶので、東京に無ければ**作ってしまいます**。名前が同じなので、コンソールだけ見ていると設定できたように見えるのが厄介です。

`cdk deploy` は成功し、`cdk diff` もきれいで、ドリフトも出ません。

## 4. 公式のとおり us-east-1 を指定する

`logGroupRegion` を足します。

```typescript
new logs.LogRetention(this, "ChatbotLogRetention", {
  logGroupName: `/aws/chatbot/${CONFIGURATION_NAME}`,
  logGroupRegion: "us-east-1",
  retention: logs.RetentionDays.TWO_WEEKS,
});
```

今度は本物に入ります。東京側には何も作られません。

```json
// ap-northeast-1
[]

// us-east-1
[
    {
        "logGroupName": "/aws/chatbot/verify-chatbot-logs",
        "retentionInDays": 14,
        "storedBytes": 0
    }
]
```

IAM ポリシーを見ると、保持期間の権限はリソース指定が `*` です。だから別リージョンにも届きます。

```yaml
- Action:
    - logs:PutRetentionPolicy
    - logs:DeleteRetentionPolicy
  Effect: Allow
  Resource: "*"
```

なお、ステップ 3 で東京にできてしまったロググループは、コードから消えても残るため、手動で削除が必要です。

```bash
aws logs delete-log-group --log-group-name /aws/chatbot/verify-chatbot-logs --region ap-northeast-1
```

### SlackChannelConfiguration ならリージョンを書かなくてよい

ここまで `CfnSlackChannelConfiguration` で書いてきましたが、`SlackChannelConfiguration` には `logRetention` プロパティがあります。中身はこうです。

```javascript
props.logRetention && new logs.LogRetention(this, "LogRetention", {
  logGroupName: `/aws/chatbot/${props.slackChannelConfigurationName}`,
  retention: props.logRetention,
  role: props.logRetentionRole,
  logGroupRegion: "us-east-1",        // 固定値
  logRetentionRetryOptions: props.logRetentionRetryOptions
})
```

このように、`us-east-1` がハードコードされています。「Chatbot のログは us-east-1 に出る」ことを CDK 自身が前提にしているわけです。こちらを使えばステップ 3 の間違いは起こりません。

```typescript
new chatbot.SlackChannelConfiguration(this, "SlackChannel", {
  // ...
  logRetention: logs.RetentionDays.TWO_WEEKS,
});
```

`CfnSlackChannelConfiguration` のままでも、`logGroupRegion: "us-east-1"` を明示すれば同じことになります。

## 5. removalPolicy: DESTROY を渡すと削除に失敗する

スタックを消したときにロググループも消したいため、`removalPolicy` に `DESTROY`を指定しますが、ここにも落とし穴があります。

```typescript
new logs.LogRetention(this, "ChatbotLogRetention", {
  logGroupName: `/aws/chatbot/${CONFIGURATION_NAME}`,
  logGroupRegion: "us-east-1",
  retention: logs.RetentionDays.TWO_WEEKS,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
});
```

`cdk synth` すると IAM に削除の権限が増えますが、噛み合っていません。

```yaml
- Action: logs:DeleteLogGroup
  Effect: Allow
  Resource:
    Fn::Join:
      - ""
      - - "arn:"
        - Ref: AWS::Partition
        - ":logs:ap-northeast-1:"          # スタックのリージョン
        - Ref: AWS::AccountId
        - :log-group:/aws/chatbot/verify-chatbot-logs:*
```

`logGroupRegion: "us-east-1"` と書いたのに、削除権限の ARN は `ap-northeast-1` です。`cdk destroy` すると失敗します。

```text
Received response status [FAILED] from custom resource. Message returned:
User: arn:aws:sts::<account>:assumed-role/VerifyChatbotLogs-LogRetention... is not authorized
to perform: logs:DeleteLogGroup on resource:
arn:aws:logs:us-east-1:<account>:log-group:/aws/chatbot/verify-chatbot-logs
because no identity-based policy allows the logs:DeleteLogGroup action
```

スタックは `DELETE_FAILED` で止まります。

![CloudFormation のイベント。スタックが DELETE_FAILED になっている](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789871455/2026/09/20/q40yqueub2ngttv18mv2.png)

### なぜこうなるのか

ここからは `aws-cdk-lib` の中の話です。`removalPolicy: DESTROY` を指定すると、CDK はハンドラのロールに削除権限を足します。その処理が `grantDeleteLogGroup` で、対象の ARN を `formatArn` で組み立てていますが、ここに `region` を渡していません。

```javascript
grantDeleteLogGroup(logGroupName) {
  this.role.addToPrincipalPolicy(new iam.PolicyStatement({
    actions: ["logs:DeleteLogGroup"],
    resources: [Stack.of(this).formatArn({
      service: "logs",
      resource: "log-group",
      resourceName: `${logGroupName}:*`,
      arnFormat: ArnFormat.COLON_RESOURCE_NAME
    })]
  }));
}
```

`formatArn` は `region` を省くとスタックのリージョンを使うので、できあがる ARN は `ap-northeast-1` のものになります。ここに `props.logGroupRegion` が渡っていれば正しい ARN になるのですが、このコードは `aws-cdk-lib` の内部なので、利用者が差し込む手段はありません。呼び出し側を見ても、渡しているのはロググループ名だけです。

```javascript
const provider = this.ensureSingletonLogRetentionFunction(props);
props.removalPolicy === cdk.RemovalPolicy.DESTROY && provider.grantDeleteLogGroup(props.logGroupName);
```

`props.logGroupRegion` が渡らないので、この処理はそもそも us-east-1 を知りません。一方ハンドラは `LogGroupRegion` で SDK クライアントを作るため、API は us-east-1 に届きます。**届いた先の ARN と、権限の ARN が一致しない**というのが失敗の理由です。

同じコンストラクトの中でも扱いが割れていて、公開される `logGroupArn` のほうは `region` を渡しています。

```javascript
this.logGroupArn = Stack.of(this).formatArn({ region: props.logGroupRegion, service: "logs", ... });
```

対処としては `removalPolicy` を指定しないのが素直です。`SlackChannelConfiguration` の `logRetention` は props に `removalPolicy` が無いので、そもそも渡す口がありません。ロググループはスタックを消しても残りますが、保持期間が入っていれば中身は期限切れで消えますし、空のロググループに費用はかかりません。

### 削除までCDKに任せたい場合の解決策

とはいえ、削除まで CDK に任せたい場合は、`LogRetention` の `role` に自前のロールを渡す方法が使えます。`role` を指定すると、CDK が作る既定のロールの代わりにそちらがハンドラのロールになります。

```typescript
const logRetentionRole = new iam.Role(this, "LogRetentionRole", {
  assumedBy: new iam.ServicePrincipal("lambda.amazonaws.com"),
  managedPolicies: [
    iam.ManagedPolicy.fromAwsManagedPolicyName("service-role/AWSLambdaBasicExecutionRole"),
  ],
});
logRetentionRole.addToPolicy(
  new iam.PolicyStatement({
    actions: ["logs:DeleteLogGroup"],
    resources: [
      `arn:aws:logs:us-east-1:${cdk.Stack.of(this).account}:log-group:${LOG_GROUP_NAME}:*`,
    ],
  }),
);

new logs.LogRetention(this, "ChatbotLogRetention", {
  logGroupName: LOG_GROUP_NAME,
  logGroupRegion: "us-east-1",
  retention: logs.RetentionDays.TWO_WEEKS,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
  role: logRetentionRole,
});
```

`cdk synth` すると、自分で付けた us-east-1 の ARN と、CDK が足す ap-northeast-1 の ARN が両方並びます。

```yaml
- Action: logs:DeleteLogGroup
  Resource: arn:aws:logs:us-east-1:<account>:log-group:/aws/chatbot/verify-chatbot-logs:*
- Action:
    - logs:PutRetentionPolicy
    - logs:DeleteRetentionPolicy
  Resource: "*"
- Action: logs:DeleteLogGroup
  Resource: arn:aws:logs:ap-northeast-1:<account>:log-group:/aws/chatbot/verify-chatbot-logs:*
```

権限は加算なので、余計なほうが残っていても問題ありません。この状態で `cdk destroy` すると、今度は失敗せずにロググループごと削除されました。

```text
✅  VerifyChatbotLogs: destroyed
```

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/chatbot --region us-east-1
```

```json
[]
```

## 後片付け

`removalPolicy` と `role` の指定によって、`cdk destroy` したあとに何が残るかが変わります。

| 書き方 | `cdk destroy` | us-east-1 のロググループ | 手動削除 |
|---|---|---|---|
| `removalPolicy` を指定しない | 成功 | 残る | 必要（または放置） |
| `removalPolicy: DESTROY` のみ | **`DELETE_FAILED`** | 残る | 必要 |
| `removalPolicy: DESTROY` + 自前の `role` | 成功 | 消える | 不要 |

`removalPolicy` を指定しない場合は、そもそもロググループを消す処理がありません。保持期間が入っていれば中身は期限切れで消えていきますし、空のロググループに費用はかからないので、放置しても問題ないです。

`DELETE_FAILED` になったスタックは、失敗したリソースを残す指定で削除できます。

```bash
aws cloudformation delete-stack --stack-name VerifyChatbotLogs \
  --region ap-northeast-1 --retain-resources ChatbotLogRetentionB9B9A71C
```

`--retain-resources` に指定したリソースは削除されず、その削除処理も走りません。ロググループを消すはずだった処理がスキップされるので、手で消すことになります。

```bash
aws logs delete-log-group --log-group-name /aws/chatbot/verify-chatbot-logs --region us-east-1
```

ステップ 3 で東京にできたロググループは、上の表とは事情が違います。リージョン指定を直した時点でテンプレートからもカスタムリソースからも参照されなくなり、**どの書き方でも完全に管理外**になります。`cdk destroy` しても残るので、忘れずに消してください。

```bash
aws logs delete-log-group --log-group-name /aws/chatbot/verify-chatbot-logs --region ap-northeast-1
```

## まとめ

ap-northeast-1 に定義した Chatbot でも、ロググループは us-east-1 に作られます。公式にも、ログを見るときは US East (N. Virginia) を指定するよう書かれています。作られるタイミングは設定をデプロイした時点ではなく、最初に通知を処理した時点でした。保持期間は無期限なので、放っておくとログが溜まり続けます。

保持期間を入れるには `logs.LogRetention` を使いますが、**`logGroupRegion: "us-east-1"` を忘れないでください。** 忘れてもデプロイは成功し、`cdk diff` もドリフトもきれいなままです。ただし東京に同名の空のロググループが作られ、そちらに保持期間が入るだけで、実際にログが溜まる us-east-1 のほうは無期限のまま残ります。コンソール上は設定できたように見えるので、気づきにくいのが厄介です。`SlackChannelConfiguration` を使う場合は `logRetention` を渡すだけでよく、リージョンは CDK が `us-east-1` で指定してくれます。

`removalPolicy: DESTROY` を渡すと、今度はスタック削除時に `logs:DeleteLogGroup` が AccessDenied になります。API は `logGroupRegion` のリージョンへ飛ぶのに、権限の ARN はスタックのリージョンで組まれるためです。`removalPolicy` を指定しないでおくか、us-east-1 の ARN を許可した自前のロールを `role` に渡せば回避できます。`SlackChannelConfiguration` にはこのプロパティ自体が無いので、そちらを使っているぶんには踏みません。

Chatbot のロググループが us-east-1 にあることは知っていても、CDK から保持期間や削除ポリシーをどう設定すればよいか迷っている方の参考になれば幸いです。

## 参考

- [Accessing Amazon CloudWatch Logs for Amazon Q Developer in chat applications](https://docs.aws.amazon.com/chatbot/latest/adminguide/cloudwatch-logs.html)
- [class SlackChannelConfiguration - AWS CDK API Reference](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_chatbot.SlackChannelConfiguration.html)
- [class LogRetention - AWS CDK API Reference](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_logs.LogRetention.html)
- [AWS::Chatbot::SlackChannelConfiguration - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-chatbot-slackchannelconfiguration.html)
