---
title: "Node.jsのイベントループの各段階は、OSにシステムコールを出しているのかをstraceとbpftraceで覗いてみた"
emoji: "🔍"
type: "tech"
topics: ["javascript", "nodejs", "libuv", "strace", "bpftrace"]
published: false
---

こんにちは、製造ビジネステクノロジー部のはすとです。

前回の[epollなどのOSのシステムコールと、libuv、undici、Node.jsの関係を整理してみた](/articles/hasuto-node-fetch-undici-libuv-epoll)では、libuvのイベントループのpollの段階で`epoll_pwait()`を呼んで待っていることを確かめました。イベントループの1周には、pollのほかにもtimers、pending、idle、prepare、check、closeの段階があります。これらの段階も、OSに何かを依頼しているのでしょうか。

本記事では、strace（`-f -k`）とbpftraceを同時に動かし、それぞれの段階の中でどのシステムコールが出ているかを覗いてみます。

## 先に結論

今回の実験では、各段階の中で出たシステムコールは次のとおりでした。

| 段階 | 確かめた実験 | 段階の中で出たシステムコール |
|---|---|---|
| timers | `setTimeout`のコールバックで書く | コールバックの`write()`など |
| pending | `socket.end()`を呼ぶ | libuvが後回しにしていた`shutdown(2)` |
| idle | `setImmediate`を残したまま待つ | なし |
| prepare | すべての実験 | なし |
| poll | 同じプロセスの中でTCPの往復 | `epoll_pwait()`、`io_uring_enter()`、`accept4()`、`read()`、`write()`など |
| check | `setImmediate`のコールバックで書く | コールバックの`write()`など |
| close | `socket.destroy()`と`'close'`のコールバック | コールバックの`write()`、その中の`server.close()`による`close(2)`など |

待つためにOSを呼んでいるのは、pollの段階だけでした。timers、check、closeの段階で出ていたのは、その段階で呼ばれたJavaScriptのコールバックが出したシステムコールです。一方で、pendingの段階では、JavaScriptのコールバックではなくlibuv自身が`shutdown(2)`を呼んでいました。

また、fdを閉じる`close(2)`は、closeの段階ではなく、`uv_close()`を呼んだ段階で出ていました。closeの段階で呼ばれるのは、閉じ終わった後のコールバックです。

## 確かめ方

### strace -f -kで、全スレッドの時系列をスタック付きで取る

前回までは`strace -f`で、全スレッドのシステムコールを時系列で見てきました。今回はさらに`-k`を付けて、システムコールごとに呼び出し元のスタックを出します。スタックに`uv__io_poll`などのlibuvの関数名が出れば、どの段階から出たのかが分かるはずです。

ところが、Debianのstraceは`-k`に対応していませんでした。

```text
strace: Stack traces (-k/--stack-traces option) are not supported by this build of strace
```

そこで、2026年10月時点の安定版の最新であるstrace 7.2を、スタックをたどるためのlibdwを付けてソースからビルドしました（Dockerfileは検証環境の節に載せています）。ビルドしたstraceでは、`strace -V`の表示が次のようになりました。

```text
Optional features enabled: stack-trace=libdw no-m32-mpers secontext
```

試しに`setTimeout`と`setImmediate`を1つずつ書いたスクリプトを`strace -f -k`で動かすと、メインスレッドの`epoll_pwait()`には、libuvの関数名までスタックが出ました。名前を解決できなかったフレーム（`ld-linux-aarch64.so.1()`の行）と、関数の中の位置を表す`+0x…`は省いています。

```text:epoll_pwait() のスタック
9     13:08:15.155353 epoll_pwait(15, [], 1024, 10, NULL, 8) = 0
 > /usr/lib/aarch64-linux-gnu/libc.so.6(epoll_pwait)
 > /usr/local/bin/node(uv__io_poll)
 > /usr/local/bin/node(uv_run)
 > /usr/local/bin/node(_ZN4node21SpinEventLoopInternalEPNS_11EnvironmentE)
 > /usr/lib/aarch64-linux-gnu/libc.so.6(__libc_start_main)
```

