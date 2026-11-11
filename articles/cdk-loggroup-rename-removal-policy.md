---
title: "CDKでロググループ名を変えると既存ログは消えるのか、RemovalPolicy別に確かめてみた"
emoji: "🗑️"
type: "tech"
topics: ["aws", "cdk", "cloudformation", "cloudwatchlogs"]
published: false
---

こんにちは、クラスメソッド製造ビジネステクノロジー部のはすとです。

CloudWatch Logs の設定を統一する作業のなかで、ロググループの命名も揃えることになりました。そこで気になったのが、ロググループ名を変えたら今まで溜めていたログはどうなるのか、という点です。

本記事では、CDK でロググループを 3 パターン用意し、それぞれ違う条件で名前を変えて何が起きるかを確認します。公式ドキュメントで説明されていない挙動もあったため、そこもあわせてまとめます。

## 検証環境

- aws-cdk-lib 2.269.0
- AWS CDK CLI 2.1104.0
- リージョン: ap-northeast-1

## 今回検証する3つのパターン

ロググループを 1 つだけ持つスタックを 3 つ用意し、それぞれ別のやり方で名前を変えます。

| ケース | スタック名 | 加える変更 | 確認したいこと |
| --- | --- | --- | --- |
| 1 | CwlRenameDestroy | `RemovalPolicy.DESTROY` のまま名前を変える | 旧ロググループとログが消えるか |
| 2 | CwlRenameRetain | `RemovalPolicy.RETAIN` のまま名前を変える | 旧ロググループがどう残るか |
| 3 | CwlRenameFlip | `RETAIN` → `DESTROY` への変更と改名を同じデプロイで行う | 新旧どちらのポリシーが効くか |

ケース 1 と 2 は公式ドキュメントに記載があるため、予想はできますが、ケース 3 については、ドキュメントに記載がないため、実際に検証してみる価値が大きいです。

## 検証に使用する CDK のコード

スタックの定義は共通で、コンテキストで名前と削除ポリシーを切り替えます。

```typescript
class LogGroupStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: LogGroupStackProps) {
    super(scope, id, props);

    new logs.LogGroup(this, "Target", {
      logGroupName: props.logGroupName,
      retention: props.retention,
      removalPolicy: props.removalPolicy,
    });
  }
}

const name = app.node.tryGetContext("name") as string;      // a → b で改名する
const policy = app.node.tryGetContext("policy") as string;  // retain → destroy で切り替える

// ケース1: DESTROY のまま改名する
new LogGroupStack(app, "CwlRenameDestroy", {
  logGroupName: `/verify/cwl-rename/destroy-${name}`,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
  retention: logs.RetentionDays.ONE_DAY,
});

// ケース2: RETAIN のまま改名する
new LogGroupStack(app, "CwlRenameRetain", {
  logGroupName: `/verify/cwl-rename/retain-${name}`,
  removalPolicy: cdk.RemovalPolicy.RETAIN,
  retention: logs.RetentionDays.ONE_DAY,
});

// ケース3: RETAIN → DESTROY への変更と改名を同じデプロイでやる
new LogGroupStack(app, "CwlRenameFlip", {
  logGroupName: `/verify/cwl-rename/flip-${name}`,
  removalPolicy: policy === "destroy" ? cdk.RemovalPolicy.DESTROY : cdk.RemovalPolicy.RETAIN,
  retention: logs.RetentionDays.ONE_DAY,
});
```

ここで一度、書いた CDK コードが CloudFormation でどうなるかを、`cdk synth` で確認してみます。

```bash
pnpm exec cdk synth CwlRenameDestroy -c name=a -c policy=retain
```

以下は、出力されたテンプレートから、ロググループだけを抜き出したものです。

```json
"Target3191CF44": {
  "Type": "AWS::Logs::LogGroup",
  "Properties": {
    "LogGroupName": "/verify/cwl-rename/destroy-a",
    "RetentionInDays": 1
  },
  "UpdateReplacePolicy": "Delete",
  "DeletionPolicy": "Delete"
}
```

ここで注目なのが、CDK では `removalPolicy` という 1 つのプロパティでしたが、CloudFormation では `DeletionPolicy` と `UpdateReplacePolicy` の 2 つに分かれて出力されることがわかりました。

