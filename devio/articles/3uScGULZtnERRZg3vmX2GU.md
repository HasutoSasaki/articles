人材育成室 育成メンバーチームで 研修中の はす です。

普段 Node.js を使っていて、非同期処理 はよく出てきますが、「具体的にどう動いているの？」 と聞かれると、「メインの処理とは別の場所で動いていて、完了したら戻ってくる？みたいな」 曖昧な答えしか言えず、モヤモヤしました。そのため今回は、Node.js の非同期処理について具体的な説明をできるようになるのがゴールです。

## そもそも Node.js の環境について

まずは、そもそもの Node.js とはというところを見ていきます。
Node.js のアーキテクチャは主に、JavaScript層・バインディング層・V8・libuv の4層構造になっています。
簡単に説明をすると、

- JavaScript層は、普段私たちが書く際に触れるレイヤー
- バインディング層は、JavaScript層とC/C++のネイティブ層（libuvなど）を繋ぐレイヤー
- V8は、Googleが開発したJavaScriptエンジンで、コードの解析・実行、メモリ管理などを担当するレイヤー
- libuvは、Node.js の非同期I/Oを実現するためのライブラリで、イベントループやスレッドプールなどを提供するレイヤー

ということで、今回は 非同期処理の仕組みを理解するために、**libuv** に焦点を当てます。

## スレッドとは

プロセス内で動作する処理単位になります。1つのプロセス内で複数のスレッドが動作することができます。
例でいうと、レストランのキッチンがプロセスで、厨房で働くシェフがスレッドになります。
では、メモリはどうでしょうか？ プロセスは独立したメモリ空間を持ちますが、スレッドは同じプロセス内でメモリを共有します。
つまりは、同じキッチン内で働くシェフは、同じ材料や道具を共有しているイメージです。

## シングルスレッドなのに、マルチスレッドに見えるのはなぜ？

Node.js はシングルスレッドで動作しますが、非同期処理を行う際に、まるでマルチスレッドのように見えることがあります。
まず、Node.js におけるシングルスレッドとは、あくまで JavaScript のコードが実行されるスレッドのことを指すことが多いようです。では、非同期処理はどこで行われているかというと、ネットワークI/O などはカーネルの仕組み（epoll等）を利用し、ファイルI/O などカーネルが非同期に対応していな非同期に対応していない操作は libuv のスレッドプール（ワーカースレッド）で行われます。そして、どの処理をどの順番で行うかや、完了のタイミングの監視などは、Node.js のイベントループが担当しています。

## strace コマンドを使って、Node.js の動きを見てみる

まずは、Node.js の基本を見るために、何もコードがない状態で、統計情報を出してみます。

```
$ strace -c node node/async/baseline.js
% time     seconds  usecs/call     calls    errors syscall
------ ----------- ----------- --------- --------- ------------------
 41.71    0.002146         119        18         3 openat
 17.82    0.000917         101         9         4 statx
  9.43    0.000485           7        64           mmap
  6.38    0.000328           4        68           munmap
  3.63    0.000187           6        27           mprotect
  3.25    0.000167           7        22           read
  2.93    0.000151           3        39           futex
  2.00    0.000103           4        21           close
  1.77    0.000091           1        63           rt_sigaction
  1.71    0.000088           4        18           fstat
  1.24    0.000064          10         6           clone
  0.99    0.000051           1        26        14 fcntl
  0.93    0.000048           1        27           getpid
  0.64    0.000033           2        15           capget
  0.60    0.000031           1        24           ioctl
  0.60    0.000031           2        15           getuid
  0.54    0.000028           1        15           getgid
  0.52    0.000027           0        31           rt_sigprocmask
  0.51    0.000026           1        15           geteuid
  0.51    0.000026           1        15           getegid
  0.35    0.000018           1        17           brk
  0.31    0.000016           0        27           madvise
  0.25    0.000013          13         1           set_tid_address
  0.25    0.000013          13         1           set_robust_list
  0.23    0.000012          12         1           rseq
  0.16    0.000008           2         3           pipe2
  0.16    0.000008           1         8           prlimit64
  0.12    0.000006           1         4           epoll_ctl
  0.10    0.000005           2         2           write
  0.06    0.000003           1         2           eventfd2
  0.06    0.000003           1         2           epoll_create1
  0.06    0.000003           3         1           prctl
  0.04    0.000002           0         3           epoll_pwait
  0.04    0.000002           1         2           getrandom
  0.04    0.000002           1         2         2 io_uring_setup
  0.04    0.000002           2         1         1 clone3
  0.02    0.000001           1         1           getcwd
  0.00    0.000000           0         1         1 faccessat
  0.00    0.000000           0         1           readlinkat
  0.00    0.000000           0         1           sched_getaffinity
  0.00    0.000000           0         1           gettid
  0.00    0.000000           0         1           execve
------ ----------- ----------- --------- --------- ------------------
100.00    0.005145           8       621
```

たくさん出てきましたが、この中から今回注目したいシステムコールをピックアップしてみます。

**ピックアップした各システムコールについての説明**

| システムコール     | 説明                                                                 |
| ------------------ | -------------------------------------------------------------------- |
| `clone` / `clone3` | プロセスやスレッドの作成に使用。                                     |
| `futex`            | スレッド間の待機・起床などの同期に使用。                             |
| `epoll_create1`    | epoll インスタンスの作成に使用。                                     |
| `epoll_ctl`        | epoll インスタンスに対してファイルディスクリプタの登録や削除を実施。 |
| `epoll_pwait`      | epoll インスタンスでイベントの発生を待ちます。                       |

特に epoll 3兄弟（ create1 → ctl　→ pwait）はイベントループの要になります。

では、`epoll_create1`, `epoll_ctl`, `epoll_pwait` に着目して、システムコールの流れを追ってみましょう。

