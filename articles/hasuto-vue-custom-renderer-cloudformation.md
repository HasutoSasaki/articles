---
title: "VueのCustom RendererでCloudFormationテンプレートを描いてみた"
emoji: "🧱"
type: "tech"
topics: ["vue", "cloudformation", "aws", "typescript"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

Vue Fes Japan 2026でVueのCustom Rendererの話を聞きました。Custom Rendererを使うと、Vueの描画先をDOM以外に差し替えられます。それなら、描画先がCloudFormationテンプレートでもよいのでは？と気になりました。`v-if`でリソースを出し分け、`v-for`でキューを並べ、値を変えたらVueが差分だけを更新してくれるなら、その差分はCloudFormationの変更セット（change set）とどのくらい一致するのでしょうか。

本記事では、Custom RendererでVueのテンプレートからCloudFormationテンプレートを出力するレンダラーを作り、`v-if`、`v-for`、値の変更でVueが呼ぶ操作を記録しました。最後に、出力したテンプレートを実際にデプロイし、変更セットとVueの操作を並べて比べます。

## 先に結論

次のように書いたVueのテンプレートから、CloudFormationテンプレートを出力できました。値を変えてリソースを1つ足したときの変更セットに出た変更は、どれもVueが呼んだ操作と1つずつ対応していました。ただし、`key`のない`v-for`で先頭を消すと、Vueは要素の`id`を書き換える操作になり、CloudFormationから見た変更（削除）とずれます。

```vue
<Bucket id="LogsBucket" DeletionPolicy="Delete" />
<Bucket v-if="withArchive" id="ArchiveBucket" DeletionPolicy="Delete" />
<QueueWithDlq v-for="t in tenants" :key="t" :name="t" :timeout="timeout" topic="EventsTopic" />
```

動かすまでに、`vue`の差し替えと`createApp`のpropsの2か所でハマりました。どちらも素直に書くと引っかかるため、手順の中で紹介します。

## Custom Rendererとは

Vueの公式ドキュメントでは、`createRenderer()`は次のように説明されています。

> Creates a custom renderer. By providing platform-specific node creation and manipulation APIs, you can leverage Vue's core runtime to target non-DOM environments.
>
> （カスタムレンダラーを作成します。プラットフォーム固有のノードの作成と操作のAPIを渡すことで、Vueのコアのランタイムを使ってDOM以外の環境に描画できます）
>
> [Custom Renderer API - Vue.js](https://vuejs.org/api/custom-renderer#createrenderer)

渡すのは`createElement`、`patchProp`、`insert`、`remove`などの関数です。Vueはテンプレートの差分を計算し、「この要素を作る」「このpropsを書き換える」「この要素を外す」といった操作を、これらの関数の呼び出しとして伝えてきます。DOM向けのVueでは、この関数の中身が`document.createElement`や`el.setAttribute`になっているわけです。

今回は、この関数の中身を「CloudFormationのリソースを表すオブジェクトを作り、書き換え、出し入れする」処理に差し替えます。

## 検証環境

2026年10月27日時点で、次の環境で動かしました。

| 項目 | バージョン |
|---|---|
| macOS | 26.7.1 |
| Node.js | 24.22.1 |
| pnpm | 12.15.0 |
| vue / @vue/runtime-core | 3.5.44 |
| vite | 8.3.5 |
| @vitejs/plugin-vue | 6.0.10 |
| vite-node | 6.0.0 |
| AWS CLI | 2.32.30 |

`.vue`ファイルをNode.jsで動かすために、Viteの変換を通してスクリプトを実行できるvite-nodeを使います。

```bash
pnpm add vue @vue/runtime-core
pnpm add -D vite @vitejs/plugin-vue vite-node typescript @types/node
```

`package.json`には、実験のスクリプトを実行するコマンドを1つだけ置きました。

```json
{
  "scripts": {
    "exp": "vite-node"
  }
}
```

## レンダラーを書く

レンダラーの全体です。タグ名とリソースタイプの対応表を持ち、`id`を論理ID、`DeletionPolicy`などをリソース直下の属性、それ以外を`Properties`として扱います。Vueのテンプレートコンパイラは属性名の大文字と小文字を変えないため、`BucketName`のようにCloudFormationのプロパティ名をそのまま書けます。

```ts:src/renderer.ts
import { createRenderer } from '@vue/runtime-core'

// テンプレートに書くタグ名と CloudFormation のリソースタイプの対応
export const resourceTypes: Record<string, string> = {
  Bucket: 'AWS::S3::Bucket',
  Queue: 'AWS::SQS::Queue',
  Topic: 'AWS::SNS::Topic',
  Subscription: 'AWS::SNS::Subscription',
}

// Properties ではなくリソース直下に置く属性
const resourceAttributes = new Set(['DependsOn', 'DeletionPolicy', 'UpdateReplacePolicy', 'Condition'])

export type CfnElement = {
  kind: 'element'
  tag: string
  props: Record<string, unknown>
  parent: CfnParent | null
}
export type CfnRoot = { kind: 'root'; children: CfnNode[] }
// v-if や Fragment の目印として Vue が作るノード。テンプレートには出さない
export type CfnPlaceholder = { kind: 'text' | 'comment'; text: string; parent: CfnParent | null }
export type CfnNode = CfnElement | CfnPlaceholder
type CfnParent = CfnRoot | CfnElement

// レンダラーが呼ばれた操作の記録
export const ops: string[] = []

function childrenOf(parent: CfnParent): CfnNode[] {
  if (parent.kind === 'root') return parent.children
  throw new Error(`<${parent.tag}> の中に要素は置けません`)
}

function label(node: CfnNode): string {
  if (node.kind === 'element') return `<${node.tag} id=${String(node.props.id)}>`
  return node.kind
}

export const { createApp } = createRenderer<CfnNode, CfnParent>({
  createElement(tag) {
    ops.push(`createElement ${tag}`)
    return { kind: 'element', tag, props: {}, parent: null }
  },
  createText(text) {
    return { kind: 'text', text, parent: null }
  },
  createComment(text) {
    return { kind: 'comment', text, parent: null }
  },
  setText(node, text) {
    if (node.kind !== 'element') node.text = text
  },
  setElementText(el) {
    throw new Error(`<${(el as CfnElement).tag}> にテキストは置けません`)
  },
  patchProp(el, key, prev, next) {
    if (el.kind !== 'element') return
    ops.push(`patchProp ${label(el)} ${key}: ${JSON.stringify(prev)} -> ${JSON.stringify(next)}`)
    if (next == null) delete el.props[key]
    else el.props[key] = next
  },
  insert(child, parent, anchor) {
    const children = childrenOf(parent)
    const from = children.indexOf(child)
    if (from !== -1) children.splice(from, 1)
    const to = anchor ? children.indexOf(anchor) : -1
    if (to === -1) children.push(child)
    else children.splice(to, 0, child)
    child.parent = parent
    if (child.kind === 'element') ops.push(`${from === -1 ? 'insert' : 'move'} ${label(child)}`)
  },
  remove(child) {
    if (!child.parent) return
    const children = childrenOf(child.parent)
    children.splice(children.indexOf(child), 1)
    child.parent = null
    if (child.kind === 'element') ops.push(`remove ${label(child)}`)
  },
  parentNode(node) {
    return node.parent
  },
  nextSibling(node) {
    if (!node.parent) return null
    const children = childrenOf(node.parent)
    return children[children.indexOf(node) + 1] ?? null
  },
})

// ルートの子を順に読んで CloudFormation テンプレートにする
export function toTemplate(root: CfnRoot) {
  const Resources: Record<string, unknown> = {}
  const Outputs: Record<string, unknown> = {}
  for (const node of root.children) {
    if (node.kind !== 'element') continue
    const { id, ...rest } = node.props
    if (typeof id !== 'string') throw new Error(`<${node.tag}> に id がありません`)
    if (node.tag === 'Output') {
      Outputs[id] = rest
      continue
    }
    const Type = resourceTypes[node.tag]
    if (!Type) throw new Error(`<${node.tag}> に対応するリソースタイプがありません`)
    if (id in Resources) throw new Error(`論理 ID ${id} が重複しています`)
    const attrs: Record<string, unknown> = {}
    const Properties: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(rest)) (resourceAttributes.has(k) ? attrs : Properties)[k] = v
    Resources[id] = { Type, ...attrs, ...(Object.keys(Properties).length ? { Properties } : {}) }
  }
  return {
    AWSTemplateFormatVersion: '2010-09-09',
    Resources,
    ...(Object.keys(Outputs).length ? { Outputs } : {}),
  }
}

// 組み込み関数を書くための小さなヘルパー
export const Ref = (logicalId: string) => ({ Ref: logicalId })
export const GetAtt = (logicalId: string, attr: string) => ({ 'Fn::GetAtt': [logicalId, attr] })
export const Sub = (text: string) => ({ 'Fn::Sub': text })
```

`createText`と`createComment`は、Vueが`v-if`の位置や`Fragment`の境目に置く目印のノードを作るために呼びます。テンプレートには出しませんが、`insert`の`anchor`として渡されるため、ほかのノードと同じ配列に並べておく必要があります。

## スタックをVueで書く

CloudFormationのスタックに当たるものを、SFC（`.vue`ファイル）で書きます。キュー本体、デッドレターキュー（DLQ）、SNSトピックへのサブスクリプションの3つを、1つのコンポーネントにまとめました。

```vue:stacks/QueueWithDlq.vue
<script setup lang="ts">
import { computed } from 'vue'
import { GetAtt, Ref } from '../src/renderer'

const props = defineProps<{ name: string; timeout: number; topic: string }>()
// 論理 ID は英数字のみ
const base = computed(() => props.name.replace(/[^A-Za-z0-9]/g, ''))
</script>

<template>
  <Queue :id="`${base}Dlq`" :MessageRetentionPeriod="1209600" />
  <Queue
    :id="`${base}Queue`"
    :VisibilityTimeout="timeout"
    :RedrivePolicy="{ deadLetterTargetArn: GetAtt(`${base}Dlq`, 'Arn'), maxReceiveCount: 3 }"
  />
  <Subscription
    :id="`${base}Subscription`"
    Protocol="sqs"
    :TopicArn="Ref(topic)"
    :Endpoint="GetAtt(`${base}Queue`, 'Arn')"
  />
</template>
```

これを使うスタック全体です。

```vue:stacks/AppStack.vue
<script setup lang="ts">
import { Ref } from '../src/renderer'
import QueueWithDlq from './QueueWithDlq.vue'

defineProps<{ tenants: string[]; withArchive: boolean; timeout: number }>()
</script>

<template>
  <Bucket id="LogsBucket" DeletionPolicy="Delete" />
  <Bucket v-if="withArchive" id="ArchiveBucket" DeletionPolicy="Delete" />

  <Topic id="EventsTopic" />
  <QueueWithDlq v-for="t in tenants" :key="t" :name="t" :timeout="timeout" topic="EventsTopic" />

  <Output id="LogsBucketName" :Value="Ref('LogsBucket')" />
  <Output id="EventsTopicArn" :Value="Ref('EventsTopic')" />
</template>
```

複数のリソースをコンポーネントにまとめて`v-for`で並べる書き方は、CDKのConstructを使う感覚に近いと感じました。なお、SNSからSQSへメッセージを届けるには、SNSからの送信を許可する`AWS::SQS::QueuePolicy`も必要です。今回はテンプレートの出力を確かめるのが目的のため入れておらず、このスタックではメッセージは届きません。

## .vueを動かす設定でハマったこと

### vueをruntime-coreに差し替えるだけでは足りなかった

SFCのコンパイル結果は、`openBlock`や`createElementBlock`などの関数を`vue`からimportします。`vue`パッケージはDOM向けのランタイムを含むため、DOMを使わない`@vue/runtime-core`に差し替えるのが素直だと考えると思います。最初は次の設定で動かしました。

```ts:vite.config.ts（最初の設定）
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { vue: '@vue/runtime-core' },
  },
  optimizeDeps: { noDiscovery: true },
})
```

`optimizeDeps.noDiscovery`は、vite-nodeで動かすときに依存の事前バンドルを止めるために入れています。この設定でスタックを描画すると、次の警告が7回出ました。

```text
[Vue warn]: resolveComponent can only be used in render() or setup().
```

`<Bucket>`のようなタグを書いているため、「そんなコンポーネントはない」という警告が出るなら分かります。実際には「`render()`か`setup()`の中でしか使えない」という警告でした。`<script setup>`で書いたコンポーネントを描画している最中のはずなので、意外でした。

vite-nodeのデバッグログで、どのファイルが読み込まれたかを確かめます。

```bash
DEBUG='vite-node:client:native,vite-node:client:execute' pnpm exec vite-node experiments/01-basic.ts
```

実行結果です（パスは短くしています）。`native`はNode.jsがそのまま読み込んだファイル、`execute`はvite-nodeが変換して実行したファイルです。

```text
execute /experiments/01-basic.ts
execute /src/synth.ts
native /@vue/runtime-core/dist/runtime-core.cjs.js
native fs
execute /src/renderer.ts
execute /stacks/AppStack.vue
execute /@vue/runtime-core/dist/runtime-core.esm-bundler.js
native /@vue/reactivity/dist/reactivity.cjs.js
native /@vue/shared/dist/shared.cjs.js
execute /stacks/QueueWithDlq.vue
```

`@vue/runtime-core`が、cjs版（`runtime-core.cjs.js`）とesm-bundler版（`runtime-core.esm-bundler.js`）の2つ読み込まれていました。`.ts`のファイルを読んでいる途中でcjs版が、`AppStack.vue`を読んだ後にesm-bundler版が読まれています。

ここからはvite-nodeの中の話です。vite-nodeは、`node_modules`の中のファイルをNode.jsにそのまま読ませるかどうかを、ファイル名で判断していました。`.cjs.js`で終わるファイルはそのまま読ませ、それ以外は`isValidNodeImport()`で調べます。

```js:node_modules/vite-node/dist/server-Bdy4M7lM.mjs（vite-node 6.0.0、_shouldExternalize() の末尾）
	if (matchExternalizePattern(id, moduleDirectories, depsExternal)) return id;
	if (isLibraryModule && await isValidNodeImport(id)) return id;
	return false;
```

`isValidNodeImport()`は、ファイル名が`.esm-bundler.js`のような形のときに`false`を返します。

```js:同じファイルの isValidNodeImport()
	if (/\.(?:\w+-)?esm?(?:-\w+)?\.js$|\/esm?\//.test(id)) return false;
```

その結果、esm-bundler版は`_shouldExternalize()`が`false`を返し、vite-nodeが変換して実行する側に回っていました。ログの`execute`と`native`の違いは、この判断によるものです。

なぜ`.ts`と`.vue`で読み込む先が分かれたのかまでは、今回は追えていません。ただ、2つのruntime-coreがそれぞれ「いま描画中のコンポーネント」を別々に持つため、警告が出た理由は説明できます。レンダラーはcjs版で描画を進めますが、`.vue`のコンパイル結果が呼ぶ`resolveComponent`はesm-bundler版です。esm-bundler版から見ると描画中のコンポーネントがないため、警告が出ます。

ここからは`@vue/runtime-core`の中の話です。`resolveComponent`の中で呼ばれる`resolveAsset`は、描画中のコンポーネントがないとこの警告を出します。

```js:node_modules/@vue/runtime-core/dist/runtime-core.cjs.js（3.5.44）
function resolveAsset(type, name, warnMissing = true, maybeSelfReference = false) {
  const instance = currentRenderingInstance || currentInstance;
  if (instance) {
    // ...
  } else {
    warn$1(
      `resolve${shared.capitalize(type.slice(0, -1))} can only be used in render() or setup().`
    );
  }
}
```

対策として、`vue`と`@vue/runtime-core`の両方を、Node.jsが解決する同じファイルに向けました。

```ts:vite.config.ts（2つ目の設定）
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { createRequire } from 'node:module'
import { resourceTypes } from './src/renderer'

// Node 向けの @vue/runtime-core の実体
const runtimeCore = createRequire(import.meta.url).resolve('@vue/runtime-core')

const tags = new Set([...Object.keys(resourceTypes), 'Output'])

export default defineConfig({
  plugins: [
    vue({
      template: {
        compilerOptions: {
        },
      },
    }),
  ],
  resolve: {
    // テンプレートのコンパイル結果は 'vue' から import する。DOM 向けの runtime-dom を読まないよう差し替える。
    // 'vue' を '@vue/runtime-core' に差し替えるだけだと .vue からは esm-bundler 版、.ts からは cjs 版が読まれ、
    // runtime-core が 2 つ動いてしまう。両方を同じファイルに向ける
    alias: [
      { find: /^vue$/, replacement: runtimeCore },
      { find: /^@vue\/runtime-core$/, replacement: runtimeCore },
    ],
  },
  // vite-node で動かすので依存の事前バンドルは不要
  optimizeDeps: { noDiscovery: true },
})
```

### タグがコンポーネントとして探される

2つ目の設定で動かすと、警告が次のように変わりました。数字は同じ警告が出た回数です。

```text
   1 [Vue warn]: Failed to resolve component: Bucket
   1 [Vue warn]: Failed to resolve component: Output
   2 [Vue warn]: Failed to resolve component: Queue
   2 [Vue warn]: Failed to resolve component: Subscription
   1 [Vue warn]: Failed to resolve component: Topic
```

今度は「そんなコンポーネントはない」という、最初に予想していた警告です。Vueのテンプレートコンパイラは、HTMLやSVGのタグではない`<Bucket>`をコンポーネントとして扱い、`resolveComponent("Bucket")`を呼ぶコードを出力します。なお、`resolveComponent`は見つからないときにタグ名の文字列をそのまま返すため、警告は出ても要素として描画され、出力されるテンプレートは同じでした。

```js:node_modules/@vue/runtime-core/dist/runtime-core.cjs.js（3.5.44）
function resolveComponent(name, maybeSelfReference) {
  return resolveAsset(COMPONENTS, name, true, maybeSelfReference) || name;
}
```

コンポーネントとして探させないためのオプションが`isCustomElement`です。

> Should return `true` if the tag should be treated as a native custom element. For a matched tag, Vue will render it as a native element instead of attempting to resolve it as a Vue component.
>
> （タグをネイティブのカスタム要素として扱う場合に`true`を返します。一致したタグは、Vueのコンポーネントとして解決しようとせず、ネイティブの要素として描画されます）
>
> [Application API - Vue.js](https://vuejs.org/api/application.html#app-config-compileroptions-iscustomelement)

`compilerOptions`に1行足して、最終的な設定にしました。これで警告は出なくなりました。

```ts:vite.config.ts（最終的な設定の差分）
        compilerOptions: {
          // Bucket や Queue をコンポーネントではなく要素として扱わせる
          isCustomElement: (tag) => tags.has(tag),
        },
```

## createAppに渡したpropsは変えても反映されない

次に、propsを変えたときに描画が変わるかを確かめます。`createApp`の第2引数にリアクティブなオブジェクトを渡せば、あとから変えた値も追ってくれると考えると思います。

```ts:experiments/00-createapp-props.ts
// createApp に渡した props をあとから変えると、描画に反映されるか
import { nextTick, reactive } from 'vue'
import { createApp, ops } from '../src/renderer'
import AppStack from '../stacks/AppStack.vue'

const props = reactive({ tenants: ['alpha'], withArchive: true, timeout: 30 })
createApp(AppStack, props).mount({ kind: 'root', children: [] })
await nextTick()
ops.splice(0)

props.withArchive = false
await nextTick()
console.log(`withArchive を false にした後の操作: ${ops.length} 件`)

props.tenants.push('beta')
await nextTick()
console.log(`tenants に追加した後の操作: ${ops.length} 件`)
```

```bash
pnpm exp experiments/00-createapp-props.ts
```

実行結果です。

```text
withArchive を false にした後の操作: 0 件
tenants に追加した後の操作: 17 件
```

`withArchive`を変えても操作は0件で、`ArchiveBucket`は消えませんでした。一方で、`tenants`への追加はbeta用の3リソースの作成として反映されています。

ここからは`@vue/runtime-core`の中の話です。`mount`はルートのvnodeを`createVNode(rootComponent, rootProps)`で作り、`createVNode`はリアクティブなpropsを`guardReactiveProps`で浅くコピーします。

```js:node_modules/@vue/runtime-core/dist/runtime-core.cjs.js（3.5.44）
function guardReactiveProps(props) {
  if (!props) return null;
  return reactivity.isProxy(props) || isInternalObject(props) ? shared.extend({}, props) : props;
}
```

コピーされるのは1段目だけです。そのため、`withArchive`の書き換えは届かず、配列の中身の変更だけが届いていました。

対策として、propsを描画関数の中で読む小さなコンポーネントで包みました。描画関数の中で読んだ値はVueが追跡するため、書き換えると描画し直されます。

```ts:src/synth.ts
import { defineComponent, h, nextTick, type Component } from '@vue/runtime-core'
import { mkdirSync, writeFileSync } from 'node:fs'
import { createApp, ops, toTemplate, type CfnRoot } from './renderer'

// コンポーネントをマウントし、テンプレートの書き出しと操作ログの取り出しを返す
export function synth(component: Component, props?: Record<string, unknown>) {
  const root: CfnRoot = { kind: 'root', children: [] }
  // createApp に渡した props はコピーされ、あとから変えても反映されない。
  // 描画関数の中で読ませて、変更を追跡させる
  const Wrapper = defineComponent({ setup: () => () => h(component, { ...props }) })
  createApp(Wrapper).mount(root)
  return {
    template: () => toTemplate(root),
    // 前回呼んでから記録された操作を返して消す
    takeOps: () => ops.splice(0),
    async flush() {
      await nextTick()
    },
    write(file: string) {
      mkdirSync('out', { recursive: true })
      writeFileSync(`out/${file}`, JSON.stringify(toTemplate(root), null, 2) + '\n')
    },
  }
}
```

## テンプレートを出力する

準備ができたところで、スタックを描画してテンプレートを出力します。

```ts:experiments/01-basic.ts
// サンプルのスタックを描画してテンプレートを書き出す
import { synth } from '../src/synth'
import AppStack from '../stacks/AppStack.vue'

const app = synth(AppStack, { tenants: ['alpha', 'beta'], withArchive: true, timeout: 30 })
await app.flush()
console.log(app.takeOps().join('\n'))
app.write('01-basic.json')
console.log(JSON.stringify(app.template(), null, 2))
```

```bash
pnpm exp experiments/01-basic.ts
```

出力されたテンプレートの一部です。

```json:out/01-basic.json（抜粋）
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Resources": {
    "LogsBucket": {
      "Type": "AWS::S3::Bucket",
      "DeletionPolicy": "Delete"
    },
    "ArchiveBucket": {
      "Type": "AWS::S3::Bucket",
      "DeletionPolicy": "Delete"
    },
    "EventsTopic": {
      "Type": "AWS::SNS::Topic"
    },
    "alphaDlq": {
      "Type": "AWS::SQS::Queue",
      "Properties": {
        "MessageRetentionPeriod": 1209600
      }
    },
    "alphaQueue": {
      "Type": "AWS::SQS::Queue",
      "Properties": {
        "VisibilityTimeout": 30,
        "RedrivePolicy": {
          "deadLetterTargetArn": {
            "Fn::GetAtt": [
              "alphaDlq",
              "Arn"
            ]
          },
          "maxReceiveCount": 3
        }
      }
    },
```

このテンプレートと、後で出てくる実験で出力したテンプレートは、すべてcfn-lint 1.58.0と`aws cloudformation validate-template`でエラーなく通りました。

```bash
uvx cfn-lint out/*.json
```

## v-ifとv-forと値の変更で呼ばれる操作

### v-ifをfalseにする

`withArchive`を`false`にして、呼ばれた操作を出力します。

```ts:experiments/02-v-if.ts
// v-if を false にしたときにリソースがテンプレートから消えるか
import { reactive } from 'vue'
import { synth } from '../src/synth'
import AppStack from '../stacks/AppStack.vue'

const props = reactive({ tenants: ['alpha'], withArchive: true, timeout: 30 })
const app = synth(AppStack, props)
await app.flush()
app.takeOps()
app.write('02-before.json')

props.withArchive = false
await app.flush()
console.log(app.takeOps().join('\n'))
app.write('02-after.json')
```

```bash
pnpm exp experiments/02-v-if.ts
```

実行結果です。

```text
remove <Bucket id=ArchiveBucket>
patchProp <Output id=LogsBucketName> Value: {"Ref":"LogsBucket"} -> {"Ref":"LogsBucket"}
patchProp <Output id=EventsTopicArn> Value: {"Ref":"EventsTopic"} -> {"Ref":"EventsTopic"}
```

`ArchiveBucket`が`remove`され、テンプレートからも消えました。気になるのは、値が変わっていない`Output`の`Value`にも`patchProp`が呼ばれている点です。`Ref('LogsBucket')`は描画のたびに新しいオブジェクトを返し、Vueはpropsの新旧を`!==`で比べるため、中身が同じでも書き換えの対象になります。

```js:node_modules/@vue/runtime-core/dist/runtime-core.cjs.js（3.5.44、要素の動的なpropsを更新する部分）
          const propsToUpdate = n2.dynamicProps;
          for (let i = 0; i < propsToUpdate.length; i++) {
            const key = propsToUpdate[i];
            const prev = oldProps[key];
            const next = newProps[key];
            if (next !== prev || key === "value") {
              hostPatchProp(el, key, prev, next, namespace, parentComponent);
            }
          }
```

テンプレートに書き出した時点では同じJSONになるため、出力には影響しません。

### v-forの先頭を消す

`v-for`で並べた3つのキューから先頭を消します。`key`の有無で比べるため、`key`を付けたコンポーネントと付けないコンポーネントを用意しました。

```vue:stacks/TenantQueuesKeyed.vue
<script setup lang="ts">
defineProps<{ tenants: string[] }>()
</script>

<template>
  <Queue v-for="t in tenants" :key="t" :id="`${t}Queue`" :QueueName="`vue-cfn-lab-${t}`" />
</template>
```

```vue:stacks/TenantQueuesUnkeyed.vue
<script setup lang="ts">
defineProps<{ tenants: string[] }>()
</script>

<template>
  <Queue v-for="t in tenants" :id="`${t}Queue`" :QueueName="`vue-cfn-lab-${t}`" />
</template>
```

実験のスクリプトは、読み込むコンポーネントと出力先のファイル名だけが違います。`key`ありの方です。

```ts:experiments/03-v-for-keyed.ts
// v-for の先頭を消したときに呼ばれる操作
import { reactive } from 'vue'
import { synth } from '../src/synth'
import TenantQueues from '../stacks/TenantQueuesKeyed.vue'

const props = reactive({ tenants: ['alpha', 'beta', 'gamma'] })
const app = synth(TenantQueues, props)
await app.flush()
app.takeOps()

props.tenants.shift()
await app.flush()
console.log(app.takeOps().join('\n'))
app.write('03-keyed.json')
```

```bash
pnpm exp experiments/03-v-for-keyed.ts
pnpm exp experiments/03-v-for-unkeyed.ts
```

`key`ありの実行結果です。

```text
remove <Queue id=alphaQueue>
```

`key`なしの実行結果です。

```text
patchProp <Queue id=alphaQueue> id: "alphaQueue" -> "betaQueue"
patchProp <Queue id=betaQueue> QueueName: "vue-cfn-lab-alpha" -> "vue-cfn-lab-beta"
patchProp <Queue id=betaQueue> id: "betaQueue" -> "gammaQueue"
patchProp <Queue id=gammaQueue> QueueName: "vue-cfn-lab-beta" -> "vue-cfn-lab-gamma"
remove <Queue id=gammaQueue>
```

`key`がないと、Vueは要素を使い回し、alphaだった要素の`id`をbetaに、betaだった要素をgammaに書き換えてから、末尾を外していました。

一方で、出力された2つのテンプレートは同じでした。

```bash
diff out/03-keyed.json out/03-unkeyed.json
```

`diff`は何も出力しませんでした。CloudFormationはテンプレートの最終的な状態を論理IDで比べるため、テンプレートが同じであれば、どちらの場合も「alphaQueueがなくなった」という変更です。つまり、`key`なしの場合はVueの操作（`id`の書き換え）とCloudFormationから見た変更（削除）が一致しません。なお、`v-for`の2つの実験は、どちらも変更セットまでは試していません。

### 値を何度も変える

同じtickの中で`timeout`を30から40、50、60と3回変え、さらにテナントを1つ足します。

```ts:experiments/04-patch.ts
// リアクティブな値を変えたときに呼ばれる操作と、テンプレートの差分
import { reactive } from 'vue'
import { synth } from '../src/synth'
import AppStack from '../stacks/AppStack.vue'

const props = reactive({ tenants: ['alpha', 'beta'], withArchive: false, timeout: 30 })
const app = synth(AppStack, props)
await app.flush()
app.takeOps()
app.write('04-before.json')

// 同じ tick の中で 3 回変えても、反映は 1 回にまとまるか
props.timeout = 40
props.timeout = 50
props.timeout = 60
props.tenants.push('gamma')
await app.flush()
console.log(app.takeOps().join('\n'))
app.write('04-after.json')
```

```bash
pnpm exp experiments/04-patch.ts
```

実行結果のうち、`VisibilityTimeout`の行です。

```text
patchProp <Queue id=alphaQueue> VisibilityTimeout: 30 -> 60
patchProp <Queue id=betaQueue> VisibilityTimeout: 30 -> 60
```

3回変えても`patchProp`は`30 -> 60`の1回ずつでした。Vueが更新をまとめて次のtickで描画するため、途中の40と50はレンダラーまで届きません。gamma用の3リソースは`createElement`から`insert`までの操作として出ていました。

## 変更セットと並べる

`04-before.json`をデプロイしてから`04-after.json`で変更セットを作り、Vueの操作と比べます。変更セットは作るだけで、実行はしません。

```bash
aws cloudformation deploy --stack-name vue-cfn-lab --template-file out/04-before.json
aws cloudformation create-change-set --stack-name vue-cfn-lab --change-set-name timeout-60-and-gamma --template-body file://out/04-after.json
aws cloudformation describe-change-set --stack-name vue-cfn-lab --change-set-name timeout-60-and-gamma --include-property-values
```

`describe-change-set`の出力から、`alphaQueue`と`gammaDlq`の部分を抜き出しました（アカウントIDは伏せています）。

```json
{
  "Type": "Resource",
  "ResourceChange": {
    "Action": "Modify",
    "LogicalResourceId": "alphaQueue",
    "PhysicalResourceId": "https://sqs.ap-northeast-1.amazonaws.com/<account>/vue-cfn-lab-alphaQueue-eXKINcOoRgYM",
    "ResourceType": "AWS::SQS::Queue",
    "Replacement": "False",
    "Scope": [
      "Properties"
    ],
    "Details": [
      {
        "Target": {
          "Attribute": "Properties",
          "Name": "VisibilityTimeout",
          "RequiresRecreation": "Never",
          "Path": "/Properties/VisibilityTimeout",
          "BeforeValue": "30",
          "AfterValue": "60",
          "AttributeChangeType": "Modify"
        },
        "Evaluation": "Static",
        "ChangeSource": "DirectModification"
      }
    ]
  }
}
{
  "Type": "Resource",
  "ResourceChange": {
    "Action": "Add",
    "LogicalResourceId": "gammaDlq",
    "ResourceType": "AWS::SQS::Queue",
    "Scope": [],
    "Details": []
  }
}
```

変更セットに含まれていた変更は5つで、Vueの操作と次のように対応していました。

| 変更セット | Vueの操作 |
|---|---|
| `alphaQueue`をModify（`VisibilityTimeout` 30→60、置き換えなし） | `patchProp <Queue id=alphaQueue> VisibilityTimeout: 30 -> 60` |
| `betaQueue`をModify（同上） | `patchProp <Queue id=betaQueue> VisibilityTimeout: 30 -> 60` |
| `gammaDlq`、`gammaQueue`、`gammaSubscription`をAdd | 3リソース分の`createElement`から`insert`まで |

なお、`04-patch.ts`のログには、`RedrivePolicy`や`TopicArn`など値が変わらない`patchProp`も出ていました。これらはテンプレートを書き出した時点で同じJSONになっているため、CloudFormationには変更として届いていません。

確認が済んだら、スタックを削除しておきます。

```bash
aws cloudformation delete-stack --stack-name vue-cfn-lab
```

## まとめ

VueのCustom Rendererで、テンプレートの`v-if`や`v-for`がそのままCloudFormationのリソースの出し入れになり、値の変更とリソースの追加は、変更セットの`Modify`と`Add`に1つずつ対応しました。値が同じままの`patchProp`も呼ばれますが、テンプレートを書き出した時点で消えます。`key`のない`v-for`で先頭を消したときだけは、Vueが`id`を書き換える操作になり、CloudFormationから見た変更とずれる点が意外でした。

動かすまでのハマりどころは、`vue`の差し替えでruntime-coreが2つ読み込まれることと、`createApp`に渡したpropsがコピーされることの2つでした。どちらも、DOMの外にVueを持ち出すと出会いやすいハマりどころだと思います。Custom Rendererを試す方の参考になれば嬉しいです。

## 参考

- [Custom Renderer API - Vue.js](https://vuejs.org/api/custom-renderer)
- [Application API（app.config.compilerOptions.isCustomElement） - Vue.js](https://vuejs.org/api/application.html#app-config-compileroptions-iscustomelement)
- [vuejs/core - GitHub](https://github.com/vuejs/core)
- [vite-node - npm](https://www.npmjs.com/package/vite-node)
- [Update CloudFormation stacks using change sets - AWS CloudFormation](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets.html)