:::details 先頭の Target3191CF44 について
CloudFormation の論理 ID です。CDK は `new logs.LogGroup(this, "Target", ...)` の第 2 引数（Construct ID）に、Construct ツリー上の位置から求めたハッシュを付けて論理 ID を作ります。今回は `Target` + `3191CF44` です。

ロググループ名（`/verify/cwl-rename/destroy-a`）のほうは物理 ID と呼ばれ、実体につく名前です。論理 ID はテンプレート内での識別子で、これが同じであれば CloudFormation は「同じリソースへの変更」として扱います。
:::

続いて早速 `a` の名前でデプロイします。

```bash
pnpm exec cdk deploy --all -c name=a -c policy=retain
```

デプロイができたら、3 つのロググループにそれぞれログを 1 件ずつ入れておきます。中身が空だと、消えたのかどうかが分かりにくいためです。

```bash
aws logs create-log-stream --log-group-name /verify/cwl-rename/destroy-a \
  --log-stream-name verify
aws logs put-log-events --log-group-name /verify/cwl-rename/destroy-a \
  --log-stream-name verify \
  --log-events "timestamp=$(($(date +%s) * 1000)),message=seeded"
```

結果、3 つとも無事に作成され、ログも入った状態です。

![改名前のロググループ一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789394614/2026/09/14/xd31q02yrbvm6syqzeup.png)

## ロググループ名変更の挙動について

[AWS::Logs::LogGroup](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-logs-loggroup.html) のドキュメントで `LogGroupName` を見ると、更新時の挙動が `Replacement`（置換）と書かれています。