```bash
$ strace -f -e trace=epoll_create1,epoll_ctl,epoll_pwait node node/async/baseline.js > /dev/null
epoll_create1(EPOLL_CLOEXEC)            = 3
strace: Process 45 attached
[pid    45] epoll_create1(EPOLL_CLOEXEC) = 9
[pid    45] epoll_ctl(9, EPOLL_CTL_ADD, 10, {events=EPOLLIN, data={u32=10, u64=10}}) = 0
[pid    45] epoll_ctl(9, EPOLL_CTL_ADD, 12, {events=EPOLLIN, data={u32=12, u64=12}}) = 0
[pid    45] epoll_pwait(9, strace: Process 47 attached
strace: Process 46 attached
strace: Process 48 attached
strace: Process 49 attached
 <unfinished ...>
[pid    44] epoll_create1(EPOLL_CLOEXEC) = 13
strace: Process 50 attached
[pid    44] epoll_ctl(13, EPOLL_CTL_ADD, 14, {events=EPOLLIN, data={u32=14, u64=14}}) = 0
[pid    44] epoll_ctl(13, EPOLL_CTL_ADD, 16, {events=EPOLLIN, data={u32=16, u64=16}}) = 0
[pid    44] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0
[pid    44] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0
[pid    45] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=12, u64=12}}], 1024, -1, NULL, 8) = 1
[pid    49] +++ exited with 0 +++
[pid    45] +++ exited with 0 +++
[pid    48] +++ exited with 0 +++
[pid    47] +++ exited with 0 +++
[pid    46] +++ exited with 0 +++
[pid    44] epoll_ctl(3, EPOLL_CTL_ADD, 6, {events=EPOLLIN, data={u32=6, u64=6}}) = 0
[pid    44] epoll_ctl(3, EPOLL_CTL_ADD, 8, {events=EPOLLIN, data={u32=8, u64=8}}) = 0
[pid    44] epoll_pwait(3, [], 1024, 0, NULL, 8) = 0
[pid    50] +++ exited with 0 +++
+++ exited with 0 +++

```

色々書いてあって訳が分からなくなりそうですが、ゆっくり紐解いていきます。

まず、 `epoll_create1` で epoll インスタンスを作成します。これ以降、イベントの監視はこのインスタンスを通じて行われます。
次に、 `epoll_ctl` で監視対象のファイルディスクリプタを登録します。
そして最後に、 `epoll_pwait` でイベントの発生を待ちます。
この流れが、Node.js のイベントループの基本的な動作になります。

では次に、実際の非同期処理の流れを追ってみましょう。

## 実際に非同期処理の流れを追ってみる

検証用としてファイル読み込みの実装を、同期と非同期の両方で比較してみます。

### 準備

コードは以下の通りです。

```javascript:同期の処理
const fs = require("fs");
const data = fs.readFileSync("/etc/hostname", "utf8");
console.log(data);
```

```javascript:非同期の処理
const fs = require("fs");
fs.readFile("/etc/hostname", "utf8", (err, data) => {
  console.log(data);
});
```

※ /etc/hostname はマシンのホスト名が書いてあるファイルです。

```bash
$ cat /etc/hostname
my-machine-name
```

### 同期処理を strace で確認

strace の trace オプションで、今回注目したいシステムコールだけを抜き取っています。

```bash
 $ strace -f -T -e trace=openat,read,write,close,futex,epoll_ctl,epoll_pwait node node/async/file-read-sync.js > /dev/null
```

一番の見どころである、ファイルの読み込み部分を抜き取ると、以下のようになっています。
※ pid とは、プロセスIDのことです。

```bash
...
[pid 27] openat("/etc/hostname", O_RDONLY|O_CLOEXEC) = 17     // メインスレッドが開く
[pid 27] read(17, "82d03664b7c1\n", 8192) = 13               // メインスレッドが読む
[pid 27] read(17, "", 8192) = 0                               // EOF（読み終わり）
[pid 27] close(17) = 0                                        // メインスレッドが閉じる
[pid 27] write(1, "82d03664b7c1\n\n", 14) = 14               // console.log（stdout）
...
```

全て pid 27（メインスレッド）になっており、ワーカースレッドは一切関与していないことがわかります。
※ pid は実行の都度割り当てられる番号なので、常に`27`がメインスレッドになるわけではない点に注意してください。

:::details 全てのシステムコール

