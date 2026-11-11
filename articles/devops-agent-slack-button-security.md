---
title: "Slack通知のボタンから、Lambda経由でAWS DevOps Agentの調査を起動してみた"
emoji: "🔘"
type: "tech"
topics: ["aws", "devopsagent", "slack", "amazonq", "lambda"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

前回は、CloudWatchアラームをきっかけにAWS DevOps Agentの調査を自動で始める構成を作りました。

https://dev.classmethod.jp/articles/devops-agent-cpu-alarm-webhook-no-lambda/

動かしてみると便利なのですが、調査は実行時間に応じて課金されるため、アラームが鳴るたびに調査が始まると費用がかさみます。
そこで今回は「人がSlackの通知のボタンを押したときだけ調査する」形にできないかと考えました。

ただ、Slackにボタンを置くと、今度は「誰でも押せてしまうのでは」「ボタンはどんな権限で動くのか」というセキュリティ面が気になります。
本記事では、Amazon Q Developer in chat applications（旧AWS Chatbot）のカスタムアクションでボタンを作り、押すとLambda経由でDevOps Agentの調査を発火させる仕組みと、セキュリティ面を確かめた結果をまとめます。

## 検証環境

2026年10月時点の情報です。

- リージョン: 東京（ap-northeast-1）
- Slack: プライベートチャンネル。Amazon Qのアプリを招待済み
- AWS CDK: aws-cdk-lib 2.272.0
- Lambda: Node.js 22、`@aws-sdk/client-devops-agent` 3.1152.0
- 調査の対象: ECS FargateのCPU使用率のアラーム

## 仕組み

ボタンを押してから調査が始まるまでの流れは、次のようになります。

![構成図。Slackのプライベートチャンネルのアラーム通知にあるボタンをメンバーが押すと、Amazon Q Developer in chat applicationsがチャンネルロールでlambda invokeを実行し、Lambdaが許可リストの照合とアラームの状態の確認をしてからCreateBacklogTaskでDevOps Agentの調査を作る。通知自体はCloudWatchアラームからSNSトピックを経由してAmazon Qが投稿する](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203017/2026/10/17/gxck7ygpboyg06rciukz.png)

ボタンの正体は、Amazon Qの**カスタムアクション**です。
通知にボタンを付けておき、押されたらAWS CLIのコマンドを実行する仕組みで、コマンドには通知の値を変数として埋め込めます。
ここでは、アラーム名を入れた`lambda invoke`を実行します。

呼ばれたLambdaは、アラーム名が許可リストにあるか、そのアラームが今ALARMかを確かめてから、DevOps Agentの`CreateBacklogTask` APIで調査を作ります。
Webhookは使わないため、トークンの保管もEventBridgeのルールも要りません。

公式ドキュメントには、カスタムアクションの権限について次のように書かれています。

> No additional permissions are needed to configure or run custom actions. When your channel members choose the custom action button, the action target is invoked using the configured IAM permissions in your channel configuration.
>
> （カスタムアクションの設定や実行に追加の権限は要りません。チャンネルのメンバーがボタンを選ぶと、チャンネル設定に構成されたIAMの権限でアクションの対象が呼び出されます）
>
> [Custom actions using Amazon Q Developer in chat applications](https://docs.aws.amazon.com/chatbot/latest/adminguide/custom-actions.html)

つまり、ボタンを押したときに使われるのは、チャンネル設定に付けたIAMロール（チャンネルロール）の権限です。
押した人のAWSの権限ではありません。

なお、Amazon QのCLI実行から`devops-agent`のコマンドを直接呼べれば一番簡単なのですが、試したところ`Internal Failure`になり使えませんでした。
Lambdaを挟んでいるのはそのためです。

## 作ったもの

CDKで作ったものは次の4つです。

| 作るもの | 役割 |
|---|---|
| Lambdaとそのロール | 許可リストと状態の確認、`CreateBacklogTask`の呼び出し |
| チャンネルロールとガードレール | ボタンが使う権限と、チャンネルから使える権限の上限 |
| カスタムアクション | 通知に出すボタンと、押したときに実行するコマンド |
| Amazon Qのチャンネル設定 | SNSトピックの購読、チャンネルロール、ガードレール、ボタンの登録 |

### Lambda

`clientToken`に「アラーム名と時刻（1時間単位）」を入れているため、同じアラームのボタンを同じ1時間の間に何度押しても、調査は1件になります。
戻り値の文字列は、Amazon QがそのままSlackのスレッドに投稿します。

```javascript
import { CloudWatchClient, DescribeAlarmsCommand } from "@aws-sdk/client-cloudwatch";
import { DevOpsAgentClient, CreateBacklogTaskCommand } from "@aws-sdk/client-devops-agent";

const cloudwatch = new CloudWatchClient({});
const devopsAgent = new DevOpsAgentClient({});
const agentSpaceId = process.env.AGENT_SPACE_ID;
const allowedAlarms = (process.env.ALLOWED_ALARMS ?? "").split(",").filter(Boolean);

export const handler = async (event) => {
  const alarmName = event?.alarmName;
  // 許可リスト: 対象のアラーム以外は調査を作らない
  if (!allowedAlarms.includes(alarmName)) {
    return `\`${alarmName}\` は調査の対象ではありません。`;
  }
  // 今 ALARM のものだけ調査する（OK に戻った通知から押しても始めない）
  const { MetricAlarms = [] } = await cloudwatch.send(new DescribeAlarmsCommand({ AlarmNames: [alarmName] }));
  const alarm = MetricAlarms[0];
  if (alarm?.StateValue !== "ALARM") {
    return `\`${alarmName}\` は今 ${alarm?.StateValue} なので調査を始めません。`;
  }
  // 同じアラームで同じ 1 時間の間に何度押しても、調査は 1 件にする（clientToken は冪等キー）
  const hour = new Date().toISOString().slice(0, 13).replace(/[-T:]/g, "");
  const clientToken = `${alarmName}-${hour}`.slice(0, 64);

  const { task } = await devopsAgent.send(
    new CreateBacklogTaskCommand({
      agentSpaceId,
      clientToken,
      taskType: "INVESTIGATION",
      priority: "MEDIUM",
      title: `Slack から調査依頼: ${alarmName}`,
      description: `Slack のアラーム通知のボタンから調査の依頼がありました。対象は CloudWatch アラーム ${alarmName} です。アラームの理由: ${alarm.StateReason}。...`,
    }),
  );
  return `調査を作りました: ${task.taskId}（状態 ${task.status}）`;
};
```

Lambdaのロールには、`aidevops:CreateBacklogTask`（このAgent Spaceだけ）と`cloudwatch:DescribeAlarms`を付けます。

```typescript
const investigateFn = new NodejsFunction(this, 'InvestigateFunction', {
  entry: 'lambda/investigate/index.mjs',
  runtime: lambda.Runtime.NODEJS_22_X,
  environment: {
    AGENT_SPACE_ID: agentSpace.attrAgentSpaceId,
    ALLOWED_ALARMS: cpuAlarm.alarmName, // カンマ区切りで複数指定できる
  },
});
investigateFn.addToRolePolicy(
  new iam.PolicyStatement({
    actions: ['aidevops:CreateBacklogTask'],
    resources: [`arn:aws:aidevops:${this.region}:${this.account}:agentspace/${agentSpace.attrAgentSpaceId}`],
  }),
);
investigateFn.addToRolePolicy(new iam.PolicyStatement({ actions: ['cloudwatch:DescribeAlarms'], resources: ['*'] }));
```

### チャンネルロールとガードレール

チャンネルロールに付けた権限は、通知の表示に使うCloudWatchの読み取りと、このLambda 1つの`lambda:InvokeFunction`だけです。
ガードレールにも同じ内容のポリシーを指定しています。

```typescript
const channelPermissions = [
  new iam.PolicyStatement({
    actions: ['lambda:InvokeFunction'],
    resources: [investigateFn.functionArn], // この Lambda だけ呼べる
  }),
  new iam.PolicyStatement({
    actions: ['cloudwatch:Describe*', 'cloudwatch:Get*', 'cloudwatch:List*'],
    resources: ['*'],
  }),
];
const channelRole = new iam.Role(this, 'ChatbotChannelRole', {
  assumedBy: new iam.ServicePrincipal('chatbot.amazonaws.com', {
    conditions: { StringEquals: { 'aws:SourceAccount': this.account } },
  }),
  inlinePolicies: { ButtonOnly: new iam.PolicyDocument({ statements: channelPermissions }) },
});
// ガードレール: チャンネルから使える権限の上限。既定のままだと AdministratorAccess になる
const guardrail = new iam.ManagedPolicy(this, 'ChatbotGuardrail', { statements: channelPermissions });
```

### カスタムアクションとチャンネル設定

カスタムアクションは`AWS::Chatbot::CustomAction`で作ります。
Slackの画面からも作れて、その場合は「Lambda action」という種類を選び、関数名とpayloadを入力するだけでボタンができます。
ただ、Slackの画面から作ったアクションは`list-custom-actions`に出てこず、CloudFormationの`AWS::Chatbot::CustomAction`にも「Lambda action」という種類はありません。
CloudFormationの定義にあるのはCLIのコマンド文字列（`CommandText`）だけです。
CDKで管理したいため、CLIアクションとして`lambda invoke`のコマンドを書いています。

`$AlarmName`は、通知の値に置き換わる変数です。
`criteria`で、ALARMになったときの通知にだけボタンを出すようにしています。

```typescript
const investigateAction = new chatbot.CfnCustomAction(this, 'InvestigateLambdaCustomAction', {
  actionName: 'devops-agent-cpu-demo-request-investigation',
  definition: {
    // 出力先のファイル名（位置引数）を付けると Amazon Q が解釈できないため付けない
    commandText: `lambda invoke --function-name ${investigateFn.functionName} --payload '{"alarmName":"$AlarmName"}' --region ${this.region}`,
  },
  attachments: [
    {
      notificationType: 'CloudWatch',
      buttonText: 'DevOps Agent に調査依頼',
      // 通知の中身から JMESPath で値を取り出す
      variables: { AlarmName: 'event.AlarmName', State: 'event.NewStateValue' },
      // ALARM の通知にだけ表示する
      criteria: [
        { variableName: 'AlarmName', operator: 'HAS_VALUE' },
        { variableName: 'State', operator: 'EQUALS', value: 'ALARM' },
      ],
    },
  ],
});

