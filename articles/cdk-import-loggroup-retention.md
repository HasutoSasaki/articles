---
title: "CDK管理外のロググループに保持期間を入れる方法をcdk importで確かめてみた"
emoji: "📥"
type: "tech"
topics: ["aws", "cdk", "cloudformation", "cloudwatchlogs"]
published: false
---

こんにちは、クラスメソッド製造ビジネステクノロジー部のはすとです。

開発の当初は CloudWatch Logs の設定までは気にせず、Lambda だけを CDK に定義しそのまま本番運用を開始！しかし、あとから 「CloudWatch のコストが高くなっている」ことに気づき、ログの保持期間を設定したい。。こういうケースはよくあるのかなと思います。

ところが、Lambda が自動生成したロググループは CDK の管理外で、CDK 側に定義を足して `cdk deploy` しても、同名のロググループがすでにあるので失敗してしまいます。

[前回の記事](https://dev.classmethod.jp/articles/cdk-loggroup-rename-keep-old-logs/)では、名前を変更して管理外になったロググループを `cdk import` で戻し、そのあと保持期間を変更して `cdk deploy` すれば実際のロググループに反映されることまで確認しました。

なので今回も同じようにいけるかと思っていましたが、分かっていなかった点として、**最初から保持期間を書いたコードで import した場合に、そのあとの `cdk deploy` で実際のロググループに反映されるのか**がありました。

結論から書くと、適用はされませんでした。ただし、コードを書く順番を変えれば CDK から入れられます。

本記事ではこの挙動を実際に再現して、なぜ上手くいかないのかと、どう回避するのかを確認していきます。

## 検証環境

- aws-cdk-lib 2.269.0
- AWS CDK CLI 2.1141.0
- リージョン: ap-northeast-1

## 何を確かめるか

Lambda が自動生成したロググループを対象にして、実際の状況を再現します。

1. Lambda だけをデプロイし、1 回実行。ロググループを自動生成させる
2. CDK 側にそのロググループの定義を足す（保持期間14日）
3. `cdk deploy` する → 名前の衝突で失敗する
4. `cdk import` で取り込む
5. `cdk deploy` する
6. ロググループの保持期間を確認する

ポイントは 5 と 6 の間です。「最後に保持期間が入っていない」だけでは、import が値を無視したのか、deploy がそのリソースを対象外にしたのかが区別できません。そこで **import 直後にテンプレートと実リソースの両方を見る**ことにします。

そのうえで、コードを書く順番を変えた場合も試します。こちらはステップ 6 で扱います。

## 検証に使用する CDK のコード

まずは Lambda だけを定義します。`logGroup` を渡していないので、関数を実行すると Lambda が `/aws/lambda/<関数名>` を自分で作ります。

```typescript
export const FUNCTION_NAME = "verify-cwl-import-retention-function";

export class ImportRetentionStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    new lambda.Function(this, "Function", {
      functionName: FUNCTION_NAME,
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: "index.handler",
      code: lambda.Code.fromInline("exports.handler = async () => 'ok';"),
    });
  }
}
```

## 1. Lambda だけをデプロイして、ロググループを自動生成させる

```bash
pnpm exec cdk deploy CwlImportRetention --require-approval never
aws lambda invoke --function-name verify-cwl-import-retention-function /dev/null
```

実行するとロググループができます。保持期間は入っていません。

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": null
}
```

コンソールでも「保持」が 失効しない になっているため、保持期間無制限ということがわかります。

![Lambda が自動生成したロググループ。保持が「失効しない」](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699824/2026/09/18/w0dbghjmsx9inuohlhso.png)

一方で、スタックのリソースには Lambda と実行ロールしかなく、ロググループは含まれていません。

![import 前のスタックのリソース一覧。ロググループが無い](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699830/2026/09/18/zkjxgbdphrf6wcbkcgx9.png)

## 2. ロググループの定義を足して、そのまま cdk deploy すると失敗する

ここでコードにロググループを足します。保持期間 14 日を指定し、Lambda の `logGroup` に渡します。

```typescript
export const FUNCTION_NAME = "verify-cwl-import-retention-function";
export const LOG_GROUP_NAME = `/aws/lambda/${FUNCTION_NAME}`;