```bash
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3 <0.000048>
close(3)                                = 0 <0.000040>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libdl.so.2", O_RDONLY|O_CLOEXEC) = 3 <0.000069>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000055>
close(3)                                = 0 <0.000039>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libstdc++.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000111>
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000069>
close(3)                                = 0 <0.000048>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libm.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000094>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000064>
close(3)                                = 0 <0.000038>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libgcc_s.so.1", O_RDONLY|O_CLOEXEC) = 3 <0.000081>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000056>
close(3)                                = 0 <0.000049>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libpthread.so.0", O_RDONLY|O_CLOEXEC) = 3 <0.000097>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000066>
close(3)                                = 0 <0.000041>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000049>
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\360\206\2\0\0\0\0\0"..., 832) = 832 <0.000042>
close(3)                                = 0 <0.000047>
futex(0xe64893ad37ec, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000025>
futex(0x6244a80, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000026>
futex(0x6245360, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000027>
futex(0x6245364, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000023>
futex(0x6245368, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000030>
futex(0x6245468, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000027>
futex(0x6245374, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000022>
futex(0x624d7f8, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000024>
futex(0x6245058, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000023>
futex(0x6244e40, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000024>
futex(0x62453a4, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000026>
futex(0x6244d30, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000025>
futex(0x624536c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000024>
openat(AT_FDCWD, "/etc/ssl/openssl.cnf", O_RDONLY) = 3 <0.000085>
read(3, "#\n# OpenSSL example configuratio"..., 4096) = 4096 <0.000033>
read(3, "d attributes must be the same, a"..., 4096) = 4096 <0.000023>
read(3, "coding of an extension: beware e"..., 4096) = 4096 <0.000040>
read(3, " = $insta::certout # insta.cert."..., 4096) = 36 <0.000031>
read(3, "", 4096)                       = 0 <0.000028>
close(3)                                = 0 <0.000028>
futex(0x624537c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000022>
futex(0x62454c8, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000023>
futex(0x6245378, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000024>
openat(AT_FDCWD, "/proc/version_signature", O_RDONLY|O_CLOEXEC) = 4 <0.000036>
read(4, "Ubuntu 6.8.0-64.67-generic 6.8.1"..., 255) = 34 <0.000030>
close(4)                                = 0 <0.000022>
write(5, "*", 1)                        = 1 <0.000023>
futex(0x6244a78, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000020>
futex(0x402e4e30, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANYstrace: Process 28 attached
 <unfinished ...>
[pid    28] futex(0x402e4e30, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000026>
[pid    27] <... futex resumed>)        = 0 <0.000993>
[pid    28] epoll_ctl(9, EPOLL_CTL_ADD, 10, {events=EPOLLIN, data={u32=10, u64=10}}) = 0 <0.000038>
[pid    28] epoll_ctl(9, EPOLL_CTL_ADD, 12, {events=EPOLLIN, data={u32=12, u64=12}}) = 0 <0.000033>
[pid    28] epoll_pwait(9, strace: Process 29 attached
 <unfinished ...>
[pid    29] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULLstrace: Process 30 attached
strace: Process 31 attached
strace: Process 32 attached
 <unfinished ...>
[pid    27] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000009>
[pid    27] futex(0xffffeea5d398, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    29] <... futex resumed>)        = 0 <0.001037>
[pid    29] futex(0xffffeea5d398, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    27] <... futex resumed>)        = 0 <0.000229>
[pid    29] <... futex resumed>)        = 1 <0.000153>
[pid    27] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    29] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    27] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000149>
[pid    29] <... futex resumed>)        = 0 <0.000154>
[pid    27] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    31] futex(0xffffeea5d39c, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    30] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    29] futex(0x40254a98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    27] <... futex resumed>)        = 0 <0.000447>
[pid    31] <... futex resumed>)        = 0 <0.000456>
[pid    27] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    32] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    27] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000138>
[pid    31] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    27] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    32] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000364>
[pid    27] <... futex resumed>)        = 0 <0.000146>
[pid    31] <... futex resumed>)        = 1 <0.000364>
[pid    30] <... futex resumed>)        = 0 <0.001278>
[pid    27] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    32] futex(0xffffeea5d398, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    31] futex(0x40254a98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    32] <... futex resumed>)        = 0 <0.000182>
[pid    30] futex(0xffffeea5d340, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    32] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    30] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000153>
[pid    27] <... futex resumed>)        = 0 <0.000885>
[pid    32] <... futex resumed>)        = 1 <0.000246>
[pid    27] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    30] futex(0xffffeea5d340, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    27] <... futex resumed>)        = 0 <0.000146>
[pid    32] futex(0x40254a98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    30] <... futex resumed>)        = 0 <0.000259>
[pid    27] futex(0xe64893ad37f8, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    30] futex(0x40254a98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    27] <... futex resumed>)        = 0 <0.000133>
[pid    27] openat(AT_FDCWD, "/proc/self/maps", O_RDONLY|O_CLOEXEC) = 17 <0.000039>
[pid    27] read(17, "00400000-061d9000 r-xp 00000000 "..., 1024) = 1024 <0.000008>
[pid    27] read(17, "1c20000-e64892420000 rw-p 000000"..., 1024) = 1024 <0.000043>
[pid    27] read(17, "64893750000 r--p 0000f000 00:2c "..., 1024) = 1024 <0.000008>
[pid    27] read(17, "41000 rw-p 00090000 00:2c 679652"..., 1024) = 1024 <0.000008>
[pid    27] read(17, " /usr/lib/aarch64-linux-gnu/libd"..., 1024) = 744 <0.000007>
[pid    27] close(17)                   = 0 <0.000010>
[pid    27] openat(AT_FDCWD, "/proc/self/cgroup", O_RDONLY|O_CLOEXEC) = 17 <0.000015>
[pid    27] read(17, "0::/\n", 1023)    = 5 <0.000006>
[pid    27] close(17)                   = 0 <0.000004>
[pid    27] openat(AT_FDCWD, "/sys/fs/cgroup//memory.max", O_RDONLY|O_CLOEXEC) = 17 <0.000104>
[pid    27] read(17, "max\n", 31)       = 4 <0.000010>
[pid    27] close(17)                   = 0 <0.000005>
[pid    27] openat(AT_FDCWD, "/sys/fs/cgroup//memory.high", O_RDONLY|O_CLOEXEC) = 17 <0.000009>
[pid    27] read(17, "max\n", 31)       = 4 <0.000004>
[pid    27] close(17)                   = 0 <0.000004>
[pid    27] openat(AT_FDCWD, "/proc/meminfo", O_RDONLY|O_CLOEXEC) = 17 <0.000011>
[pid    27] read(17, "MemTotal:        2006412 kB\nMemF"..., 4095) = 1504 <0.000028>
[pid    27] close(17)                   = 0 <0.000004>
[pid    27] futex(0x6244b20, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000004>
[pid    27] futex(0x6244b48, FUTEX_WAKE_PRIVATE, 2147483647strace: Process 33 attached
) = 0 <0.000211>
[pid    27] futex(0x6245388, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000004>
[pid    27] futex(0x6244c44, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000052>
[pid    27] futex(0x624538c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000007>
[pid    27] futex(0x6245390, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000007>
[pid    27] futex(0x6235b48, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000009>
[pid    33] futex(0x62357d0, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    27] futex(0x40254a98, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000005>
[pid    29] <... futex resumed>)        = 0 <0.023875>
[pid    29] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1) = 0 <0.000004>
[pid    29] futex(0x40254a9c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    27] openat(AT_FDCWD, "/workspace/node/async/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000057>
[pid    27] openat(AT_FDCWD, "/workspace/node/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000094>
[pid    27] openat(AT_FDCWD, "/workspace/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000137>
[pid    27] futex(0x40254a98, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000010>
[pid    31] <... futex resumed>)        = 0 <0.027964>
[pid    31] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1) = 0 <0.000056>
[pid    27] openat(AT_FDCWD, "/workspace/node/async/file-read-sync.js", O_RDONLY|O_CLOEXEC <unfinished ...>
[pid    31] futex(0x40254a9c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    27] <... openat resumed>)       = 17 <0.000765>
[pid    27] read(17, "const fs = require(\"fs\");\nconst "..., 8192) = 100 <0.000404>
[pid    27] read(17, "", 8192)          = 0 <0.000025>
[pid    27] close(17)                   = 0 <0.000298>
[pid    27] openat(AT_FDCWD, "/etc/hostname", O_RDONLY|O_CLOEXEC) = 17 <0.000029>
[pid    27] read(17, "82d03664b7c1\n", 8192) = 13 <0.000005>
[pid    27] read(17, "", 8192)          = 0 <0.000013>
[pid    27] close(17)                   = 0 <0.000004>
[pid    27] write(1, "82d03664b7c1\n\n", 14) = 14 <0.000004>
[pid    27] epoll_ctl(13, EPOLL_CTL_ADD, 14, {events=EPOLLIN, data={u32=14, u64=14}}) = 0 <0.000055>
[pid    27] epoll_ctl(13, EPOLL_CTL_ADD, 16, {events=EPOLLIN, data={u32=16, u64=16}}) = 0 <0.000005>
[pid    27] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0 <0.000004>
[pid    27] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0 <0.000051>
[pid    27] futex(0x40254a98, FUTEX_WAKE_PRIVATE, 2147483647) = 2 <0.000007>
[pid    32] <... futex resumed>)        = 0 <0.037493>
[pid    30] <... futex resumed>)        = 0 <0.037386>
[pid    27] futex(0x40254a80, FUTEX_WAIT_PRIVATE, 5, NULL <unfinished ...>
[pid    32] futex(0x40254a40, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    27] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000236>
[pid    30] futex(0x40254a80, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    27] futex(0x40254a9c, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    30] <... futex resumed>)        = 0 <0.000126>
[pid    27] <... futex resumed>)        = 2 <0.000756>
[pid    31] <... futex resumed>)        = 0 <0.011247>
[pid    29] <... futex resumed>)        = 0 <0.016930>
[pid    27] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    31] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    30] futex(0x40254a40, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    27] <... futex resumed>)        = 1 <0.000750>
[pid    32] <... futex resumed>)        = 0 <0.003826>
[pid    31] <... futex resumed>)        = 0 <0.001151>
[pid    29] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    27] write(12, "\1\0\0\0\0\0\0\0", 8 <unfinished ...>
[pid    32] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    30] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.002104>
[pid    27] <... write resumed>)        = 8 <0.000767>
[pid    32] <... futex resumed>)        = 0 <0.000427>
[pid    29] <... futex resumed>)        = 0 <0.001657>
[pid    28] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=12, u64=12}}], 1024, -1, NULL, 8) = 1 <0.050158>
[pid    27] futex(0xe6489343f0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 28, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    30] futex(0x40254a40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    28] read(12,  <unfinished ...>
[pid    30] <... futex resumed>)        = 0 <0.000343>
[pid    28] <... read resumed>"\1\0\0\0\0\0\0\0", 1024) = 8 <0.000321>
[pid    31] +++ exited with 0 +++
[pid    28] close(10 <unfinished ...>
[pid    32] +++ exited with 0 +++
[pid    28] <... close resumed>)        = 0 <0.000232>
[pid    29] +++ exited with 0 +++
[pid    28] close(11)                   = 0 <0.000056>
[pid    30] +++ exited with 0 +++
[pid    28] close(12)                   = 0 <0.000056>
[pid    28] close(9)                    = 0 <0.000048>
[pid    27] <... futex resumed>)        = 0 <0.004293>
[pid    28] +++ exited with 0 +++
[pid    27] epoll_ctl(3, EPOLL_CTL_ADD, 6, {events=EPOLLIN, data={u32=6, u64=6}}) = 0 <0.000116>
[pid    27] epoll_ctl(3, EPOLL_CTL_ADD, 8, {events=EPOLLIN, data={u32=8, u64=8}}) = 0 <0.000072>
[pid    27] epoll_pwait(3, [], 1024, 0, NULL, 8) = 0 <0.000057>
[pid    27] close(6)                    = 0 <0.000025>
[pid    27] close(7)                    = 0 <0.000179>
[pid    27] close(8)                    = 0 <0.000029>
[pid    27] close(3)                    = 0 <0.000137>
[pid    27] futex(0x6244bdc, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000118>
[pid    27] close(4)                    = 0 <0.000028>
[pid    27] close(5)                    = 0 <0.000067>
[pid    33] <... futex resumed>)        = ?
[pid    33] +++ exited with 0 +++
+++ exited with 0 +++
```

