---
title: "straceでSSHコマンドの内部を覗いてみた"
emoji: "🔍"
type: "tech"
topics: ["ssh", "strace", "linux", "syscall"]
published: false
---

こんにちは 人材育成室 育成メンバーチームで 研修中の はすと です。

以前、mitmproxyを使ってClaude Codeがどんな通信をしているのかネットワークの外側から覗いてみたことがありました。その後もSSHで毎日のようにサーバーへ接続しているのですが、`ssh user@server` と打ったその瞬間、Linuxカーネルへ何をお願いしているのかは考えたことがありませんでした。前回はネットワークの外側から通信を覗きましたが、今回はもう一段階下のレイヤー、アプリケーションとLinuxカーネルの境界をstraceで覗いてみることにしました。

本記事では、`strace -f ssh user@server` を実際に実行し、sshコマンドがどんなシステムコールを発行しているかを、実際に取得したログを見ながら追っていきます。

## straceとは

以下のような流れになります。

```
Terminal
   │
  ssh
   │
System Call
   │
Linux Kernel
   │
  NIC
   │
Server
```

straceは、アプリケーションとLinuxカーネルの境界で発生するシステムコールを観測するツールです。今回はSSHの仕組みそのものではなく、「sshコマンドがLinuxに何を依頼しているか」だけに焦点を当てます。

## 検証環境を用意する