export class ImportRetentionStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // 実体はすでに Lambda が作っている。ここでは同名のロググループを CDK 側に定義する
    const logGroup = new logs.LogGroup(this, "FunctionLogGroup", {
      logGroupName: LOG_GROUP_NAME,
      retention: logs.RetentionDays.TWO_WEEKS,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    new lambda.Function(this, "Function", {
      functionName: FUNCTION_NAME,
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: "index.handler",
      code: lambda.Code.fromInline("exports.handler = async () => 'ok';"),
      logGroup,
    });
  }
}
```

`cdk synth` すると、ロググループの論理 ID は `FunctionLogGroupBD1576D5` になります。これはあとで使います。

```yaml
  FunctionLogGroupBD1576D5:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/lambda/verify-cwl-import-retention-function
      RetentionInDays: 14
    UpdateReplacePolicy: Delete
    DeletionPolicy: Delete
```

Lambda 側には `LoggingConfig` が生成されます。これは「この関数はどのロググループに書くか」を指す設定で、コードには書きません。`logGroup` を渡したことで CDK が出力します。

```yaml
  Function76856677:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: verify-cwl-import-retention-function
      LoggingConfig:
        LogGroup:
          Ref: FunctionLogGroupBD1576D5
```

この状態でデプロイすると、変更セットの事前検証で止まります。

```bash
pnpm exec cdk deploy CwlImportRetention --require-approval never
```

```text
CwlImportRetention: creating CloudFormation changeset...
Early validation failed for change set cdk-deploy-change-set:
CwlImportRetention/FunctionLogGroup/Resource  (AWS::Logs::LogGroup FunctionLogGroupBD1576D5)
  Resource of type 'AWS::Logs::LogGroup' with identifier '/aws/lambda/verify-cwl-import-retention-function' already
  exists. (at /Resources/FunctionLogGroupBD1576D5)
```

CloudFormation にとっては新規作成のつもりなので、同名のものがすでにあると作れません。

`cdk diff` も同じ理由で変更セットを作れず、デプロイ済みのテンプレートと `cdk synth` の結果を比較する方式に切り替わるようです。差分はロググループの追加と、Lambda の `LoggingConfig` の追加です。

```text
Could not create a change set, will base the diff on template differences (run again with -v to see the reason)

