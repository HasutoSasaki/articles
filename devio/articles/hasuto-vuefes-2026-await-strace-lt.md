---
title: "Vue Fes Japan 2026で「あなたの await、OS まで届いてる？ strace で覗く JavaScript の非同期」というタイトルで登壇しました"
emoji: "🎤"
type: "tech"
topics: ["vuefes", "javascript", "nodejs", "strace"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

2026年10月24日に大手町プレイス ホール&カンファレンスで開催された[Vue Fes Japan 2026](https://vuefes.jp/2026/)の[ライトニングトーク枠](https://vuefes.jp/2026/timetable)で、「あなたの await、OS まで届いてる？ strace で覗く JavaScript の非同期」というタイトルで5分間お話ししました。本記事では、登壇資料と伝えたかったことをまとめます。

## Vue Fes Japan 2026とは

https://vuefes.jp/2026/

Vue Fes Japanは、Vue.js日本ユーザーグループが主催するフロントエンドのカンファレンスです。公式サイトでは「日本最大級のフロントエンドカンファレンス」と紹介されており、Vue.jsに閉じず、JavaScriptコミュニティで活躍するOSS開発者が集まるお祭りのようなイベントです！

## 登壇資料

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9)

`await`はPromiseを待つだけでOSには届かず、OSに届いていたのは`fetch()`が返すPromiseを解決するための処理だった、という話です。スライドに載せたログとコードは次のリポジトリに置いています。Dockerがあれば`docker compose up --build`で全部の実験を再現できます。

https://github.com/HasutoSasaki/vuefes-2026-await-strace

## 伝えたかったこと

`await fetch()`と書いたとき、待っている間にOSは何をしているのか。これを`strace`で確かめるという内容で、3つの問いで進めました。

計測はNode.js v22.23.3とstrace 6.1で、手元のMacのDocker（Colima）上のDebian 12で行いました。
`epoll_pwait`はLinuxの仕組みで、macOSではkqueue、WindowsではIOCPをlibuvが使います。スライドのログはどれもLinuxでの話です。

### await した時に、OS には何が届くのか

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=8)

`await fetch()`をMARKで挟んで`strace`を取ると、`socket()`でソケットを作り、`connect()`で接続を始め、`write()`でGETリクエストを書き込んだあと、Node.jsのスレッドは`epoll_pwait()`の中で応答が届くまで止まります。届いたら`read()`で読みます。`fetch()`が返すPromiseを解決するための処理が、OSまで届いていました。

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=9)

`await Promise.resolve()`に置き換えると、MARKの間には何も出ません。`await`はPromiseを待つだけで、OSには何も届いていませんでした。

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=11)

システムコールを出しているのはlibuvです。libuvはイベントループのpollフェーズで、作ったソケットをepollに登録してから`epoll_pwait`を呼びます。`epoll_pwait`は、登録したソケットのどれかに応答が届くまでOSに待ってもらう仕組みです。応答が届くとOSが`epoll_pwait`を戻し、libuvが`read`して、Promiseが解決し、`await`の続きが動きます。

### 直列と Promise.all は、OS から見ると何が違うのか

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=14)

ここからは、モックサーバーが300ms待ってから応答します。直列（`await fetch(); await fetch()`）は、1本目のソケットだけを登録して`epoll_pwait`で待ち、2本目の`socket`と`connect`は1本目の応答を読んでから出ています。

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=15)

`Promise.all`は、2本ともソケットを作って接続を始めてから`epoll_pwait`に入ります。`epoll_pwait`は1回で、そのあと2本の応答を読んでいます。

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=16)

所要時間は直列が約640ms、`Promise.all`が約330msで、約半分でした。`Promise.all`が速いのは、`await`で止まる前に2本とも`fetch()`を呼んでいるためです。2本とも登録してから`epoll_pwait`に入れるため、2本分の待ちが1回の待ちに重なります。

### Nuxt の useFetch に置き換えると

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=18)

Nuxtの`useFetch`でも同じことを試しました。`await useFetch`を2回並べると直列と同じ形になり、1本目の応答待ちが終わってから2本目の`connect`が出ています。

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=19)

`Promise.all`で束ねると、2本とも`connect`してから`epoll_pwait`が1回で、同じ形になりました。初回リクエストの所要時間は748msと436msです。

### まとめとして話したこと

@[speakerdeck](5e29ec9e26f34cd5a23f369d3d2c99e9?slide=21)

`await`はPromiseを待つだけで、OSには届きません。OSに届いていたのは、`fetch()`が返すPromiseを解決するための処理でした。JavaScriptが止まったあとにlibuvがソケット操作を出し、pollフェーズの`epoll_pwait`で応答を待っていました。

## 最後に

Vue Fes Japanという大きな舞台での登壇は初めてで、とても緊張しましたが、楽しかったです！登壇後は、Xや懇親会等で反応をいただけて嬉しかったです。

スライドを作る過程で、自分の理解も整理されました。ログを見ながら「`fetch()`が返すPromiseを解決するための処理が届く」と言い直す作業を繰り返したことで、イベントループとlibuvの役割分担を自分の言葉で説明できるようになりました。次はもう少し長い枠でも話してみたいと思います。

## 参考

- [Vue Fes Japan 2026](https://vuefes.jp/2026/)
- [検証一式（GitHub）- HasutoSasaki/vuefes-2026-await-strace](https://github.com/HasutoSasaki/vuefes-2026-await-strace)
- [Node.js の非同期処理をシステムコールから覗く - DevelopersIO](https://dev.classmethod.jp/articles/nodejs-async-deep-dive-with-syscalls/)
- [Node.js の fetch を strace で追う - DevelopersIO](https://dev.classmethod.jp/articles/nodejs-fetch-strace/)
- [複数 fetch の直列 vs Promise.all を strace で比べる - DevelopersIO](https://dev.classmethod.jp/articles/nodejs-multiple-fetch-strace/)
- [JS の非同期処理は epoll で成り立っているのか（Node.js / Deno / Bun）- DevelopersIO](https://dev.classmethod.jp/articles/hasuto-js-async-epoll-node-deno-bun/)
- [The Node.js Event Loop - Node.js](https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick)
- [epoll_wait(2) - Linux manual page](https://man7.org/linux/man-pages/man2/epoll_wait.2.html)