macOSにはstraceが存在しないので(Linux専用のツールで、macOSは`dtruss`/`dtrace`という別系統になります)、Linux環境が必要です。手元では[colima](https://github.com/abiquo/colima)でDockerがすでに動いていたので、使い捨てのUbuntuコンテナを1つ立てて、その中でクライアントもサーバーも完結させることにしました。

同じ手順を試せるように、必要なものと動作確認したバージョンを挙げておきます。

- Dockerが動く環境(colima・Docker Desktop・OrbStackなど、`docker`コマンドが使えればランタイムは問いません)
- インターネット接続(`ubuntu:24.04`イメージの取得に使用)

| ソフトウェア | バージョン |
| --- | --- |
| ホストOS | macOS(Apple Silicon, aarch64) |
| colima | 0.10.3 |
| Docker | Client 29.6.1 / Server 29.5.2 |
| コンテナOS | Ubuntu 24.04.4 LTS |
| OpenSSH | 9.6p1(Ubuntu-3ubuntu13.18) |
| strace | 6.8 |

:::details DockerのClient/Server、sshのバージョン表記の内訳が気になった方へ

`docker version`の出力を見ると、ClientとServerでバージョンが違っています(29.6.1 / 29.5.2)。Dockerは公式にクライアント・サーバー型のアーキテクチャを採っているためです。

> Docker uses a client-server architecture. The Docker client talks to the Docker daemon, which does the heavy lifting of building, running, and distributing your Docker containers.
>
> The Docker client and daemon can run on the same system, or you can connect a Docker client to a remote Docker daemon. The Docker client and daemon communicate using a REST API, over UNIX sockets or a network interface.
>
> 出典: [Docker overview - Docker Docs](https://docs.docker.com/get-started/overview/)

手元の環境で実際に確認すると、Client(`/opt/homebrew/bin/docker`、HomebrewでインストールしたmacOS/arm64バイナリ)と、Server(colimaのLinux VM内で動くdaemon、`unix:///Users/hasutosasaki/.colima/default/docker.sock`経由で接続)は別々のバイナリでした。Homebrew管理のCLIとcolima VM内蔵のdaemonがそれぞれ独立して更新されるため、バージョンにずれが出ていました。

sshのバージョン文字列(`OpenSSH_9.6p1 Ubuntu-3ubuntu13.18, OpenSSL 3.0.13`)にも内訳があります。

- `OpenSSH_9.6` : OpenBSD側の本家バージョン
- `p1` : portable版(他OS向け移植版)のパッチレベル。本家とは別に振られる番号

> The "p" in versions like "10.4p1" indicates a patchlevel for the portable distribution. This allows bug fixes and security patches to be released between major version updates.
>
> 出典: [OpenSSH Release Notes](https://www.openssh.org/releasenotes.html)

- `Ubuntu-3ubuntu13.18` : Ubuntuが独自にバックポートしたセキュリティパッチのリビジョン番号
- `OpenSSL 3.0.13` : リンクしている暗号ライブラリのバージョン(sshとは別物)

ちなみにOpenSSHの最新は10.4(2026-07-06リリース)で、Ubuntu 24.04は9.6p1のままセキュリティパッチだけをバックポートする運用でした。バージョン番号だけ見ると古そうですが、LTSとしては想定通りの状態です。

:::

Ubuntu 24.04は2024年4月リリースのLTSで、サポートは2029年まで続くため、バージョンが古いことによる弊害は特にありません。

```bash
docker run -d --name ssh-strace-demo ubuntu:24.04 sleep infinity
```

コンテナの中に`openssh-server`・`openssh-client`・`strace`を入れ、検証専用のユーザー`sshdemo`を作成し、その場で使い捨てのed25519鍵を生成しました。普段使っている自分の鍵やアカウントは一切使っていません。

:::details openssh-serverとopenssh-clientの違い

パッケージの説明(`apt show`)を見ると役割がはっきり分かれています。

- `openssh-client`: secure shell (SSH) client, for secure access to **remote machines** — `ssh`/`scp`/`ssh-keygen`など、接続しに行く側のコマンド一式
- `openssh-server`: secure shell (SSH) server, for secure access **from remote machines** — 接続を受け付ける`sshd`デーモンと`/etc/ssh/sshd_config`

普段使うUbuntu/Macには`openssh-client`だけが入っていることが多く、`ssh`で外に繋ぎに行くことはできても、外から繋がれることはできません。今回は1つのコンテナにクライアント役とサーバー役を同居させる構成にしたため、両方インストールしています。

:::

```bash
docker exec ssh-strace-demo bash -c "
  apt-get update -qq
  apt-get install -y -qq openssh-server openssh-client strace sudo
  useradd -m -s /bin/bash sshdemo
"
docker exec ssh-strace-demo su - sshdemo -c "
  ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519 -C sshdemo-throwaway
  cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
"
```

サーバー役もクライアント役も同じコンテナに同居させて、`ssh sshdemo@localhost`で自分自身に接続する形にしています。これなら本物のリモートサーバーの情報を記事に出さずに済みますし、`connect`が失敗するパターンも自分の手元で自由に作れます。

なお、今回は`localhost`への接続なので、DNS解決(`getaddrinfo`がDNSサーバーに問い合わせる部分)は対象外です。この点は検証範囲から意図的に外しています。

普通に接続できることを確認しておきます。

実行結果です。

```
$ ssh sshdemo@localhost echo CONNECT_OK
CONNECT_OK
```

:::details ssh末尾に毎回コマンドを付けている理由

コマンドを指定しないと`ssh`は対話シェルを起動しようとして疑似端末(pty)の割り当てを試みますが、今回`docker exec`(`-it`無し)経由で実行しているため正規の端末が無く、そのままだと入力待ちで固まってしまいます。末尾にコマンドを1つ渡すと、`ssh`はそのコマンドをログインシェルの代わりに実行して結果を返すとすぐ終了するので、`execve`から`exit_group`まで有限の流れとしてstraceで追えるようになります。

この挙動は`ssh(1)`のマニュアルにも明記されています。

> If a command is specified, it will be executed on the remote host instead of a login shell.
>
> If an interactive session is requested, ssh by default will only request a pseudo-terminal (pty) for interactive sessions when the client has one. The flags -T and -t can be used to override this behaviour.
>
> 出典: [ssh(1) - OpenBSD manual pages](https://man.openbsd.org/ssh.1)

日本語にすると次のような内容です。

- コマンドが指定された場合、ログインシェルの代わりにそのコマンドがリモートホスト上で実行される
- 対話セッションが要求された場合(コマンド指定が無い場合)、クライアント側に端末があれば疑似端末(pty)をデフォルトで要求する。この挙動は`-T`/`-t`オプションで上書きできる

:::

ここからstraceで覗いていきます。

## プロセスが起動する瞬間を見る

```bash
strace -f -o full_trace.log ssh sshdemo@localhost echo SSH_STRACE_OK
```

実行結果の先頭です。

```
execve("/usr/bin/ssh", ["ssh", "sshdemo@localhost", "echo", "SSH_STRACE_OK"], 0xffffc4d33330 /* 10 vars */) = 0
```

`ssh`コマンドを打った瞬間に記録される最初の1行です。ここから先のすべての処理は、このプロセスが発行するシステムコールの連鎖として観測できます。

## 設定ファイルを読みに行く

`ssh`は接続を試みる前に、複数の設定ファイルを`openat`で開きに行きます。

```
openat(AT_FDCWD, "/home/sshdemo/.ssh/config", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/etc/ssh/ssh_config", O_RDONLY) = 3
openat(AT_FDCWD, "/etc/ssh/ssh_config.d/", O_RDONLY|O_NONBLOCK|O_DIRECTORY|O_CLOEXEC) = 3
```

`~/.ssh/config`が無い状態だと`ENOENT`(ファイルが無い)で返ってきます。実際に`~/.ssh/config`を作ってから同じコマンドを実行すると、結果が変わります。

```
openat(AT_FDCWD, "/home/sshdemo/.ssh/config", O_RDONLY) = 3
```

ファイルの有無だけで、`-1 ENOENT`か`= 3`(オープン成功時のファイルディスクリプタ)かがきれいに切り替わりました。

秘密鍵を探す部分にも気になる点がありました。`~/.ssh/id_ed25519`しか用意していないにもかかわらず、`openat`のログには次のようなファイルが次々と登場します。

```
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_rsa", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_dsa", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_ecdsa", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_ecdsa_sk", O_RDONLY) = -1 ENOENT (No such file or directory)
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_ed25519", O_RDONLY) = 3
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_xmss", O_RDONLY) = -1 ENOENT (No such file or directory)
```

`ssh`は「設定された1つの鍵」を読みに行くのではなく、対応している鍵形式(RSA/DSA/ECDSA/ECDSA-SK/Ed25519/Ed25519-SK/XMSS、それぞれの証明書版も含む)を総当たりで試し、存在したものだけを使っていました。存在しないファイルへの`ENOENT`は、エラーというより「候補を1つずつ潰していった記録」として読めます。

:::details 存在しない鍵ファイルを試すことにセキュリティリスクは無いか

`id_rsa`や`id_dsa`など、用意していない鍵まで`openat`されているのを見て気になったので調べてみました。

ログを見ると、鍵候補の`openat`(ENOENTのものも含め)は、SSHプロトコルのバナー交換(`write(3, "SSH-2.0-OpenSSH...")`)より**前**に、ソケットとは別のファイルディスクリプタで完了しています。つまり鍵探索は完全にローカルのファイルシステム操作で完結していて、サーバーには何も送られていません。ファイルが無ければ`ENOENT`が返るだけで、それ以上何も起きようがありませんでした。

`ssh_config(5)`のマニュアルにも、存在しない鍵ファイルに関するセキュリティ上の注記は見当たりません。デフォルトの鍵候補を順に試すのは、明示的に意図された標準の挙動です。

ただし隣接する、実在するリスクがあります。これは「無い鍵」ではなく「ある鍵」の話です。

> Specifies the maximum number of authentication attempts permitted per connection. Once the number of failures reaches half this value, additional failures are logged.
>
> 出典: [sshd_config(5) - OpenBSD manual pages](https://man.openbsd.org/sshd_config.5)

`MaxAuthTries`はデフォルト6回です。`ssh-agent`に鍵をたくさん登録していたり`IdentityFile`が複数実在したりすると、存在する鍵を次々オファーする過程でこの上限を消費してしまい、本来使いたい鍵やパスワード認証にたどり着く前に接続を拒否されることがあります。

なお、複数の鍵が実際に有効な場合の挙動も`ssh -v`で確認しました。RSA鍵とEd25519鍵の両方を`authorized_keys`に登録した状態で接続すると、次のように**優先順位順に1つずつオファーし、サーバーが受け入れた時点で即座に終了**します。2番目の鍵が試されることはありませんでした。

```
debug1: Offering public key: /home/sshdemo/.ssh/id_rsa RSA SHA256:ULeD...
debug1: Server accepts key: /home/sshdemo/.ssh/id_rsa RSA SHA256:ULeD...
```

:::

## ソケットを作り、接続を試みる

`socket`と`connect`のあたりを見ると、`connect`が3回も成功しているのに、実際のTCPソケット(`SOCK_STREAM`)は1つしか作られていませんでした。

実行結果です。

```
socket(AF_INET, SOCK_DGRAM|SOCK_CLOEXEC, IPPROTO_IP) = 3
connect(3, {sa_family=AF_INET, sin_port=htons(22), sin_addr=inet_addr("127.0.0.1")}, 16) = 0
getsockname(3, {sa_family=AF_INET, sin_port=htons(33292), sin_addr=inet_addr("127.0.0.1")}, [28 => 16]) = 0
close(3)                          = 0

socket(AF_INET6, SOCK_DGRAM|SOCK_CLOEXEC, IPPROTO_IP) = 3
connect(3, {sa_family=AF_INET6, sin6_port=htons(22), ... "::1" ...}, 28) = 0
getsockname(3, {sa_family=AF_INET6, sin6_port=htons(43626), ... "::1" ...}, [28]) = 0
close(3)                          = 0

socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP) = 3
connect(3, {sa_family=AF_INET6, sin6_port=htons(22), ... "::1" ...}, 28) = 0
```

`connect`と聞くと「サーバーへ接続すること」だと考えると思います。実際には、最初の2回は`SOCK_DGRAM`(UDPソケット)に対する`connect`で、これは本当のパケットを1つも送らずに「このIPへ出て行くとしたら自分はどのアドレスを使うか」をカーネルに教えてもらうためだけの呼び出しでした。`connect`した直後に`getsockname`で自分のアドレスを確認し、そのままソケットを閉じています。本当に接続を試みているのは、最後の`SOCK_STREAM`(TCP)に対する`connect`1回だけでした。

調べてみると、これはssh自身のロジックではなく、glibcの`getaddrinfo()`が`localhost`の複数アドレス(`127.0.0.1`と`::1`)をRFC 3484(Default Address Selection)に基づいて並び替えるための処理でした。並び替えの結果、実際にTCP接続を確立したのは`::1`(IPv6のループバック)側でした。

:::details なぜUDPソケットへのconnectだけで済むのか(glibcのソースコードで確認)

glibcの`getaddrinfo()`の実装(`nss/getaddrinfo.c`)に、まさにこの処理をしている`try_connect()`という関数がありました。各候補アドレスへUDPソケットで`connect`+`getsockname`を行い、本物のパケットを送らずに到達可能性と送信元アドレスだけを調べています。コード中にも理由がそのまま書かれていました。

```c
/* We overwrite the type with SOCK_DGRAM since we do not want
   connect() to connect to the other side. */
```

出典: [nss/getaddrinfo.c - glibc公式リポジトリ](https://sourceware.org/git/?p=glibc.git;a=blob;f=nss/getaddrinfo.c;hb=HEAD)(`git clone`して該当箇所を直接確認)

`try_connect()`の実装自体は`__connect()`と`__getsockname()`を呼んでいるだけで、アドレスの選択自体はカーネルの経路表(ルーティングテーブル)に委ねられています。UDPソケットに明示的なbind無しで`connect`すると、カーネルは「この宛先に出すならどのインターフェースのどのアドレスを使うか」を経路表から自動選択します(暗黙のbind)。つまりここで判明するのは、ローカルマシンに実在するインターフェースのアドレス(今回なら`lo`の`127.0.0.1`/`::1`、`eth0`の`172.17.0.4`)の中から、経路表に基づいて実際に選ばれるものです。同じログに写っていた`AF_NETLINK`での`RTM_GETADDR`(インターフェースのアドレス一覧取得)は、まさにこの判定に使うローカルアドレス一覧を集める処理でした。

:::

:::details `localhost`ではなく`eth0`のIPを指定したらどうなるか

`ssh sshdemo@localhost`の代わりに`ssh sshdemo@172.17.0.4`(コンテナの`eth0`自身のIPアドレス)を指定したらどうなるか試してみました。`127.0.0.1`/`::1`は最初からループバック専用として予約されたアドレスですが、`172.17.0.4`はDockerのブリッジネットワークが割り当てた、他のコンテナからも到達できる普通のIPです。

実行結果です。

```
$ ip route get 172.17.0.4
local 172.17.0.4 dev lo src 172.17.0.4 uid 0
    cache <local>
```

`eth0`自身のIPアドレス宛てでも、経路は`dev lo`と表示されました。これは経路表上の判断なので、実際のパケットも本当に`eth0`を通らないのか、`tcpdump`で`eth0`を直接監視しながら接続して確かめました。

実行結果です。

```
$ tcpdump -i eth0 -n port 22
0 packets captured
0 packets received by filter
0 packets dropped by kernel
```

`ssh sshdemo@172.17.0.4`で接続している間、`eth0`上には1パケットも観測されませんでした。接続前後の`/proc/net/dev`の統計でも`lo`のバイト数・パケット数だけが増え、`eth0`は変化なし。経路表の宣言・統計の差分・実際のパケットキャプチャの3つが一致したので、`eth0`自身のIPアドレスに接続しても、実際のパケットは`eth0`を一切通らず`lo`だけで完結している、と言えます。

ただし、straceの`connect`自体はこの違いを教えてくれません。

```
connect(3, {sa_family=AF_INET, sin_port=htons(22), sin_addr=inet_addr("172.17.0.4")}, 16) = 0
```

`localhost`に接続したときと見た目上まったく同じ`connect`の記録で、「実際は`lo`で処理された」という情報はsyscallレベルには出てきません。この経路のショートカットは`ip route get`やインターフェース統計を見て初めて分かるカーネル内部の判断で、straceだけを見ていても気づけないものでした。

:::

## 接続の成功と失敗を比較する

`connect`の返り値を、成功・拒否・無応答の3パターンで比較してみました。

**成功時**は、先ほど見た通り`connect(...) = 0`がそのまま返ってきます。

**sshdを止めてポートを閉じた状態**(`ECONNREFUSED`)を試すと、少し違う形で結果が現れました。

実行結果です。

```
connect(3, {sa_family=AF_INET6, ... "::1" ...}, 28) = -1 EINPROGRESS (Operation now in progress)
getsockopt(3, SOL_SOCKET, SO_ERROR, [ECONNREFUSED], [4]) = 0
socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) = 3
connect(3, {sa_family=AF_INET, ... "127.0.0.1" ...}, 16) = -1 EINPROGRESS (Operation now in progress)
getsockopt(3, SOL_SOCKET, SO_ERROR, [ECONNREFUSED], [4]) = 0
+++ exited with 255 +++
```

`connect`の感覚だと、失敗すれば`-1`とエラー番号がその場で返ってくると考えると思います。実際には、非同期(ノンブロッキング)ソケットのため`connect`自体は`EINPROGRESS`(処理中)を返すだけで、本当の結果は後続の`getsockopt(SOL_SOCKET, SO_ERROR)`で初めて判明していました。しかもIPv6(`::1`)で失敗した後、IPv4(`127.0.0.1`)でも同じように試し、両方失敗して初めて`ssh`は接続を諦めていました。

**実在しないIP**(`192.0.2.1`。RFC 5737で文書用に予約されているアドレスなので、実在するサーバーに迷惑をかける心配がありません)へ`ConnectTimeout=3`を指定して接続すると、また違う終わり方をしました。

実行結果です。

```
connect(3, {sa_family=AF_INET, sin_port=htons(22), sin_addr=inet_addr("192.0.2.1")}, 16) = -1 EINPROGRESS (Operation now in progress)
ppoll([{fd=3, events=POLLIN|POLLOUT}], 1, {tv_sec=3, tv_nsec=0}, NULL, 8) = 0 (Timeout)
+++ exited with 255 +++
```

`ECONNREFUSED`の時と違って`getsockopt`でエラーが判明することはなく、`ppoll`が指定した3秒(`ConnectTimeout=3`)ぴったりでタイムアウトしていました。`ConnectTimeout`オプションが、実体としては`ppoll`の待ち時間としてそのまま渡されていることが確認できました。

## 暗号化された通信を見る

接続が確立した後は、同じソケットに対して`read`と`write`が繰り返されます。

```
write(3, "-\336\222\355\375\370<\261\357\0\256\2\322\301b\17\2658B&\270Zl\"\377\257\36\367FqLq"..., 36) = 36
```

ここでSSHの鍵交換や認証、コマンド実行のやり取りが行われていますが、中身は暗号化されているためstraceからはバイト列にしか見えません。ここは深追いせず、「通信の中身は見えないが、通信していること自体は`read`/`write`の回数とサイズで観測できる」ことだけ確認しました。

なお、この間`getrandom`が1540回呼ばれていました。試しに通信を伴わない`ssh -V`だけを`strace -c`で見てみると、`getrandom`はわずか3回です。同じコマンド(`ssh sshdemo@localhost echo test`)を5回実行して比較しても、5回とも寸分違わず1540回でした。つまりこの大量の`getrandom`は実際の鍵交換・認証・パケットのやり取りの中で発生していて、しかも呼ばれる「回数」自体はこのセッションの構成(鍵交換アルゴリズムやパケット数)によって決まる固定値になっているようです。

RFC 4253(SSH Transport Layer Protocol)のBinary Packet Protocolには、各パケットのパディングについてこう書かれています。

> Arbitrary-length padding, such that the total length of (packet_length || padding_length || payload || random padding) is a multiple of the cipher block size or 8, whichever is larger. There MUST be at least four bytes of padding. The padding SHOULD consist of random bytes.
>
> 出典: [RFC 4253 - The Secure Shell (SSH) Transport Layer Protocol, Section 6](https://datatracker.ietf.org/doc/html/rfc4253#section-6)

パケットごとに最低4バイトのランダムなパディングが必須(SHOULD)なので、やり取りするパケット数が多いほど`getrandom`の回数も増えると考えられますが、1540回すべての内訳までは今回追い切れていません。

## 秘密鍵を探す動きを見る

最後に、使い捨ての秘密鍵をリネームしてから接続してみました。

```bash
mv ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.bak
strace -f -e trace=openat ssh -o BatchMode=yes sshdemo@localhost echo x
```

実行結果です。

```
openat(AT_FDCWD, "/home/sshdemo/.ssh/id_ed25519", O_RDONLY) = -1 ENOENT (No such file or directory)
```

```
$ ssh -o BatchMode=yes sshdemo@localhost echo x
sshdemo@localhost: Permission denied (publickey,password).
```

「sshは秘密鍵を探している」というのは比喩ではなく、実際にファイルシステムへの`openat`として観測できました。鍵が無ければ`ENOENT`、その後に認証全体が失敗する、という一連の流れが1つのログの中に収まっています。

## 接続を終える

正常に終了する場合は、最後にこう記録されていました。

```
write(3, "\370\236\317\36y\265\20:\300\\QY7\3408\234;\20Y\254$T\31\22t\267\\\336\376\17\311\260"..., 60) = 60
close(3)                          = 0
munmap(0xe31307656000, 266240)    = 0
exit_group(0)                     = ?
+++ exited with 0 +++
```

最後の`write`でおそらく切断のフレームを送り、ソケットを`close`し、`exit_group`でプロセスが終了します。`ssh user@server`という1行のコマンドは、この`execve`から`exit_group`までの間に発行される数百〜数千のシステムコールとして、Linuxカーネルから見えていました。

## まとめ

`ssh sshdemo@localhost`という1つのコマンドを`execve`から`exit_group`まで追うと、`connect`まわりだけで2つのことが分かりました。非同期の`connect`は`EINPROGRESS`を返すだけで、本当の結果(成功したのか、`ECONNREFUSED`だったのか)は`getsockopt`や`ppoll`という別のタイミングのシステムコールで判明する、という2段構えの仕組みになっていること。そしてUDPソケットへの`connect`が、パケットを送らずに経路情報だけを尋ねるために使われている場面があったことです。

今回は基本的な流れに絞りましたが、`strace -e trace=%file`や`%network`によるフィルタ、`-c`によるシステムコールの統計はまだ試せていません。`-T`は各システムコールの実行時間を計測するオプションで、どのsyscallに時間がかかっているかを特定できます。今回`getrandom`が1540回も呼ばれていることが分かったので、これが本当に無視できるくらい速いのか、それとも意外と時間がかかっているのか、`-T`で実際に計測してみたいです。次回はこのあたりをもう少し細かく覗いてみたいと思います。

普段ブラックボックスになりがちな「アプリケーションとOSの境界」ですが、straceを使うと、思っていたより多くのことが観測できると感じました。SSH以外のコマンドでも気になるものがあれば、皆さんも一度覗いてみてはいかがでしょうか。

## 参考

- [strace(1) - Linux manual page](https://man7.org/linux/man-pages/man1/strace.1.html)
- [ssh(1) - OpenBSD manual page](https://man.openbsd.org/ssh.1)
- [ssh_config(5) - OpenBSD manual page](https://man.openbsd.org/ssh_config)
- [sshd_config(5) - OpenBSD manual page](https://man.openbsd.org/sshd_config.5)
- [RFC 4253 - The Secure Shell (SSH) Transport Layer Protocol, Section 6](https://datatracker.ietf.org/doc/html/rfc4253#section-6)
- [RFC 5737 - IPv4 Address Blocks Reserved for Documentation](https://datatracker.ietf.org/doc/html/rfc5737)
- [Docker overview - Docker Docs](https://docs.docker.com/get-started/overview/)
- [OpenSSH Release Notes](https://www.openssh.org/releasenotes.html)
- [nss/getaddrinfo.c - glibc公式リポジトリ](https://sourceware.org/git/?p=glibc.git;a=blob;f=nss/getaddrinfo.c;hb=HEAD)