Stack CwlImportRetention (aws://<account>/ap-northeast-1)
Resources
[+] AWS::Logs::LogGroup FunctionLogGroup FunctionLogGroupBD1576D5
[~] AWS::Lambda::Function Function Function76856677
 └─ [+] LoggingConfig
     └─ {"LogGroup":{"Ref":"FunctionLogGroupBD1576D5"}}
```

## 3. cdk import で取り込む

```bash
pnpm exec cdk import CwlImportRetention --force \
  --resource-mapping-inline '{"FunctionLogGroupBD1576D5":{"LogGroupName":"/aws/lambda/verify-cwl-import-retention-function"}}'
```

```text
Ignoring updated/deleted resources (--force): CwlImportRetention/Function/Resource
CwlImportRetention/FunctionLogGroup/Resource: importing using LogGroupName=/aws/lambda/verify-cwl-import-retention-function
CwlImportRetention: importing resources into stack...
CwlImportRetention: creating CloudFormation changeset...

✅  CwlImportRetention
Import complete. Run cdk deploy to update the stack to match your CDK app.
```

`--resource-mapping-inline` の JSON は「**CloudFormation の論理 ID** → **実リソースの識別子**」の対応です。キーの `FunctionLogGroupBD1576D5` は CDK が生成した論理 ID で、既存ロググループの ID ではありません。実物を指しているのは値側の `LogGroupName` のほうです。

:::details 対話形式で実行する場合

対話形式で実行するならこのオプションは不要です。テンプレートには `LogGroupName` が文字列で書いてあるため、CDK は名前の入力を求めるのではなく `... (AWS::Logs::LogGroup): import with LogGroupName=/aws/lambda/verify-cwl-import-retention-function` という確認を出し、y と答えれば取り込んでくれます。CI などの非対話環境では `--resource-mapping` か `--resource-mapping-inline` が無いと `ResourceMappingRequired` で止まります。
:::

また、`--force` は必須ではありません。差分に Lambda の `LoggingConfig` の更新が含まれるため、付けないと差分が表示され `Perform import?` と確認が入ります。対話形式であれば y と答えれば問題ないです。しかし、ここで付けているのは、1 コマンドで終わらせるためです。CI などの非対話環境では確認に答えられないので、`--force` か `--yes` が必要になります。

リソース一覧にはロググループが加わりました。

![import 後のスタックのリソース一覧。ロググループが増えている](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699836/2026/09/18/ytbabvxe7wnze1jif6wr.png)

### 本番で実行するときの手順

本番のスタックに対して実行するのは怖いところがありますが、`cdk import` が CloudFormation に送るテンプレートは、デプロイ済みテンプレートに取り込むリソースの記述を足しただけのものです。既存リソースの記述には触らないので、import が他のリソースを巻き込むことはありません。

とはいえ、いきなりステップ 3 のコマンドを叩くのは怖いため、段階を踏んで実行する方式でやってみることにしました。

ステップ 3 では、取り込むリソースの対応表を `--resource-mapping-inline` で書き、import の実行までを 1 回で終わらせています。段階を踏む方式では、この**対応表をファイルに切り出すこと**で、一度レビューに回せるようにします。

**1. 対応表をファイルに書き出す**

`--record-resource-mapping` を付けると、対応表をファイルに書いたところで終わり、import は実行されません。

```bash
pnpm exec cdk import CwlImportRetention --record-resource-mapping mapping.json
```

```text
The following resources have pending updates that will be reconciled with a cdk deploy after import:
Stack CwlImportRetention
Resources
[+] AWS::Logs::LogGroup FunctionLogGroup FunctionLogGroupBD1576D5
[~] AWS::Lambda::Function Function Function76856677
 └─ [+] LoggingConfig
     └─ {"LogGroup":{"Ref":"FunctionLogGroupBD1576D5"}}

Perform import? (y/n) y
CwlImportRetention/FunctionLogGroup/Resource (AWS::Logs::LogGroup): import with LogGroupName=/aws/lambda/verify-cwl-import-retention-function (y/n) y
mapping.json: mapping file written.
```

`reconciled with a cdk deploy after import` が要点です。「import では反映されない変更がコードに入っている。これは import 後の `cdk deploy` で適用されることになる」という予告で、ここでは Lambda の `LoggingConfig` がそれにあたります。

以下が、書き出された `mapping.json` の中身です。ステップ 3 でインラインに書いたものと同じです。

```json
{
  "FunctionLogGroupBD1576D5": {
    "LogGroupName": "/aws/lambda/verify-cwl-import-retention-function"
  }
}
```

この時点ではスタックのリソースは増えていません。

```bash
aws cloudformation describe-stack-resources --stack-name CwlImportRetention \
  --query 'StackResources[].LogicalResourceId'
```

```json
[
    "CDKMetadata",
    "Function76856677",
    "FunctionServiceRole675BB04A"
]
```

なお `--record-resource-mapping` は対話形式向けなので、CI などから実行すると、対応表を作る前に止まります。

```text
--resource-mapping or --resource-mapping-inline is required when input is not a terminal
```

なので、手元で作りレビューに回し、CI では `-m mapping.json` で流す、という分担になります。

**2. 変更セットだけ作って中身を見る**

`--no-execute` を付けると、変更セットを作ったところで止まります。

```bash
pnpm exec cdk import CwlImportRetention -m mapping.json --no-execute
```

```text
Perform import? (y/n) y
CwlImportRetention/FunctionLogGroup/Resource: importing using LogGroupName=/aws/lambda/verify-cwl-import-retention-function
CwlImportRetention: importing resources into stack...
CwlImportRetention: creating CloudFormation changeset...
Changeset arn:aws:cloudformation:ap-northeast-1:<account>:changeSet/cdk-deploy-change-set/09e0bd8d-... created and waiting in review for manual execution (--no-execute)

✅  CwlImportRetention
Finish with a cdk deploy now? (y/n) n
```

最後の `Finish with a cdk deploy now?` は **n** です。変更セットはまだ実行していないので、ここで y と答えると取り込みが済んでいない状態でデプロイすることになり、ステップ 2 と同じ `already exists` で失敗してしまいます。

`✅ CwlImportRetention` と出ますが、import は実行されていません。変更セットの状態で確認します。

```bash
aws cloudformation describe-change-set --change-set-name <上の ARN> \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[].ResourceChange.{Action:Action,LogicalResourceId:LogicalResourceId,ResourceType:ResourceType}}'
```

```json
{
    "Status": "CREATE_COMPLETE",
    "ExecutionStatus": "AVAILABLE",
    "Changes": [
        {
            "Action": "Import",
            "LogicalResourceId": "FunctionLogGroupBD1576D5",
            "ResourceType": "AWS::Logs::LogGroup"
        }
    ]
}
```

変更は 1 件、ロググループの `Import` だけです。Lambda も実行ロールも入っていません。「他のリソースを巻き込まない」はここでチェックできます。

**3. 確認後に実行する**

```bash
aws cloudformation execute-change-set --change-set-name <上の ARN>
aws cloudformation describe-stacks --stack-name CwlImportRetention --query 'Stacks[0].StackStatus'
```

```json
"IMPORT_COMPLETE"
```

```bash
aws cloudformation describe-stack-resources --stack-name CwlImportRetention \
  --query 'StackResources[].LogicalResourceId'