一方で、JavaScriptのコールバックから出た`write()`は、スタックがV8の途中で切れていました。

```text:write() のスタック
9     13:08:15.168499 write(1, "T\n", 2) = 2
 > /usr/lib/aarch64-linux-gnu/libc.so.6(__write)
 > /usr/local/bin/node(uv__try_write)
 > /usr/local/bin/node(_ZThn112_N4node15LibuvStreamWrap10DoTryWriteEPP8uv_buf_tPm)
 > /usr/local/bin/node(Builtins_JSEntryTrampoline)
 > /usr/local/bin/node(Builtins_JSEntry)
 > /usr/local/bin/node(_ZN2v88internal12_GLOBAL__N_16InvokeEPNS0_7IsolateERKNS1_12InvokeParamsE)
```

`--stack-trace-frame-limit=128`でたどるフレームの数を増やしても、`v8::internal::Invoke`より先は出ませんでした。そのため、コールバックが出したシステムコールがtimersとcheckのどちらの段階のものかは、strace -kだけでは分かりません。

### bpftraceで、段階の出入りを同じ時間軸に並べる

そこで、段階の判定はbpftraceで補います。bpftraceでは、ユーザー空間の関数の入口（uprobe）と出口（uretprobe）でスクリプトを動かせます。libuvの各段階の関数に入口と出口のプローブを置き、同時にメインスレッドのシステムコールを出せば、どの段階の中で出たシステムコールかが分かります。

nodeのバイナリには関数の名前の情報が残っていて、各段階の関数のうち次のものにはプローブを置けました。

```text
uv_run                     T 0000000001c30180
uv__run_timers             t 0000000001c2bf50
uv__run_idle               t 0000000001c37f40
uv__run_prepare            t 0000000001c37b60
uv__io_poll                t 0000000001c44d04
uv__run_check              t 0000000001c37d50
uv__run_pending
uv__run_closing_handles
```

一方で、`uv__run_pending`と`uv__run_closing_handles`は名前が見つかりませんでした。どちらも`static`な関数で、`uv_run`の中に埋め込まれていると見られます。

使ったbpftraceのスクリプトです。各段階の関数の入口と出口の時刻を出し、入口では第1引数の`uv_loop_t*`を`loop=`として出しています。`uv__io_poll`では、第2引数のtimeoutも出しています。時刻はstraceの`-tt`と突き合わせるため、壁時計の時刻で出しました。

```c:phases.bt（抜粋）
uprobe:/usr/local/bin/node:uv__run_timers /comm == "node" && pid == tid/ { printf("%s [timers 開始] loop=%p\n", strftime("%H:%M:%S.%f", nsecs), arg0); }
uretprobe:/usr/local/bin/node:uv__run_timers /comm == "node" && pid == tid/ { printf("%s [timers 終了]\n", strftime("%H:%M:%S.%f", nsecs)); }
uprobe:/usr/local/bin/node:uv__io_poll /comm == "node" && pid == tid/ { printf("%s [poll 開始] loop=%p timeout=%d\n", strftime("%H:%M:%S.%f", nsecs), arg0, (int32)arg1); }
uretprobe:/usr/local/bin/node:uv__io_poll /comm == "node" && pid == tid/ { printf("%s [poll 終了]\n", strftime("%H:%M:%S.%f", nsecs)); }
tracepoint:raw_syscalls:sys_enter /comm == "node" && pid == tid/ { printf("%s     syscall %d\n", strftime("%H:%M:%S.%f", nsecs), args->id); }
```

idle、prepare、checkと`uv_run`も同じ形で書き、`uv__drain`と`uv_close`は入口だけを出しています。`pid == tid`は、JavaScriptとイベントループが動いているメインスレッドだけに絞る条件です。

### 2つを同時に動かして、時刻で突き合わせる

bpftraceの`-c`で、straceを付けたnodeを起動しました。

```bash
bpftrace phases.bt \
  -c "strace -f -k --stack-trace-frame-limit=128 -tt -o out/timers.k.log node experiments/timers.mjs" \
  > out/timers.bt.log 2>&1
```