:::

### 非同期処理を strace で確認

続いては本題である、非同期のコードを見てみます。
同期のコードと同様に、strace に trace オプションをつけて確認してみます。

```bash
 $ strace -f -T -e trace=openat,read,write,close,futex,epoll_ctl,epoll_pwait node node/async/file-read-async.js > /dev/null
```

非同期の場合は、登場人物が増えます。

```bash
pid 13 = メインスレッド（イベントループ）
pid 21 = ワーカースレッド A
pid 20 = ワーカースレッド B
pid 22 = ワーカースレッド C
pid 23 = ワーカースレッド D
fd=16  = eventfd（ワーカー → メインへの完了通知用、8バイト固定の uint64 を読み書き）
fd=17  = /etc/hostname のファイルディスクリプタ
```

こちらも、出力の中から注目したい部分を抜き取って、読んでいきます。

1. **eventfd を epoll の監視リストに登録**

ファイル操作を始める前に、メインスレッドが通知用の　eventfd(fd=16) を epoll に登録しています。
この準備をしておくことで、ワーカーが完了通知を書き込んだときに、メインスレッドが起きられるようになります。

```bash
[pid 13] epoll_ctl(13, EPOLL_CTL_ADD, 14, {events=EPOLLIN})  # fd=14 を監視リストに登録
[pid 13] epoll_ctl(13, EPOLL_CTL_ADD, 16, {events=EPOLLIN})  # fd=16 を監視リストに登録
```

※ eventfd はイベント通知用のファイルディスクリプターを生成するもの

2. **ワーカーA がファイルを開く**