new chatbot.CfnSlackChannelConfiguration(this, 'SlackChannelConfiguration', {
  configurationName: 'devops-agent-cpu-demo-alarm',
  slackWorkspaceId,
  slackChannelId,
  snsTopicArns: [alarmTopic.topicArn], // アラームの通知先の SNS トピック
  iamRoleArn: channelRole.roleArn,
  guardrailPolicies: [guardrail.managedPolicyArn],
  customizationResourceArns: [investigateAction.attrCustomActionArn],
});
```

## 押してみた

アラームをALARMにすると、Slackの通知に「DevOps Agent に調査依頼」のボタンが付きました。

![SlackのCloudWatchアラームの通知。List dashboards、Query logsに並んで「DevOps Agent に調査依頼」のボタンがある](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203016/2026/10/17/oljprmbgmygxshxytkfr.png)

ボタンを押すと、すぐには実行されず、確認のダイアログが出ます。
実行するコマンドの全文と、実行先のアカウントが表示されます。

![Command Actionのダイアログ。AlarmNameの値、実行するlambda invokeのコマンド全文、Run in accountの選択、Change variablesのボタン、CloseとRunのボタンがある](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203016/2026/10/17/af5hf5wrs1vc8gsltsns.png)

Runを押すと、スレッドに実行結果が投稿されました。
Lambdaの戻り値がそのまま`Payload`として表示され、DevOps Agentに調査が作られています。
続けてもう一度押しても、同じタスクIDが返り、調査は増えませんでした。

![通知のスレッド。Amazon Qが「I ran the command」としてlambda invokeのコマンドとチャンネルロールで実行したことを投稿し、Payloadに「調査を作りました: 256d07c5-…（状態 PENDING_START）」が表示されている。同じ内容がもう1件続き、同じタスクIDが返っている。その下に、アラームがOKに戻った通知が続き、こちらにはList dashboardsとQuery logsのボタンしかない](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203023/2026/10/17/zpssui23ghc5mldpbjuh.png)

アラームがOKに戻った通知にはボタンが出ていません。
`criteria`で指定した表示の条件は、そのとおりに働いています。

## 誰が押せるのか

チャンネル設定には、チャンネルロールを使う方法と、メンバーごとにユーザーロールを選ばせる方法があります。
公式ドキュメントでは、チャンネルロールは次のように説明されています。

> A channel role gives all channel members the same permissions.
>
> （チャンネルロールは、チャンネルの全メンバーに同じ権限を与えます）
>
> [Understanding Amazon Q Developer in chat applications permissions](https://docs.aws.amazon.com/chatbot/latest/adminguide/understanding-permissions.html)

今回の構成はチャンネルロールのため、チャンネルにいる人なら誰でもボタンを押せます。
AWSのアカウントを持っているかどうかは関係ありません。
「誰が押せるか」は、Slackのチャンネルに誰を入れるかで決まります。

## 表示条件は、起動の制限にならない

ここからが、本記事で確かめたかったところです。

ボタンに「ALARMの通知にだけ表示する」という条件を付けたため、対象外のアラームや、OKに戻った通知からは調査を起動できないはずだと考えると思います。
私もそう思っていました。

実際には、この条件は表示の条件にすぎません。
確認のダイアログには「Change variables」のボタンがあり、押した人がその場でアラーム名を書き換えられます。
書き換えると、実行するコマンドの中身もその名前に変わります。

![Command Actionのダイアログ。AlarmNameがsome-other-alarmに書き換わっていて、コマンドのpayloadにもその名前が入っている](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203023/2026/10/17/wxlzd8rwe0cdowyuqlpv.png)

さらに、チャンネルのメンバーは`@Amazon Q lambda invoke ...`とコマンドを手で打つこともできます。
どちらの場合も、Amazon Qはチャンネルロールの権限でLambdaを呼びます。
IAMの権限は「この関数を呼べるか」しか見ていないため、ここでは止まりません。

止めてくれるのはLambdaです。
許可リストにない名前で呼ぶと、調査を作らずに拒否の文を返します。

![スレッド。alarmNameがsome-other-alarmのlambda invokeが実行され、Payloadに「some-other-alarm は調査の対象ではありません。対象: devops-agent-cpu-demo-worker-cpu-high」が表示されている](https://devio2024-media.developers.io/image/upload/c_limit,w_1200/f_auto/q_auto/v1792203023/2026/10/17/mbmmuel4xm6qcsiwpz0p.png)

同じように、アラームがOKに戻ったあとに押しても「今 OK なので調査を始めません」が返ります。
ボタンの表示条件や変数の初期値は、起動を制限する仕組みではありません。
どのアラームの調査を起動してよいかは、ボタンの外側（今回はLambda）で決める必要があります。

## 気をつけること

検証して分かった、設計で気をつける点です。

**ガードレールを既定のままにしない**
チャンネル設定のガードレールは、既定では`AdministratorAccess`です。
ガードレールはチャンネルロールとユーザーロールの両方に優先する上限であるため、ここが広いままだと、将来チャンネルロールに権限を足したときに、そのままチャンネルの全員が使えるようになります。
チャンネルロールと同じ最小のポリシーを指定しましょう。

**押した人の記録は、監査ログに残らない**
Amazon Qは、実行したコマンドの監査ログをCloudWatch Logs（バージニア北部の`/aws/chatbot/<設定名>`）に残します。
手打ちしたコマンドは、`prepared`と`approved`の2行が、SlackのユーザーIDとコマンド全文付きで残っていました。
一方、ボタンを押した時刻には、このログに`command`の行がありませんでした。
カスタムアクションの実行は、この検証では監査ログに残りませんでした。

`CreateBacklogTask`は管理イベントのためCloudTrailに残りますが、主体はLambdaのロールです。
Amazon QがLambdaに渡す`event`は`{"alarmName": "..."}`だけで、押した人の情報は入っていませんでした。
誰が押したかを残したい場合は、Amazon Qの監査ログの保持期間を確かめたうえで、Slackのスレッドの投稿（`I ran the command`の投稿者）を手がかりにすることになります。

**1日の調査時間の上限は別に要る**
`clientToken`でまとめられるのは、同じアラームを同じ1時間の間に押した分だけです。
時間を置いて押せば新しい調査が始まり、調査は実行時間に応じて課金されるため、押した回数に応じて費用はかかります。
1日の調査時間の合計に上限を付けたい場合は、その判定もLambdaに足す等の対応が必要です。

## まとめ

Slackの通知のボタンから調査を起動する仕組みは、カスタムアクションと小さなLambdaで作れました。

一方で、ボタン自体には何かを制限する力がありません。
ボタンを押したときに使われるのはチャンネルロールの権限で、チャンネルにいる人なら誰でも押せます。
そのため、チャンネルロールに付ける権限は、ボタンに必要な最小限にとどめる必要があります。
同じように、ボタンを「ALARMの通知にだけ表示する」ようにしても、調査を起動できる範囲は絞れません。
表示条件が決めるのはボタンを出すかどうかだけで、確認のダイアログからアラーム名を書き換えることも、同じコマンドを手で打つこともできます。

つまり各責任は、誰が押せるかはSlackのチャンネル側にあり、何の権限で動くかはチャンネルロールで、どのアラームを調査してよいかはLambdaで決まります。
今回はLambdaに許可リストと状態の確認を置いたため、書き換えても手で打っても、対象外なら調査は始まりません。

同じようにSlackからDevOps Agentを起動したい方の参考になれば幸いです。

## 参考

- [Custom actions using Amazon Q Developer in chat applications](https://docs.aws.amazon.com/chatbot/latest/adminguide/custom-actions.html)
- [Understanding Amazon Q Developer in chat applications permissions](https://docs.aws.amazon.com/chatbot/latest/adminguide/understanding-permissions.html)
- [Accessing Amazon CloudWatch Logs for Amazon Q Developer in chat applications](https://docs.aws.amazon.com/chatbot/latest/adminguide/cloudwatch-logs.html)
- [AWS::Chatbot::CustomAction - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-chatbot-customaction.html)
- [CreateBacklogTask - AWS DevOps Agent API Reference](https://docs.aws.amazon.com/devopsagent/latest/APIReference/API_CreateBacklogTask.html)
