---
title: "CDKで既存ログを残したままロググループ名を変える方法を確かめてみた"
emoji: "📦"
type: "tech"
topics: ["aws", "cdk", "cloudformation", "cloudwatchlogs"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

前回は、CDK でロググループ名を変更したときに、既存ログがどうなるのかを検証しました。結果は、`RemovalPolicy.DESTROY` を適用すると、旧ロググループがログごと消えてしまうことが確認できました。

https://dev.classmethod.jp/articles/cdk-loggroup-rename-removal-policy/

では、既存のログを残したまま命名を変更したい時には、どうすればよいのでしょうか。

本記事では、旧ロググループを残し、新しいロググループを別に定義する方法を検証します。

あわせておまけとして、すでにロググループ名を変更してしまい、CDK 管理外になったものを取り込む方法も検証しました。

## 検証環境

- aws-cdk-lib 2.269.0
- AWS CDK CLI 2.1104.0
- リージョン: ap-northeast-1

## 軽く前回の振り返り
CDK で `removalPolicy` に指定した値は、`UpdateReplacePolicy` として出力され、この値を元に、`logGroupName` 変更時の対応を決めます。 


| CDK の `removalPolicy` | 出力される `UpdateReplacePolicy` | 置換されたときの旧ロググループ |
| --- | --- | --- |
| `DESTROY` | `Delete` | 削除される（ログも消える） |
| `RETAIN` | `Retain` | 残るが、CloudFormation の管理外になる |

`RETAIN` ならログは残りますが、CDK 管理外になると保持期間を IaC から変更できず、`cdk destroy` でも消えません。
そのため、ロググループ名の変更作業は、単純なリネーム作業では終わらないことがわかりました。


## 旧ロググループを残して、新しいロググループを別に定義する

置換が起きるのは、既存の Construct の `logGroupName` が変わったときです。逆に言えば、既存の Construct には手を付けず、新しい名前のロググループを別の Construct として定義すれば、旧ロググループには何も起きません。

```typescript
// 旧ロググループ。論理 ID も logGroupName も変えない
new logs.LogGroup(this, "Legacy", {
  logGroupName: "/verify/cwl-keep/app-old",
  retention: logs.RetentionDays.ONE_DAY,
  removalPolicy: cdk.RemovalPolicy.DESTROY,   // RETAIN から変更。設定しても今は発動しない
});

// 新しいロググループ。別の Construct として追加する
new logs.LogGroup(this, "Fresh", {
  logGroupName: "/verify/cwl-keep/app-new",
  retention: logs.RetentionDays.ONE_MONTH,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
});
```

ここでは次の 2 つを 1 回のデプロイでまとめています。

1. 旧ロググループの `RemovalPolicy` を `RETAIN` から `DESTROY` へ変更
2. 新しいロググループの追加

前回の検証を踏まえると 1 が不安ですが、問題はありません。変更セットを実行前に見ると、旧ロググループは置換対象になっていないことがわかります。

```bash
pnpm exec cdk deploy CwlKeep --no-execute --change-set-name keep-check
aws cloudformation describe-change-set --stack-name CwlKeep --change-set-name keep-check \
  --query 'Changes[].ResourceChange.{LogicalId:LogicalResourceId,Action:Action,Replacement:Replacement,PolicyAction:PolicyAction,Scope:Scope}'
```

```json
[
  {
    "LogicalId": "FreshA68222D7",
    "Action": "Add",
    "Replacement": null,
    "PolicyAction": null,
    "Scope": []
  },
  {
    "LogicalId": "LegacyFA07BB5D",
    "Action": "Modify",
    "Replacement": "False",
    "PolicyAction": null,
    "Scope": ["DeletionPolicy", "UpdateReplacePolicy"]
  }
]
```

旧ロググループ（`LegacyFA07BB5D`）は `Replacement: False` で、`PolicyAction` も `null` です。`Scope` は `DeletionPolicy` と `UpdateReplacePolicy` だけなので、変わるのは削除ポリシーの設定だけです。

[前回記事の検証](https://dev.classmethod.jp/articles/cdk-loggroup-rename-removal-policy/#%E6%A4%9C%E8%A8%BC%E3%81%8B%E3%82%89%E3%82%8F%E3%81%8B%E3%81%A3%E3%81%9F%E6%B3%A8%E6%84%8F%E3%81%99%E3%81%B9%E3%81%8D%E7%82%B9)では、ここが `Replacement: True` と `PolicyAction: ReplaceAndRetain` になっていました。



続いて、実行後のロググループです。

![旧ロググループを残したまま新しいロググループが追加された一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789477650/2026/09/15/bvehux7u1yrbunvejo7s.png)

`app-old` はそのまま残り、新しく `app-new` が追加されました。スタックのリソース一覧を見ると、両方とも管理下にあります。

![CwlKeep のリソース一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789477655/2026/09/15/yohgolyl2khttairzb4l.png)

`app-old` の作成時刻も変更前と同じ `1789475239800` のままで、保持期間もログも変わっていません。

## すでにロググループ名を変更してしまい、CDK 管理に戻したい場合

ここからはおまけです。前回の記事のように `RETAIN` のまま名前を変更してしまい、旧ロググループが CDK の管理外になった場合の戻し方を確認します。

スタックのリソース一覧には、新しいロググループしかありません。

![改名後の CwlImport のリソース一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789477665/2026/09/15/wmvbpy2f2zwmu7lrverl.png)

### 旧名をコードに書き戻すだけでは失敗する

管理外になったロググループを管理下に戻したくなり、旧名の Construct をコードに書き足したとします。

```typescript
new logs.LogGroup(this, "Old", {
  logGroupName: "/verify/cwl-import/app-old",  // 既に存在するロググループ
  retention: logs.RetentionDays.ONE_DAY,
  removalPolicy: cdk.RemovalPolicy.DESTROY,
});
```

これを通常デプロイすると失敗します。CloudFormation にとっては新規作成扱いで、同名のロググループがすでにあるよと、弾かれます。

```
Early validation failed for change set cdk-deploy-change-set:
CwlImport/Old/Resource  (AWS::Logs::LogGroup OldF7E39C65)
  Resource of type 'AWS::Logs::LogGroup' with identifier '/verify/cwl-import/app-old' already exists.
```

変更セットの事前検証で止まるため、スタックは `UPDATE_COMPLETE` のままで変化しません。ロールバックも起きないので、この失敗自体は安全です。

### cdk import なら成功する

コードはそのままで、`cdk import` を使います。論理 ID と既存ロググループ名の対応を渡すだけです。

```bash
pnpm exec cdk import CwlImport \
  --resource-mapping-inline '{"OldF7E39C65":{"LogGroupName":"/verify/cwl-import/app-old"}}'
```

```
CwlImport/Old/Resource: importing using LogGroupName=/verify/cwl-import/app-old
CwlImport: importing resources into stack...
✅  CwlImport
```

リソース一覧に旧ロググループが加わりました。

![import 後の CwlImport のリソース一覧](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789477669/2026/09/15/hi1krb5lfkv2wf3eemzw.png)

取り込んだあとは普通のリソースとして扱えます。実際に保持期間を 1 日から 14 日へ変更してみたところ、`cdk deploy` で反映できました。ログもそのまま残っています。

### `DeletionPolicy` が書かれていれば、`DESTROY` でも import は成功する

import するリソースには `DeletionPolicy` の指定が必要で、公式ドキュメントの [Considerations during an import operation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/import-resources-manually.html) にこう書かれています。

> Each resource to import must have a `DeletionPolicy` attribute for the import operation to succeed. The `DeletionPolicy` can be set to any possible value.
// 日本語訳
インポートするリソースには、操作を成功させるために `DeletionPolicy` 属性が必要です。`DeletionPolicy` には取りうる値のどれを設定してもかまいません

書かれている通り、値は問われないため、今回のように `RemovalPolicy.DESTROY`（`DeletionPolicy: Delete`）のままでも import できました。

## まとめ

今回の検証では、「既存のログを残したままロググループ名を変えること」は可能ということがわかりました。方法としては、既存の Construct には手を付けず、新しい名前のロググループを別の Construct として定義することです。
また、すでに名前を変更してしまい管理外になっている場合も、`cdk import` で管理下に戻せることが確認できました。

既存ログを消さずに、ロググループ名の変更を行いたい方は、ぜひ参考にしてみてください。

## 参考

- [Import AWS resources into a CloudFormation stack manually](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/import-resources-manually.html)
- [UpdateReplacePolicy attribute - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatereplacepolicy.html)
- [DeletionPolicy attribute - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-deletionpolicy.html)
- [ResourceChange - AWS CloudFormation API Reference](https://docs.aws.amazon.com/AWSCloudFormation/latest/APIReference/API_ResourceChange.html)
- [enum RemovalPolicy - AWS CDK API Reference](https://docs.aws.amazon.com/cdk/api/v2/docs/aws-cdk-lib.RemovalPolicy.html)