> `LogGroupName`
> *Update requires*: [Replacement](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-update-behaviors.html#update-replacement)

CloudFormation では、更新時の挙動が 3 種類に分けられています。置換はそのうちの 1 つで、[Update behaviors of stack resources](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-update-behaviors.html) にこう説明されています。

> CloudFormation recreates the resource during an update, which also generates a new physical ID. CloudFormation usually creates the replacement resource first, changes references from other dependent resources to point to the replacement resource, and then deletes the old resource.

（CloudFormation は更新時にリソースを作り直し、新しい物理 ID が払い出されます。通常は先に新しいリソースを作り、それを参照している他のリソースの向き先を新しい方へ変えたうえで、古いリソースを削除します）

つまり置換とは、既存のロググループの名前を書き換えるのではなく、**新しい名前のロググループを別に作って、古いほうを削除する** という動きです。ロググループの中身（蓄積されたログ）は新しいものへは引き継がれません。

古いほうを削除するかどうかを決めるのが [UpdateReplacePolicy](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatereplacepolicy.html) です。既定は削除で、`Retain` を指定すると残せます。ただし、残したあとの扱いにも注意書きがあります。

> `UpdateReplacePolicy` retains the old physical resource or snapshot, but removes it from CloudFormation's scope.

（`UpdateReplacePolicy` は古いリソース（またはスナップショット）を残しますが、CloudFormation の管理対象からは外します）

これは、「残るけど、そのスタックのリソースではなくなるよ」ということです。ここは後ほど実際に確認します。

## ロググループ名を変えてデプロイしてみる

`a` から `b` へ改名します。ケース 3 のポリシー切り替えも同時に行います。

```bash
pnpm exec cdk deploy --all -c name=b -c policy=destroy
```

![改名後のロググループ一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789394618/2026/09/14/bas2h0eu1jgxdsbb01oy.png)

`destroy-a` と `flip-a` が消えました。`retain-a` はログを保ったまま残っています。

ここで、残った `retain-a` が本当に CloudFormation の管理から外れているかを確認します。`CwlRenameRetain` スタックのリソース一覧を見ると、ロググループは `retain-b` だけです。

![CwlRenameRetain のリソース一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789394635/2026/09/14/b05y1difecpilnfxthkb.png)

アカウント上には `retain-a` と `retain-b` の両方が存在していますが、スタックが管理しているのは `retain-b` だけ、という状態です。
実際、このあと `cdk destroy` でスタックごと消しても `retain-a` は残り、`aws logs delete-log-group` で個別に削除する必要がありました。

また、スタックイベントを見ると、書き換えの流れがそのまま追えます。

![CwlRenameDestroy のスタックイベント](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789394623/2026/09/14/kndxxi9p6wa979ouvex7.png)

論理 ID は `Target3191CF44` のまま、物理 ID が `destroy-a` → `destroy-b` に入れ替わっています。

これは、新しいロググループを作り、参照を切り替えたあと、クリーンアップの段階で旧ロググループを削除しています。`RETAIN` の方は、ここのイベントが `DELETE_SKIPPED` になります。

結果をまとめます。

| ケース | 旧ロググループ |
| --- | --- |
| DESTROY のまま改名 | 削除された（ログも消えた） |
| RETAIN のまま改名 | 残るが、 CloudFormation の管理外 |
| RETAIN→DESTROY と改名を同時 | 削除された（ログも消えた）  |

## 検証からわかった注意すべき点
RETAIN から DESTROY へ切り替えるデプロイが一番危ないということです。
ケース 3 の「RETAIN→DESTROY と改名を同時」ですが、デプロイ前のテンプレートは `Retain` なので、守られるのでは？と思うかもしれません。

しかし、実際には旧ロググループがログごと削除されました。

CloudFormation が見るのは、これから反映するテンプレートの `UpdateReplacePolicy` です。デプロイ前のテンプレートに書かれていた `Retain` は参照されません。そのため、ポリシーの変更と名前の変更が同じデプロイに入った時点で、`DESTROY` として扱われます。

さらに紛らわしいのが変更セットの表示です。実行前に中身を確認すると、`PolicyAction` は `ReplaceAndRetain` になっていました。

```bash
aws cloudformation describe-change-set --stack-name CwlRenameFlip --change-set-name flip-check2 \
  --query 'Changes[].ResourceChange.{Replacement:Replacement,PolicyAction:PolicyAction,Scope:Scope}'
```

```json
[
  {
    "Replacement": "True",
    "PolicyAction": "ReplaceAndRetain",
    "Scope": ["DeletionPolicy", "UpdateReplacePolicy", "Properties"]
  }
]
```

[ResourceChange](https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ResourceChange.html) の定義では、この値はこう説明されています。

> `ReplaceAndRetain` The resource will be replaced and then retained.

（リソースは置換されたあと、保持されます）

これをみると、旧ロググループは保持されるのでは？と一瞬思います。しかし、中身を確認したこの変更セットをそのまま実行すると、結果は違いました。

```bash
aws cloudformation execute-change-set --stack-name CwlRenameFlip --change-set-name flip-check2
```

![変更セット実行後のスタックイベント](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789394630/2026/09/14/dn5kaok2ivdobsupbmqq.png)

`ReplaceAndRetain` と表示した変更セット自身が、旧ロググループを削除しました。ログも一緒に消えています。

## 気をつけること

既存のロググループを改名すると、どちらのポリシーでも困ることになります。`DESTROY` ならログが消え、`RETAIN` ならログは残るものの CloudFormation の管理から外れて、以後 IaC で保持期間を変更できなくなります。`cdk destroy` でも消えないので、手動での削除が必要になります。

なお、名前を変えずに保持期間（`RetentionInDays`）だけを変える場合は *Update requires: No interruption* なので置換は起きません。設定の統一が目的なら、保持期間だけに絞るのが安全です。

## まとめ

既存のロググループ名を変更した場合、`DESTROY` なら旧ログが消え、`RETAIN` なら旧ログは残るものの CloudFormation の管理から外れてしまいます。こちらは、`cdk destroy` でも消えないので、手動での削除が必要になります。

想定外だったのは、ポリシーを `RETAIN` から `DESTROY` へ変える際にロググループ名の変更も混ざると、デプロイ前のテンプレートが `Retain` だったとしても削除されることです。

ロググループの命名を揃えたくなったときは、消えて困るログがないか先に確認してみてください。

## 参考

- [AWS::Logs::LogGroup - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-logs-loggroup.html)
- [UpdateReplacePolicy attribute - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatereplacepolicy.html)
- [DeletionPolicy attribute - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html)
- [ResourceChange - AWS CloudFormation API Reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ResourceChange.html)
- [class LogGroup - AWS CDK API Reference](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.aws_logs.LogGroupProps.html)
- [enum RemovalPolicy - AWS CDK API Reference](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.RemovalPolicy.html)