2つのログの時刻は、そのまま突き合わせられました。たとえば、straceで`write(1, "timer callback\n", 15)`が出た23:16:49.359347は、bpftraceで記録したtimersの段階（23:16:49.190230〜23:16:49.362003）の中に入っています。

ただし、同時に動かすとstrace -kのスタックが短くなることがありました。uretprobeを置いた関数より呼び出し元の側が、スタックに出なくなります。たとえば`epoll_pwait()`のスタックは`uv__io_poll`で止まり、`uv_run`が出ませんでした。uretprobeが関数の戻り先を書き換えるためと見られます。そのため、スタックの例はstraceだけで動かしたときのものを載せています。

### pendingとcloseは、前後の段階の出入りで挟んで判定する

pendingとcloseの段階は、関数の名前が無いためプローブを置けません。そこで、libuv 1.51.0の`uv_run`の並びを使いました（[src/unix/core.c 427行目〜](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/core.c#L427)）。

```c:libuv src/unix/core.c（抜粋）
    uv__run_pending(loop);
    uv__run_idle(loop);
    uv__run_prepare(loop);
    /* 中略 */
    uv__io_poll(loop, timeout);

    for (r = 0; r < 8 && !uv__queue_empty(&loop->pending_queue); r++)
      uv__run_pending(loop);
    /* 中略 */
    uv__run_check(loop);
    uv__run_closing_handles(loop);

    uv__update_time(loop);
    uv__run_timers(loop);
```

この並びから、次の区間をpendingとcloseの段階とみなしました。

- `uv_run`の開始、または前の周のtimersの終了から、idleの開始まで: pending（1周の最初）
- pollの終了から、checkの開始まで: pending（pollの直後）
- checkの終了から、timersの開始まで: close

closeとtimersの間にある`uv__update_time`は時刻を更新するだけで、Linuxでは多くの場合システムコールを使わずに時刻を読めるvDSOで済むため、ここで出るシステムコールはcloseの段階のものとして扱いました。この判定は、bpftraceのログにシステムコール名と段階を付けるスクリプトで行っています。

:::details bpftraceのログにシステムコール名と段階を付けるスクリプト
```python:annotate.py
#!/usr/bin/env python3
"""bpftrace のログ（phases.bt の出力）に、システムコール名と「どの段階の中か」を付ける。

pending と close の段階は node のバイナリにシンボルが無く uprobe を張れないため、
uv_run の中の並び（pending → idle → prepare → poll → pending → check → close → timers）から、
前後の段階の出入りの間にあるものとして判定する。
"""
import re
import sys

names = {79: "newfstatat", 80: "fstat", 222: "mmap"}
for line in open(sys.argv[2]):
    num, name = line.split()
    names[int(num)] = name

phase = 'uv_run の外'
loop = '-'
for line in open(sys.argv[1]):
    line = line.rstrip('\n')
    m = re.match(r'^(\S+) \[(\S+) (開始|終了)\](?: loop=(\S+))?', line)
    if m:
        t, p, ev, lp = m.groups()
        if lp:
            loop = lp
        if p == 'uv_run':
            phase = 'pending（1周の最初）' if ev == '開始' else 'uv_run の外'
        elif ev == '開始':
            phase = p
        else:
            phase = {'timers': 'pending（1周の最初）', 'poll': 'pending（poll の直後）', 'check': 'close'}.get(p, phase)
            if p in ('idle', 'prepare'):
                phase = '（idle / prepare の間）'
        print(line)
        continue
    m = re.match(r'^(\S+)\s+syscall (\d+)$', line)
    if m:
        t, n = m.groups()
        print(f'{t}     {names.get(int(n), n):<16} … {phase} loop={loop if phase != "uv_run の外" else "-"}')
        continue
    print(line)
```

システムコールの番号と名前の対応（`syscall-names.txt`）は、コンテナの中の`/usr/include/asm-generic/unistd.h`から作っています。
:::

pendingの判定は、strace -kのスタックでも裏付けが取れました。詳しくはpendingの節で見ていきます。

## 検証環境

Node.js 22のDebianのイメージに、libdw付きでビルドしたstraceとbpftraceを入れました。

```dockerfile:Dockerfile
# libdw 付きでビルドした strace（-k でスタックを出せる）、bpftrace、Node.js 22 を入れたイメージ
FROM node:22.23.3-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libdw-dev xz-utils \
 && rm -rf /var/lib/apt/lists/*
COPY .cache/strace-7.2.tar.xz /tmp/
RUN cd /tmp && tar xf strace-7.2.tar.xz && cd strace-7.2 \
 && ./configure --with-libdw --enable-mpers=no \
 && make -j"$(nproc)" && make install \
 && cd / && rm -rf /tmp/strace-7.2 /tmp/strace-7.2.tar.xz
RUN apt-get update \
 && apt-get install -y --no-install-recommends bpftrace \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
```

`.cache/strace-7.2.tar.xz`は、straceの[GitHubのリリース](https://github.com/strace/strace/releases/tag/v7.2)から取得したものです。コンテナの中で確認したバージョンです。

```text
kernel:   Linux 6.8.0-64-generic aarch64
node:     v22.23.3 (uv 1.51.0)
strace:   strace -- version 7.2
bpftrace: bpftrace v0.17.0
```

macOS上のColima（Ubuntu 24.04のVM）で動かしています。bpftraceはカーネルにプログラムを読み込むため、コンテナを`--privileged`で起動し、カーネルの情報を読むための`/sys/kernel/debug`と`/sys/kernel/tracing`をマウントしました。

```bash
docker build -t node22-strace-k .
docker run --rm --privileged \
  -v /sys/kernel/debug:/sys/kernel/debug \
  -v /sys/kernel/tracing:/sys/kernel/tracing \
  -v "$PWD:/work" node22-strace-k bash run.sh
```

`run.sh`は、実験のスクリプトを1つずつ、straceとbpftraceを同時に付けて動かします。

```bash:run.sh
#!/usr/bin/env bash
# 各実験を strace -f -k と bpftrace で同時に記録する（コンテナの中で実行）
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p out
grep -E '^#define __NR_[a-z0-9_]+ [0-9]+$' /usr/include/asm-generic/unistd.h | awk '{sub("__NR_","",$2); print $3, $2}' > out/syscall-names.txt
for name in timers check idle poll pending close; do
  bpftrace phases.bt \
    -c "strace -f -k --stack-trace-frame-limit=128 -tt -o out/$name.k.log node experiments/$name.mjs" \
    > out/$name.bt.log 2>&1
done
```

ここからのbpftraceのログは、`annotate.py`で段階を付けたものから、本文で触れる行だけを抜き出しています。`loop=`は、イベントループ本体のもの（後で触れる、終了時のもう1つのループではないもの）だけを残して省きました。`…`の右側が、そのシステムコールが出た段階です。

## 1周の段階と、Node.jsが登録しているもの

libuvの各段階は、その段階に登録されたハンドルのコールバックを順に呼びます。Node.jsがどの段階に何を登録しているかは、`src/env.cc`で確かめられます（[Node.js v22.23.3 src/env.cc](https://github.com/nodejs/node/blob/v22.23.3/src/env.cc)）。

- timers: JavaScriptのタイマー全体で、1つの`uv_timer_t`を使っています（1098行目）
- idle: `setImmediate`が残っている間だけ、中身の無いコールバックで開始します（1600〜1601行目）
- prepare: CPUプロファイラ向けの`idle_prepare_handle_`がありますが、開始するのは`StartProfilerIdleNotifier`だけです（1264行目）。JavaScript側の`process._startProfilerIdleNotifier`は何もしない関数になっていて（[lib/internal/bootstrap/switches/is_main_thread.js 21行目](https://github.com/nodejs/node/blob/v22.23.3/lib/internal/bootstrap/switches/is_main_thread.js#L21)）、既定ではprepareに登録されたものは無いと見られます
- check: `setImmediate`のコールバックを実行します（1106行目）

idleのコールバックが空なのは、idleのハンドルを動かすこと自体に意味があるためです。ソースのコメントには、次のように書かれています。

> Idle handle is needed only to stop the event loop from blocking in poll.

和訳すると「idleのハンドルは、イベントループがpollで止まらないようにするためだけに必要」です。

また、Node.jsは既定のループに`UV_METRICS_IDLE_TIME`を設定しています（[src/node.cc 1598行目](https://github.com/nodejs/node/blob/v22.23.3/src/node.cc#L1598)）。この設定があると、libuvの`uv__io_poll`は1回目の`epoll_pwait()`をtimeout 0で呼び、何も届いていなければ本来のtimeoutで呼び直します（[libuv src/unix/linux.c 1393〜1400行目](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/linux.c#L1393-L1400)、[1480〜1481行目](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/linux.c#L1480-L1481)）。これまでのログで、待つ`epoll_pwait()`の直前に、timeout 0の`epoll_pwait()`が毎回出ていたのはこのためです。

## 段階ごとに確かめてみた

### timers：setTimeoutのコールバックが出すシステムコール

50ミリ秒後に標準出力へ書くだけのスクリプトです。

```js:timers.mjs
// timers: setTimeout のコールバックで標準出力に書く
setTimeout(() => {
  process.stdout.write('timer callback\n');
}, 50);
```

```text:timers.bt.log（段階を付けたもの）
23:16:49.134218 [poll 開始] timeout=50
23:16:49.139951     io_uring_enter   … poll
23:16:49.143970     epoll_pwait      … poll
23:16:49.144928     epoll_pwait      … poll
23:16:49.190187 [poll 終了]
23:16:49.190203 [check 開始]
23:16:49.190223 [check 終了]
23:16:49.190230 [timers 開始]
23:16:49.201011     ioctl            … timers
23:16:49.206250     fstat            … timers
23:16:49.230781     mmap             … timers
23:16:49.278309     madvise          … timers
23:16:49.285553     munmap           … timers
23:16:49.333164     mprotect         … timers
23:16:49.359595     write            … timers
23:16:49.362003 [timers 終了]
```

pollの段階では、timeout 50で入り、`epoll_pwait()`を2回呼んで待っています。straceでは、この2回が`epoll_pwait(15, [], 1024, 0, …)`と`epoll_pwait(15, [], 1024, 39, …)`で、`UV_METRICS_IDLE_TIME`の形どおりでした。

timersの段階の中では、`write()`のほかに`ioctl()`や`fstat()`、`mmap()`などが出ています。`ioctl()`のスタックには`uv_guess_handle`が出ていたため、最初に標準出力を使うときに、標準出力が端末かどうかを調べていると見られます。`mmap()`などはV8のメモリ操作と見られますが、今回は確かめていません。どれもコールバックの中の処理で、`uv__run_timers`自体はタイマーを取り出してコールバックを呼ぶだけです（[src/timer.c 165行目](https://github.com/libuv/libuv/blob/v1.51.0/src/timer.c#L165)）。

### pending：socket.end()のshutdown(2)は、ここで出る

pendingの段階では、libuvが「次の周で処理する」と後回しにしたものを実行します。後回しにするのは`uv__io_feed`で、書き込みの完了（[src/unix/stream.c 736行目](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/stream.c#L736)）や、`uv_shutdown`（[1183行目](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/stream.c#L1183)）などから呼ばれます。`uv_shutdown`のコメントには、`shutdown(2)`は`uv__drain`まで後回しにすると書かれていました。

そこで、ソケットの書き込み側を閉じる`socket.end()`を呼ぶスクリプトを動かしました。サーバーとクライアントは同じプロセスの中にあります。

```js:pending.mjs
// pending: socket.end() で書き込み側を閉じる（libuv は shutdown(2) を後回しにする）
import net from 'node:net';

const server = net.createServer((socket) => {
  socket.on('end', () => {
    process.stdout.write('server got end\n');
    server.close();
  });
  socket.resume();
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  const client = net.connect(port, '127.0.0.1', () => {
    process.stdout.write('client calls end\n');
    client.end();
  });
});
```

```text:pending.bt.log（段階を付けたもの）
23:17:27.854875     write            … poll
23:17:27.857066 [poll 終了]
23:17:27.857093   (uv__drain)
23:17:27.863998     shutdown         … pending（poll の直後）
23:17:27.865403 [check 開始]
```

接続の完了のコールバックで`client.end()`を呼んだのはpollの段階の中ですが、`shutdown(2)`はその場では出ていません。pollが終わった直後のpendingの段階で`uv__drain`が呼ばれ、そこで`shutdown(2)`が出ています。

strace -kのスタックでも、`shutdown(2)`は`uv__drain`から呼ばれていました。

```text:pending.k.log
109   23:17:27.863775 shutdown(22, SHUT_WR) = 0
 > /usr/lib/aarch64-linux-gnu/libc.so.6(shutdown)
 > /usr/local/bin/node(uv__drain)
 > /usr/local/bin/node(uv_run)
 > /usr/lib/aarch64-linux-gnu/libc.so.6(__libc_start_main)
```

`uv__drain`のすぐ下が`uv_run`になっているのは、`uv__run_pending`が`uv_run`の中に埋め込まれているためと見られます。pendingの段階では、JavaScriptのコールバックではなく、libuv自身がシステムコールを出していました。

### idle：setImmediateが残っていると、pollで待たなくなる

idleの効果を見るため、1秒のタイマーと`setImmediate`を両方置きました。straceを付けると処理が遅くなるため、タイマーが待つ前に期限切れにならないよう、1秒にしています。

```js:idle.mjs
// idle: setImmediate が残っている間は idle が動き、poll で待たなくなるかを見る
// strace で遅くなってもタイマーが先に期限切れにならないよう、タイマーは 1 秒にする
setTimeout(() => {
  process.stdout.write('timer callback\n');
}, 1000);
setImmediate(() => {
  process.stdout.write('immediate callback\n');
});
```

```text:idle.bt.log（段階を付けたもの）
23:18:20.771428 [idle 開始]
23:18:20.771433 [idle 終了]
23:18:20.771438 [prepare 開始]
23:18:20.771443 [prepare 終了]
23:18:20.771449 [poll 開始] timeout=0
23:18:20.778389     io_uring_enter   … poll
23:18:20.782933     epoll_pwait      … poll
23:18:20.783482 [poll 終了]
23:18:20.783492 [check 開始]
23:18:20.944626     write            … check
23:18:20.945747 [check 終了]
23:18:20.945760 [timers 開始]
23:18:20.945767 [timers 終了]
23:18:20.945773 [idle 開始]
23:18:20.945778 [idle 終了]
23:18:20.945783 [prepare 開始]
23:18:20.945788 [prepare 終了]
23:18:20.945794 [poll 開始] timeout=826
23:18:20.949489     epoll_pwait      … poll
23:18:20.950167     epoll_pwait      … poll
23:18:21.781916 [poll 終了]
```

`setImmediate`が残っている周は、1秒のタイマーがあるにもかかわらず、pollにtimeout 0で入っています。`epoll_pwait()`も1回だけで、待たずに戻っています。`setImmediate`のコールバックを実行した後の周は、timeoutが826になり、`epoll_pwait()`をtimeout 0とtimeout 822の2回呼んで、タイマーの時刻まで待っていました。

idleの段階の中では、どちらの周でもシステムコールは出ていません。idleの段階は、ハンドルがあることでpollのtimeoutを0にする役割で、段階そのものはOSに何も依頼していませんでした。

### prepare：何も登録されていない

prepareの段階は、どの実験でも開始と終了の間にシステムコールが1件もありませんでした。idleの節のログでも、`[prepare 開始]`と`[prepare 終了]`の間は空です。Node.jsが既定では何も登録していないため、prepareの段階は空の一覧を回すだけと見られます。

### poll：待つためにOSを呼ぶのはここだけ

同じプロセスの中でTCPのサーバーとクライアントをつなぎ、応答を受け取るスクリプトです。

```js:poll.mjs
// poll: 同じプロセスの中でサーバーとクライアントをつなぎ、応答を待つ
import net from 'node:net';

const server = net.createServer((socket) => {
  socket.on('data', () => {
    setTimeout(() => socket.end('pong'), 100);
  });
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  const client = net.connect(port, '127.0.0.1', () => {
    client.write('ping');
  });
  client.on('data', (data) => {
    process.stdout.write(`client received ${data}\n`);
  });
  client.on('end', () => server.close());
});
```

```text:poll.bt.log（段階を付けたもの）
23:17:16.263154 [poll 開始] timeout=-1
23:17:16.272289     io_uring_enter   … poll
23:17:16.278018     epoll_pwait      … poll
23:17:16.287362     accept4          … poll
23:17:16.291415     getsockopt       … poll
23:17:16.296780     write            … poll
23:17:16.298134 [poll 終了]
```

タイマーが無いため、pollにはtimeout -1（無期限）で入っています。`epoll_pwait()`でつながってきた接続を受け取り、`accept4()`で受け入れ、接続のコールバックで`write()`しています。この実験では、イベントループ本体のシステムコールのうち27件がpollの段階の中で出ていて、待つための`epoll_pwait()`はすべてpollの中でした。

なお、このスクリプトでは、timersの段階で`socket.end('pong')`の`write()`が出た後、次の周の最初のpendingの段階で`shutdown(2)`が出ていました。pendingの節で見た後回しは、pollの直後だけでなく、1周の最初でも起きます。

### check：setImmediateのコールバックが出すシステムコール

`setImmediate`のコールバックで標準出力に書くスクリプトです。

```js:check.mjs
// check: setImmediate のコールバックで標準出力に書く
setImmediate(() => {
  process.stdout.write('immediate callback\n');
});
```

```text:check.bt.log（段階を付けたもの）
23:16:58.064034 [check 開始]
23:16:58.075027     ioctl            … check
23:16:58.077521     fstat            … check
23:16:58.098852     mmap             … check
23:16:58.157937     madvise          … check
23:16:58.166404     munmap           … check
23:16:58.210527     mprotect         … check
23:16:58.233515     write            … check
23:16:58.234884 [check 終了]
```

timersの節と同じ形のシステムコールが、checkの段階の中で出ています。checkの段階でも、システムコールを出しているのは`setImmediate`のコールバックでした。

### close：fdを閉じるのはここではない

`socket.destroy()`でソケットを閉じ、`'close'`のコールバックで標準出力に書くスクリプトです。

```js:close.mjs
// close: socket.destroy() で閉じ、'close' イベントのコールバックで標準出力に書く
import net from 'node:net';

const server = net.createServer((socket) => {
  socket.resume();
});

server.listen(0, '127.0.0.1', () => {
  const { port } = server.address();
  const client = net.connect(port, '127.0.0.1', () => {
    process.stdout.write('client calls destroy\n');
    client.destroy();
  });
  client.on('close', () => {
    process.stdout.write('client close callback\n');
    server.close();
  });
});
```

```text:close.bt.log（段階を付けたもの）
23:17:38.507606     write            … poll
23:17:38.515179     ioctl            … poll
23:17:38.518812     fstat            … poll
23:17:38.523428   (uv_close)
23:17:38.540146     epoll_ctl        … poll
23:17:38.556903     close            … poll
23:17:38.562578 [poll 終了]
23:17:38.562605 [check 開始]
23:17:38.562616 [check 終了]
23:17:38.562623   (uv__drain)
23:17:38.563029     write            … close
23:17:38.566440   (uv_close)
23:17:38.566810     epoll_ctl        … close
23:17:38.570080     close            … close
23:17:38.573887 [timers 開始]
```

`client.destroy()`は接続のコールバックの中、つまりpollの段階で呼ばれています。そのときに`uv_close`が呼ばれ、同じpollの段階の中で`epoll_ctl()`（epollからの登録の削除）と`close(2)`が出ていました。libuvの`uv_close`は、ストリームならその場で`uv__stream_close`を通してfdを閉じます。

closeの段階で出ていたのは、`'close'`のコールバックの`write()`と、その中で呼んだ`server.close()`による`epoll_ctl()`と`close(2)`です。closeの段階の`uv__finish_close`は、ストリームの片付け（`uv__stream_destroy`の中で`uv__drain`も呼ばれます）を済ませてから、閉じ終わった後のコールバックを呼んでいました。`uv__drain`は呼ばれていましたが、ここでは`shutdown(2)`を出していません。

## メインスレッドで動くもう1つのループと、ほかのスレッド

段階の関数の`loop=`を見ると、メインスレッドでは2つのループが動いていました。1つは、ここまで見てきたイベントループ本体（`epoll_pwait(15, …)`のループ）です。もう1つは、プロセスの終了時に1周だけ回るループで、`epoll_pwait(3, …)`をtimeout 0で1回呼んでいました。

```text:timers.bt.log（段階を付けたもの）
23:16:49.903113 [uv_run 開始] loop=0x2b491db8
23:16:49.903120 [idle 開始] loop=0x2b491db8
23:16:49.903132 [prepare 開始] loop=0x2b491db8
23:16:49.903142 [poll 開始] loop=0x2b491db8 timeout=0
23:16:49.908879     io_uring_enter   … poll loop=0x2b491db8
23:16:49.912712     epoll_pwait      … poll loop=0x2b491db8
```

このループが何のためのものかは、今回は確かめていません。ここまでの表や件数は、イベントループ本体のものだけを数えています。

メインスレッドの外では、`DelayedTaskScheduler`という名前のスレッドが、自分専用のlibuvのループを回していました。strace -kのスタックには、epollへの登録をまとめて送る`uv__epoll_ctl_flush`も出ています。

```text:timers.k.log
38    23:16:45.702515 <... io_uring_enter resumed>) = 2
 > /usr/lib/aarch64-linux-gnu/libc.so.6(syscall)
 > /usr/local/bin/node(uv__epoll_ctl_flush)
 > /usr/local/bin/node(uv__io_poll)
```

ほかにも、ファイル操作を受け持つ`libuv-worker`や、V8の作業用の`V8Worker`といったスレッドがあります。今回の実験は、ファイル操作を含まないものにして、これらのスレッドは対象から外しました。

## まだ確かめていないこと

- プロセスの終了時に1周だけ回る、もう1つのループ（`epoll_pwait(3, …)`）が何のためのものか
- timersとcheckの段階で出た`mmap()`などが、V8のどの処理から出ているか
- straceで遅くなったことで、段階の並びや件数がどれくらい変わっているか

## まとめ

Node.jsのイベントループの各段階のうち、待つためにOSを呼んでいたのはpollの段階だけでした。idleとprepareの段階ではシステムコールは1件も出ず、timers、check、closeの段階で出ていたのは、その段階で呼ばれたJavaScriptのコールバックのシステムコールです。一方で、pendingの段階ではlibuv自身が、後回しにしていた`shutdown(2)`を呼んでいました。

意外だったのは、closeの段階ではfdを閉じていなかったことです。`close(2)`は`uv_close()`を呼んだ段階で出ていて、closeの段階では閉じ終わった後のコールバックを呼んでいるだけでした。

strace -kとbpftraceは、片方だけでは段階との対応が取れませんでしたが、組み合わせることで、どの段階で何が出ているかを確かめることができました。私と同じように「pollの段階以外では何が起きているんだろう」と気になった方の参考になれば嬉しいです。

## 参考

- [libuv v1.51.0 src/unix/core.c - GitHub](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/core.c)
- [libuv v1.51.0 src/unix/stream.c - GitHub](https://github.com/libuv/libuv/blob/v1.51.0/src/unix/stream.c)
- [Node.js v22.23.3 src/env.cc - GitHub](https://github.com/nodejs/node/blob/v22.23.3/src/env.cc)
- [Design overview - libuv](https://docs.libuv.org/en/v1.x/design.html)
- [strace(1) - Linux manual page](https://man7.org/linux/man-pages/man1/strace.1.html)
- [bpftrace Reference Guide - GitHub](https://github.com/bpftrace/bpftrace/blob/master/man/adoc/bpftrace.adoc)
- [strace v7.2 - GitHub](https://github.com/strace/strace/releases/tag/v7.2)