```

```json
[
    "CDKMetadata",
    "Function76856677",
    "FunctionLogGroupBD1576D5",
    "FunctionServiceRole675BB04A"
]
```

無事ロググループが取り込まれました。変更セットを人の目に通してから実行できるので、ローカルから本番に対して `cdk import` を一発で叩くよりは安心できます。

## 4. import 直後はテンプレートだけが先に進む

ここからが本題です。CloudFormation がスタックごとに保持しているテンプレートと、実リソースを別々に確認します。

**デプロイ済みテンプレート**

```bash
aws cloudformation get-template --stack-name CwlImportRetention
```

```yaml
  FunctionLogGroupBD1576D5:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/lambda/verify-cwl-import-retention-function
      RetentionInDays: 14
    UpdateReplacePolicy: Delete
    DeletionPolicy: Delete
```

**実リソース**

```bash
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/verify-cwl-import-retention
```

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": null
}
```

この時点では、まだ `cdk deploy` していないので、ロググループには何も適用されていません。

CloudFormation の import は既存リソースをスタックの管理下に置くだけで、リソース自体の値は書き換えません。一方 CDK が import 用に送るテンプレートは、**デプロイ済みテンプレート**に、**`cdk synth` したテンプレート**からコピーして作られます。なので、import に必要なのは `LogGroupName` だけですが、 `RetentionInDays: 14` も一緒に入ります。

この「テンプレートだけ先に進んだ」状態が、次のステップで効いてきます。

ドリフト検出でも同じことが確認できます。ロググループだけが `MODIFIED` です。

![ドリフト検出の結果。ロググループだけが MODIFIED で、Lambda は IN_SYNC](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699843/2026/09/18/zthijjqv6nbcyoemlkfc.png)

詳細を開くと、`RetentionInDays` の期待値が 14、現在の値は空であることが分かります。

![ドリフトの詳細。RetentionInDays の期待値 14 に対し現在の値が無い](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699849/2026/09/18/tfzszw9lbzz088n9cqyi.png)

Lambda が `IN_SYNC` なのは、`LoggingConfig` がまだテンプレートに入っていないからです。import は取り込むリソースしか触らないので、Lambda の更新は記録されていません。

## 5. cdk deploy しても保持期間は入らない

`cdk deploy` はデプロイ済みテンプレートと `cdk synth` したテンプレートの差分を見て動きます。ロググループの記述は import の時点ですでに 14 日として記録済みなので、**取り込んだリソースには差分がありません**。残っているのは Lambda の `LoggingConfig` だけです。

```bash
pnpm exec cdk diff CwlImportRetention
```

```text
Stack CwlImportRetention (aws://<account>/ap-northeast-1)
Resources
[~] AWS::Lambda::Function Function Function76856677
 └─ [+] LoggingConfig
     └─ {"LogGroup":{"Ref":"FunctionLogGroupBD1576D5"}}
```

デプロイすると、この `LoggingConfig` は反映されます。

```bash
pnpm exec cdk deploy CwlImportRetention --require-approval never
```