メインスレッドではなく、ワーカーA が `/etc/hostname` を開いています。
開いた後に、メインスレッドに「開いたよ」と通知するために、fd=16 に書き込んでいます。

```bash
[pid 21] openat("/etc/hostname", O_RDONLY|O_CLOEXEC) = 17     # ワーカーA: ファイルを開いた（fd=17）
[pid 21] write(16, "\1\0\0\0\0\0\0\0", 8) = 8                # ワーカーA: fd=16 に「開いたよ」と通知
```

3. **メインが通知を受け取って起きる**

メインスレッドは、`epoll_pwait` でブロックしていましたが、ワーカーA が fd=16 に書き込みを検知して起きました。
次に通知を`read` で読み取った後、次のワーカーを起こすために `futex` を呼び出しています。

```bash
[pid 13] epoll_pwait(13, [{fd=16}], 1024, -1) = 1            # メイン: fd=16 にデータ来た！起きた
[pid 13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8              # メイン: 通知を読み取った
[pid 13] futex(FUTEX_WAKE, 1) = 1                             # メイン: 次のワーカーを起こす
```

4. **ワーカーB が完了通知（ファイル I/O の syscall は発行していない）**

ワーカーBは、ファイルI/Oのシステムコールは発行していませんが、fd=16 に完了通知を書き込んでいます。

```bash
[pid 20] write(16, "\1\0\0\0\0\0\0\0", 8) = 8                # ワーカーB: fd=16 に通知
```

5. **メインが起きて、次のワーカーを起こす**

ステップ3と同様に、メインスレッドは、ワーカーB からの通知を検知して起きました。
そして、次のワーカーを起こすために `futex` を呼び出しています。

```bash
[pid 13] epoll_pwait(13, [{fd=16}], 1024, -1) = 1            # メイン: 起きた
[pid 13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8              # メイン: 通知を読み取った
[pid 13] futex(FUTEX_WAKE, 1) = 1                             # メイン: 次のワーカーを起こす
```

6. **ワーカーC がファイルの中身を読む**

ここが本命の部分です。ワーカーC が fd=17 からホスト名を読み取ります。
読み取り完了後は、fd=16 に「読んだよ」と通知しています。

```bash
[pid 22] read(17, "82d03664b7c1\n", 13) = 13                 # ワーカーC: fd=17 からホスト名を読んだ！
[pid 22] write(16, "\1\0\0\0\0\0\0\0", 8) = 8                # ワーカーC: fd=16 に「読んだよ」と通知
```

7. **メインが起きて、次のワーカーを起こす**

ここもステップ3と同様に、メインスレッドは、ワーカーC からの通知を検知して起きました。
そして、次のワーカーを起こすために `futex` を呼び出しています。

```bash
[pid 13] epoll_pwait(13, [{fd=16}], 1024, -1) = 1            # メイン: 起きた
[pid 13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8              # メイン: 通知を読み取った
[pid 13] futex(FUTEX_WAKE, 1) = 1                             # メイン: 次のワーカーを起こす
```

8. **ワーカーD がファイルを閉じる**

ファイルの読み取りは完了したので、ステップ2で開いた fd=17 を閉じます。
open → read → close の一連の流れが完了したことを、fd=16 に「閉じたよ」と通知しています。

```bash
[pid 23] close(17) = 0                                        # ワーカーD: fd=17 を閉じた
[pid 23] write(16, "\1\0\0\0\0\0\0\0", 8) = 8                # ワーカーD: fd=16 に「閉じたよ」と通知
```

9. **メインが起きて、コールバック（console.log）を実行**

全ステップが完了したので、ようやくメインスレッドがコールバックを実行します。
write(1, ...) は fd=1 (stdout) への書き込みなので、ここで console.log() が実行されていることがわかります。

```bash
[pid 13] epoll_pwait(13, [{fd=16}], 1024, -1) = 1            # メイン: 起きた
[pid 13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8              # メイン: 通知を読み取った
[pid 13] write(1, "82d03664b7c1\n\n", 14) = 14               # ★ メイン: console.log() = stdout に出力！
```

**非同期のまとめ**

メインスレッドはファイル操作を行わず、ワーカーからの完了通知を `epoll_pwait` で待ち、通知が来たら次のワーカーを起こす、という繰り返しを行なっています。
そして、すべてのステップ (open　→ read → close) が完了して初めて、コールバック(console.log) を実行していることがわかりました。
一方でワーカーは、実際のファイル操作(open / read / close)を担当し、完了したらメインスレッドに通知する、という役割を担っています。
これで、Node.js の非同期処理の流れを、システムコールレベルで追うことができました。

:::details 全てのシステムコール