デプロイ後のテンプレートを見ると、ロググループの保持期間も Lambda の `LoggingConfig` も揃っています。

```text
LogGroup: {"LogGroupName": "/aws/lambda/verify-cwl-import-retention-function", "RetentionInDays": 14}
Lambda LoggingConfig: {"LogGroup": {"Ref": "FunctionLogGroupBD1576D5"}}
```

それでも実リソースは変わりません。

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": null
}
```

コンソールでも import 前とまったく同じ「失効しない」のままです。

![cdk deploy 後のロググループ。保持は import 前と同じ「失効しない」](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699854/2026/09/18/mfheg09tf3msl4ojsgr7.png)

**`cdk import` のあとに `cdk deploy` しても保持期間は入りません。** デプロイがスキップされたわけではなく、`LoggingConfig` はきちんと反映されたうえで、保持期間だけが変わっていません。

## 6. 保持期間を入れる

一番短いのは、実リソースに直接設定することです。

```bash
aws logs put-retention-policy \
  --log-group-name /aws/lambda/verify-cwl-import-retention-function --retention-in-days 14
```

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": 14
}
```

コンソールの「保持」も **2 週間** に変わります。ロググループ一覧は古い値を表示したままのことがあるので、更新ボタンを押して確認してください。

![put-retention-policy 後のロググループ。保持が「2 週間」](https://devio2024-media.developers.io/image/upload/f_auto/q_auto/v1789699858/2026/09/18/femhkbfz7sx5vjevpoyp.png)

これでテンプレートと実物が一致するので、ドリフトも解消します。

```json
{
    "s": "DETECTION_COMPLETE",
    "d": "IN_SYNC"
}
```

### CDK だけで入れる（deploy を 2 回に分ける）

`aws logs put-retention-policy` を本番に直接叩くのが怖い場合は、CDK だけで完結させることもできます。**実リソースと一致する状態で import して、そのあとに保持期間を足す**という順番です。

まず注意点があります。「保持期間を書かずに import する」では**うまくいきません**。`logs.LogGroup` は `retention` を省略すると 2 年をデフォルトにするためです。

```javascript
let retentionInDays = props.retention;
if (retentionInDays === undefined && props.logGroupClass !== DELIVERY)
  retentionInDays = RetentionDays.TWO_YEARS;          // 省略すると 731 が入る
if (retentionInDays === RetentionDays.INFINITE)
  retentionInDays = undefined;                        // INFINITE で初めて未出力になる
```

省略すると `RetentionInDays: 731` が出力されて、実リソースとまたずれます。合わせるには `retention: logs.RetentionDays.INFINITE` を指定します。

**1 回目: `INFINITE` で import する**

```typescript
const logGroup = new logs.LogGroup(this, "FunctionLogGroup", {
  logGroupName: LOG_GROUP_NAME,
  retention: logs.RetentionDays.INFINITE,  // 実物と同じ「失効しない」
  removalPolicy: cdk.RemovalPolicy.DESTROY,
});
```

`cdk synth` すると `RetentionInDays` が出力されません。

```yaml
  FunctionLogGroupBD1576D5:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/lambda/verify-cwl-import-retention-function
    UpdateReplacePolicy: Delete
    DeletionPolicy: Delete
```

この状態で import すると、デプロイ済みテンプレートも実リソースも保持期間なしで揃います。

```text
  FunctionLogGroupBD1576D5:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: /aws/lambda/verify-cwl-import-retention-function
    UpdateReplacePolicy: Delete
    DeletionPolicy: Delete
```

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": null
}
```

ドリフトも発生しません。ロググループを含めて全リソースが `IN_SYNC` です。

```json
{"s": "DETECTION_COMPLETE", "d": "IN_SYNC"}
[
    {"LogicalResourceId": "Function76856677",        "DriftStatus": "IN_SYNC"},
    {"LogicalResourceId": "FunctionLogGroupBD1576D5", "DriftStatus": "IN_SYNC"},
    {"LogicalResourceId": "FunctionServiceRole675BB04A", "DriftStatus": "IN_SYNC"}
]
```

**2 回目: `TWO_WEEKS` に変えて deploy する**

```typescript
  retention: logs.RetentionDays.TWO_WEEKS,