````
...あとで入れる
```bash
openat(AT_FDCWD, "/etc/ld.so.cache", O_RDONLY|O_CLOEXEC) = 3 <0.000044>
close(3)                                = 0 <0.000030>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libdl.so.2", O_RDONLY|O_CLOEXEC) = 3 <0.000120>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000065>
close(3)                                = 0 <0.000072>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libstdc++.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000222>
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000077>
close(3)                                = 0 <0.000029>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libm.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000223>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000261>
close(3)                                = 0 <0.000063>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libgcc_s.so.1", O_RDONLY|O_CLOEXEC) = 3 <0.000087>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000079>
close(3)                                = 0 <0.000051>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libpthread.so.0", O_RDONLY|O_CLOEXEC) = 3 <0.000126>
read(3, "\177ELF\2\1\1\0\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\0\0\0\0\0\0\0\0"..., 832) = 832 <0.000100>
close(3)                                = 0 <0.000062>
openat(AT_FDCWD, "/lib/aarch64-linux-gnu/libc.so.6", O_RDONLY|O_CLOEXEC) = 3 <0.000113>
read(3, "\177ELF\2\1\1\3\0\0\0\0\0\0\0\0\3\0\267\0\1\0\0\0\360\206\2\0\0\0\0\0"..., 832) = 832 <0.000030>
close(3)                                = 0 <0.000075>
futex(0xe196c6d837ec, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000026>
futex(0x6244a80, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000103>
futex(0x6245360, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000063>
futex(0x6245364, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000026>
futex(0x6245368, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000081>
futex(0x6245468, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000060>
futex(0x6245374, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000030>
futex(0x624d7f8, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000026>
futex(0x6245058, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000035>
futex(0x6244e40, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000036>
futex(0x62453a4, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000082>
futex(0x6244d30, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000021>
futex(0x624536c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000129>
openat(AT_FDCWD, "/etc/ssl/openssl.cnf", O_RDONLY) = 3 <0.000337>
read(3, "#\n# OpenSSL example configuratio"..., 4096) = 4096 <0.000058>
read(3, "d attributes must be the same, a"..., 4096) = 4096 <0.000066>
read(3, "coding of an extension: beware e"..., 4096) = 4096 <0.000056>
read(3, " = $insta::certout # insta.cert."..., 4096) = 36 <0.000033>
read(3, "", 4096)                       = 0 <0.000039>
close(3)                                = 0 <0.000076>
futex(0x624537c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000022>
futex(0x62454c8, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000063>
futex(0x6245378, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000072>
openat(AT_FDCWD, "/proc/version_signature", O_RDONLY|O_CLOEXEC) = 4 <0.000166>
read(4, "Ubuntu 6.8.0-64.67-generic 6.8.1"..., 255) = 34 <0.000048>
close(4)                                = 0 <0.000027>
write(5, "*", 1)                        = 1 <0.000089>
futex(0x6244a78, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000041>
strace: Process 14 attached
[pid    13] futex(0x38eabe30, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    14] futex(0x38eabe30, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000071>
[pid    13] <... futex resumed>)        = 0 <0.002507>
[pid    14] epoll_ctl(9, EPOLL_CTL_ADD, 10, {events=EPOLLIN, data={u32=10, u64=10}}) = 0 <0.000124>
strace: Process 15 attached
[pid    14] epoll_ctl(9, EPOLL_CTL_ADD, 12, {events=EPOLLIN, data={u32=12, u64=12}}) = 0 <0.000138>
[pid    14] epoll_pwait(9,  <unfinished ...>
[pid    15] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULLstrace: Process 16 attached
 <unfinished ...>
[pid    16] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULLstrace: Process 17 attached
 <unfinished ...>
[pid    17] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULLstrace: Process 18 attached
 <unfinished ...>
[pid    18] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    13] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000020>
[pid    15] <... futex resumed>)        = 0 <0.003808>
[pid    13] futex(0xfffffa0185d8, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    15] futex(0xfffffa0185d8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000315>
[pid    15] <... futex resumed>)        = 0 <0.000413>
[pid    13] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    15] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000377>
[pid    16] <... futex resumed>)        = 0 <0.005508>
[pid    15] <... futex resumed>)        = 1 <0.000602>
[pid    13] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    16] futex(0xfffffa0185dc, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... futex resumed>)        = 1 <0.000302>
[pid    17] <... futex resumed>)        = 0 <0.005277>
[pid    15] futex(0x38e1ba98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    17] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    16] <... futex resumed>)        = 0 <0.001581>
[pid    16] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000019>
[pid    18] <... futex resumed>)        = 0 <0.006429>
[pid    16] futex(0x38e1ba98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    18] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000020>
[pid    13] <... futex resumed>)        = 0 <0.002157>
[pid    18] futex(0x38e1ba98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000240>
[pid    17] <... futex resumed>)        = 0 <0.002545>
[pid    13] futex(0xfffffa0185d8, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    17] futex(0xfffffa0185d8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000319>
[pid    17] <... futex resumed>)        = 0 <0.000383>
[pid    13] futex(0xfffffa018580, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    17] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.002165>
[pid    17] <... futex resumed>)        = 0 <0.000213>
[pid    13] futex(0xfffffa018580, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    17] futex(0x38e1ba98, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] <... futex resumed>)        = 0 <0.000536>
[pid    13] futex(0xe196c6d837f8, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000004>
[pid    13] openat(AT_FDCWD, "/proc/self/maps", O_RDONLY|O_CLOEXEC) = 17 <0.001179>
[pid    13] read(17, "00400000-061d9000 r-xp 00000000 "..., 1024) = 1024 <0.000018>
[pid    13] read(17, "4ed0000-e196c56d0000 rw-p 000000"..., 1024) = 1024 <0.000010>
[pid    13] read(17, "196c6a00000 r--p 0000f000 00:2c "..., 1024) = 1024 <0.000015>
[pid    13] read(17, "f1000 rw-p 00090000 00:2c 679652"..., 1024) = 1024 <0.000017>
[pid    13] read(17, " /usr/lib/aarch64-linux-gnu/libd"..., 1024) = 744 <0.000049>
[pid    13] close(17)                   = 0 <0.000022>
[pid    13] openat(AT_FDCWD, "/proc/self/cgroup", O_RDONLY|O_CLOEXEC) = 17 <0.000017>
[pid    13] read(17, "0::/\n", 1023)    = 5 <0.000006>
[pid    13] close(17)                   = 0 <0.000007>
[pid    13] openat(AT_FDCWD, "/sys/fs/cgroup//memory.max", O_RDONLY|O_CLOEXEC) = 17 <0.000040>
[pid    13] read(17, "max\n", 31)       = 4 <0.000009>
[pid    13] close(17)                   = 0 <0.000064>
[pid    13] openat(AT_FDCWD, "/sys/fs/cgroup//memory.high", O_RDONLY|O_CLOEXEC) = 17 <0.000064>
[pid    13] read(17, "max\n", 31)       = 4 <0.000006>
[pid    13] close(17)                   = 0 <0.000006>
[pid    13] openat(AT_FDCWD, "/proc/meminfo", O_RDONLY|O_CLOEXEC) = 17 <0.000012>
[pid    13] read(17, "MemTotal:        2006412 kB\nMemF"..., 4095) = 1504 <0.000025>
[pid    13] close(17)                   = 0 <0.000031>
[pid    13] futex(0x6244b20, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000018>
strace: Process 19 attached
[pid    13] futex(0x6244b48, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    19] futex(0x62357d0, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] <... futex resumed>)        = 0 <0.000414>
[pid    13] futex(0x6245388, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000055>
[pid    13] futex(0x6244c44, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000041>
[pid    13] futex(0x624538c, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000051>
[pid    13] futex(0x6245390, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000087>
[pid    13] futex(0x6235b48, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000072>
[pid    13] futex(0x38e1ba98, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000023>
[pid    15] <... futex resumed>)        = 0 <0.044670>
[pid    15] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1) = 0 <0.000051>
[pid    13] openat(AT_FDCWD, "/workspace/node/async/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000044>
[pid    13] openat(AT_FDCWD, "/workspace/node/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000025>
[pid    13] openat(AT_FDCWD, "/workspace/package.json", O_RDONLY|O_CLOEXEC) = -1 ENOENT (No such file or directory) <0.000191>
[pid    13] openat(AT_FDCWD, "/workspace/node/async/file-read-async.js", O_RDONLY|O_CLOEXEC <unfinished ...>
[pid    15] futex(0x38e1ba9c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] <... openat resumed>)       = 17 <0.000387>
[pid    13] read(17, "const fs = require(\"fs\");\nfs.rea"..., 8192) = 105 <0.000224>
[pid    13] read(17, "", 8192)          = 0 <0.000022>
[pid    13] close(17)                   = 0 <0.000085>
strace: Process 20 attached
strace: Process 21 attached
strace: Process 22 attached
[pid    21] futex(0x6244658, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    20] futex(0x6244658, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    22] futex(0x6244658, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANYstrace: Process 23 attached
 <unfinished ...>
[pid    23] futex(0x6244658, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] futex(0x62445f0, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000069>
[pid    13] futex(0x6244658, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000057>
[pid    21] <... futex resumed>)        = 0 <0.002252>
[pid    13] epoll_ctl(13, EPOLL_CTL_ADD, 14, {events=EPOLLIN, data={u32=14, u64=14}} <unfinished ...>
[pid    21] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... epoll_ctl resumed>)    = 0 <0.000249>
[pid    21] <... futex resumed>)        = 0 <0.000272>
[pid    13] epoll_ctl(13, EPOLL_CTL_ADD, 16, {events=EPOLLIN, data={u32=16, u64=16}} <unfinished ...>
[pid    21] openat(AT_FDCWD, "/etc/hostname", O_RDONLY|O_CLOEXEC <unfinished ...>
[pid    13] <... epoll_ctl resumed>)    = 0 <0.000274>
[pid    21] <... openat resumed>)       = 17 <0.000355>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    21] write(16, "\1\0\0\0\0\0\0\0", 8 <unfinished ...>
[pid    13] <... epoll_pwait resumed>[], 1024, 0, NULL, 8) = 0 <0.000342>
[pid    21] <... write resumed>)        = 8 <0.000456>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    21] futex(0x624465c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=16, u64=16}}], 1024, -1, NULL, 8) = 1 <0.000406>
[pid    13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8 <0.000036>
[pid    13] futex(0x6244658, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000029>
[pid    20] <... futex resumed>)        = 0 <0.006762>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    20] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] <... epoll_pwait resumed>[], 1024, 0, NULL, 8) = 0 <0.000234>
[pid    20] <... futex resumed>)        = 0 <0.000558>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    20] write(16, "\1\0\0\0\0\0\0\0", 8) = 8 <0.000007>
[pid    13] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=16, u64=16}}], 1024, -1, NULL, 8) = 1 <0.000415>
[pid    20] futex(0x624465c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8 <0.000026>
[pid    13] futex(0x6244658, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000029>
[pid    22] <... futex resumed>)        = 0 <0.009795>
[pid    22] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    22] <... futex resumed>)        = 0 <0.000103>
[pid    13] <... epoll_pwait resumed>[], 1024, 0, NULL, 8) = 0 <0.000116>
[pid    22] read(17,  <unfinished ...>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    22] <... read resumed>"82d03664b7c1\n", 13) = 13 <0.000207>
[pid    22] write(16, "\1\0\0\0\0\0\0\0", 8) = 8 <0.000006>
[pid    13] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=16, u64=16}}], 1024, -1, NULL, 8) = 1 <0.000201>
[pid    22] futex(0x624465c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8 <0.000066>
[pid    13] futex(0x6244658, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000029>
[pid    23] <... futex resumed>)        = 0 <0.012066>
[pid    23] futex(0x62445f8, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    13] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    23] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000461>
[pid    13] <... futex resumed>)        = 0 <0.000448>
[pid    23] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    23] <... futex resumed>)        = 0 <0.000166>
[pid    13] <... epoll_pwait resumed>[], 1024, 0, NULL, 8) = 0 <0.000296>
[pid    23] close(17 <unfinished ...>
[pid    13] epoll_pwait(13,  <unfinished ...>
[pid    23] <... close resumed>)        = 0 <0.000253>
[pid    23] write(16, "\1\0\0\0\0\0\0\0", 8) = 8 <0.000008>
[pid    13] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=16, u64=16}}], 1024, -1, NULL, 8) = 1 <0.000479>
[pid    23] futex(0x624465c, FUTEX_WAIT_BITSET_PRIVATE|FUTEX_CLOCK_REALTIME, 0, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    13] read(16, "\1\0\0\0\0\0\0\0", 1024) = 8 <0.000026>
[pid    13] write(1, "82d03664b7c1\n\n", 14) = 14 <0.000030>
[pid    13] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0 <0.000176>
[pid    13] epoll_pwait(13, [], 1024, 0, NULL, 8) = 0 <0.000033>
[pid    13] futex(0x38e1ba98, FUTEX_WAKE_PRIVATE, 2147483647) = 3 <0.000137>
[pid    18] <... futex resumed>)        = 0 <0.083253>
[pid    17] <... futex resumed>)        = 0 <0.078581>
[pid    16] <... futex resumed>)        = 0 <0.084926>
[pid    13] futex(0x38e1ba80, FUTEX_WAIT_PRIVATE, 7, NULL <unfinished ...>
[pid    18] futex(0x38e1ba40, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    17] futex(0x38e1ba40, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000619>
[pid    16] futex(0x38e1ba80, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    13] futex(0x38e1ba9c, FUTEX_WAKE_PRIVATE, 2147483647 <unfinished ...>
[pid    16] <... futex resumed>)        = 0 <0.000569>
[pid    13] <... futex resumed>)        = 1 <0.000263>
[pid    15] <... futex resumed>)        = 0 <0.039648>
[pid    13] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    16] futex(0x38e1ba40, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    13] <... futex resumed>)        = 1 <0.000299>
[pid    18] <... futex resumed>)        = 0 <0.002784>
[pid    15] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    13] write(12, "\1\0\0\0\0\0\0\0", 8 <unfinished ...>
[pid    18] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    16] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.001761>
[pid    13] <... write resumed>)        = 8 <0.000669>
[pid    18] <... futex resumed>)        = 0 <0.000365>
[pid    17] <... futex resumed>)        = 0 <0.004142>
[pid    15] <... futex resumed>)        = 1 <0.001382>
[pid    14] <... epoll_pwait resumed>[{events=EPOLLIN, data={u32=12, u64=12}}], 1024, -1, NULL, 8) = 1 <0.100373>
[pid    13] futex(0xe196c66ef0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 14, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    17] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    16] futex(0x38e1ba40, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    14] read(12, "\1\0\0\0\0\0\0\0", 1024) = 8 <0.000004>
[pid    14] close(10)                   = 0 <0.000008>
[pid    14] close(11)                   = 0 <0.000009>
[pid    14] close(12)                   = 0 <0.000004>
[pid    14] close(9)                    = 0 <0.000003>
[pid    14] +++ exited with 0 +++
[pid    13] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.001379>
[pid    17] <... futex resumed>)        = 0 <0.001444>
[pid    16] <... futex resumed>)        = 0 <0.001695>
[pid    13] futex(0xe196c5edf0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 15, NULL, FUTEX_BITSET_MATCH_ANY) = 0 <0.000314>
[pid    15] +++ exited with 0 +++
[pid    13] futex(0xe196c56cf0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 16, NULL, FUTEX_BITSET_MATCH_ANY) = 0 <0.000241>
[pid    17] +++ exited with 0 +++
[pid    16] +++ exited with 0 +++
[pid    13] futex(0xe196bffff0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 18, NULL, FUTEX_BITSET_MATCH_ANY) = 0 <0.000557>
[pid    18] +++ exited with 0 +++
[pid    13] epoll_ctl(3, EPOLL_CTL_ADD, 6, {events=EPOLLIN, data={u32=6, u64=6}}) = 0 <0.000080>
[pid    13] epoll_ctl(3, EPOLL_CTL_ADD, 8, {events=EPOLLIN, data={u32=8, u64=8}}) = 0 <0.000094>
[pid    13] epoll_pwait(3, [], 1024, 0, NULL, 8) = 0 <0.000064>
[pid    13] close(6)                    = 0 <0.000030>
[pid    13] close(7)                    = 0 <0.000087>
[pid    13] close(8)                    = 0 <0.000077>
[pid    13] close(3)                    = 0 <0.000114>
[pid    13] futex(0x6244bdc, FUTEX_WAKE_PRIVATE, 2147483647) = 0 <0.000059>
[pid    13] close(4)                    = 0 <0.000057>
[pid    13] close(5)                    = 0 <0.000036>
[pid    13] futex(0x624465c, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000085>
[pid    21] <... futex resumed>)        = 0 <0.046793>
[pid    13] futex(0xe196977ef0f0, FUTEX_WAIT_BITSET|FUTEX_CLOCK_REALTIME, 20, NULL, FUTEX_BITSET_MATCH_ANY <unfinished ...>
[pid    21] futex(0x624465c, FUTEX_WAKE_PRIVATE, 1) = 1 <0.000088>
[pid    20] <... futex resumed>)        = 0 <0.044538>
[pid    21] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    20] futex(0x624465c, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    21] <... futex resumed>)        = 0 <0.000245>
[pid    22] <... futex resumed>)        = 0 <0.042598>
[pid    20] <... futex resumed>)        = 1 <0.000447>
[pid    22] futex(0x62445f8, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    20] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    22] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000336>
[pid    20] <... futex resumed>)        = 0 <0.000320>
[pid    22] futex(0x624465c, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    23] <... futex resumed>)        = 0 <0.039397>
[pid    22] <... futex resumed>)        = 1 <0.000383>
[pid    23] futex(0x62445f8, FUTEX_WAIT_PRIVATE, 2, NULL <unfinished ...>
[pid    22] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    23] <... futex resumed>)        = -1 EAGAIN (Resource temporarily unavailable) <0.000306>
[pid    22] <... futex resumed>)        = 0 <0.000469>
[pid    23] futex(0x62445f8, FUTEX_WAKE_PRIVATE, 1 <unfinished ...>
[pid    21] +++ exited with 0 +++
[pid    23] <... futex resumed>)        = 0 <0.000132>
[pid    13] <... futex resumed>)        = 0 <0.005061>
[pid    20] +++ exited with 0 +++
[pid    22] +++ exited with 0 +++
[pid    23] +++ exited with 0 +++
[pid    19] <... futex resumed>)        = ?
[pid    19] +++ exited with 0 +++
+++ exited with 0 +++
````

:::

## まとめ

システムコールの話までくるとかなり深い話になってしまいましたが、システムコールレベルで追ってみたことで、普段何気なく書いている非同期処理の裏側が見えてきました。
実際にファイル操作を行っているのはメインスレッドではなく、ワーカーたちがせっせと役割分担をしながら働いていて、なんだか可愛く見えてきた気がします。
最近は AI、AI と話題が尽きない世の中ですが、たまには仕組みを学ぶ好奇心に身を任せて、技術の裏側を覗いてみるのも楽しいのではないでしょうか。

## 参考

https://zenn.dev/mmomm/articles/ff83eb49a7b642

https://nodejs.org/en/learn/asynchronous-work/event-loop-timers-and-nexttick

https://zenn.dev/dozo13189/articles/78e26ea96c5ae4

```

```