```

今度は `cdk diff` にロググループの差分が出ます。本記事のステップ 5 で差分がゼロだったところが、ここでは `RetentionInDays` の追加として現れます。

```text
Stack CwlImportRetention (aws://<account>/ap-northeast-1)
Resources
[~] AWS::Lambda::Function Function Function76856677
 └─ [+] LoggingConfig
     └─ {"LogGroup":{"Ref":"FunctionLogGroupBD1576D5"}}
[~] AWS::Logs::LogGroup FunctionLogGroup FunctionLogGroupBD1576D5
 └─ [+] RetentionInDays
     └─ 14
```

デプロイすると、実リソースに保持期間が入ります。

```bash
pnpm exec cdk deploy CwlImportRetention --require-approval never
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/verify-cwl-import-retention
```

```json
{
    "name": "/aws/lambda/verify-cwl-import-retention-function",
    "retentionInDays": 14
}
```

デプロイ後のドリフトも `IN_SYNC` のままです。

**どちらを選ぶか**

`put-retention-policy` は 1 コマンドで済みますが、CDK の外で実リソースを触ります。deploy を 2 回に分ける方法は、コードを一時的に `INFINITE` にする手間があるかわりに、すべて CDK の中で完結し、途中でドリフトが発生しません。本番のように AWS CLI を直接叩きたくない環境では、後者が良いかなと思います。

## 前回の記事との違い

[前回の記事](https://dev.classmethod.jp/articles/cdk-loggroup-rename-keep-old-logs/)では、import したあとに保持期間を 1 日から 14 日へ変更したところ、`cdk deploy` で反映できました。今回と結果が逆に見えますが、条件が違います。

| | 前回 | 今回 |
| --- | --- | --- |
| import 時のコードの値 | 1 日 | 14 日 |
| import 時の実リソースの値 | 1 日 | 未設定 |
| import 直後 | 一致。ドリフト無し | ずれる。ドリフトあり |
| その後の `cdk deploy` | コードを 14 日に変更したので差分が出て反映 | コードは変えていないので差分ゼロ。反映されない |

つまり、import が適用しないのは「**import する時点でコードに書いてあった値**」だけです。import 後に変更した値は普通に反映されます。前回は変更したので効き、今回は最初から書いてあったので効かなかった、という違いです。

## 後片付け

`removalPolicy: DESTROY` を指定してあるので、import したロググループもスタック削除で消えます。

```bash
pnpm exec cdk destroy CwlImportRetention --force
```

```bash
aws logs describe-log-groups \
  --log-group-name-prefix /aws/lambda/verify-cwl-import-retention --query 'logGroups'
# []
```

## まとめ

 後から、CDK 管理外のロググループ(Lambdaで自動生成されるやつとか）に保持期間を入れようとすると名前の衝突で `cdk deploy` が失敗するため、`cdk import` で取り込むことになります。しかし、 `cdk import` の仕事は「既存リソースを CDK の管理下に置く」ところまでで、値を揃えてくれるわけではありません。なので、import した際にテンプレートだけが新しい値になり、実リソースはそのまま残るパターンがありえます。

厄介なのは、この状態が `cdk diff` からは見えないことです。コードとテンプレートは一致しているため差分はゼロですが、テンプレートと実物はずれたままになります。import のあとに CDK がドリフト検出を勧めてくるのはこのためですね。ここは素直に実行して確認するのが安全です。

結果、実リソースに値を入れるには、`aws logs put-retention-policy` で直接設定するか、`retention: INFINITE`で import してから 保持期間を設定して `cdk deploy` を行う2択になります。

なお「import は実際のリソースを変更しない」は CloudFormation の仕様ですが、本記事で確認したのは `AWS::Logs::LogGroup` の場合です。他のリソースタイプでどう振る舞うかは別途確認してみてください。

本番リリース後、CDK 管理外のロググループに保持期間の設定を行いたい方はぜひ参考にしてみてください。

## 参考

- [Import AWS resources into a CloudFormation stack](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/resource-import.html)
- [Detect drift on an entire CloudFormation stack](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/detect-drift-stack.html)
- [cdk import - AWS CDK CLI Reference](https://docs.aws.amazon.com/cdk/v2/guide/ref-cli-cmd-import.html)
- [AWS::Logs::LogGroup - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-resource-logs-loggroup.html)
