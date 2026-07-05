---
title: "【1分で理解】TailscaleとVPNの違い：実際にEC2に接続して分かったこと"
emoji: "🔐"
type: "tech"
topics: ["tailscale", "vpn", "セキュリティ", "初心者向け"]
published: true
---

## はじめに
Claude Codeをモバイルでアクセスするために、Tailscaleを触ったのがきっかけでした。VPNなのに `curl ifconfig.me` の結果が変わらない？Tailscaleって何？という疑問を解決します。

## TL;DR（結論）
- **一般的なVPN**: IPアドレスを変えて匿名化・地域制限回避
- **Tailscale**: デバイス同士を安全に直接接続するプライベートネットワーク

## 一般的なVPNの仕組み
主な目的: IPアドレス変更、地域制限回避、匿名化
```
あなたのPC → VPNサーバー → インターネット
```



## Tailscaleの仕組み
主な目的: デバイス間の直接通信、プライベートネットワーク構築、ゼロトラストセキュリティ


```
あなたのPC ←→ EC2サーバー
    ↕           ↕
スマホ     ←→ 会社PC
```



## 実際に試して分かった違い

### VPNの場合
```bash
# VPN接続前
curl ifconfig.me  # => 203.0.113.1 (自宅IP)

# VPN接続後  
curl ifconfig.me  # => 198.51.100.1 (VPNサーバーIP)
```

### Tailscaleの場合
```bash
# Tailscale接続 前/後 で変わらない
curl ifconfig.me  # => 203.0.113.1 (自宅IP) ← 変わらない！

# でもプライベートネットワークができる
tailscale ip     # => 100.64.1.5 (プライベートIP)
```

## EC2接続での実例

### 従来の方法（セキュリティリスク）
```bash
# パブリックIPでSSH
ssh -i key.pem ec2-user@54.123.45.67

# 問題点:
# - 世界中からアクセス可能
# - 場所が変わるたびにセキュリティグループ更新
# - ブルートフォース攻撃のリスク
```

### Tailscale使用（セキュア）
```bash
# EC2にTailscaleインストール後
ssh -i key.pem ec2-user@100.64.1.10  # プライベートIP

# メリット:
# - あなたのデバイスからのみアクセス可能
# - 場所が変わっても同じIPでアクセス
# - セキュリティグループ設定が1回だけ
```

## セキュリティグループ設定の違い

### 従来
```bash
# 頻繁な更新が必要
aws ec2 authorize-security-group-ingress \
    --cidr 203.0.113.1/32  # 自宅IP
    
# カフェに移動したら...
aws ec2 authorize-security-group-ingress \
    --cidr 198.51.100.1/32  # カフェIP
```

### Tailscale
```bash
# 一度だけ設定
aws ec2 authorize-security-group-ingress \
    --cidr 100.64.0.0/10  # Tailscaleネットワーク全体
    
# どこに移動しても設定変更不要！
```

## どちらを使うべき？

### 一般的なVPNが適している場合
- ✅ 地域制限回避
- ✅ 公共Wi-Fiでの匿名化
- ✅ IPアドレスを隠したい

### Tailscaleが適している場合
- ✅ 複数デバイスでの開発環境共有
- ✅ サーバーへの安全なアクセス

## まとめ
TailscaleはVPNという名前がついていますが、実際は**プライベートネットワーク構築ツール**です。

- **IPアドレスを変えたい** → 一般的なVPN
- **デバイス同士を安全に接続したい** → Tailscale


## 参考リンク
- [Tailscale公式ドキュメント](https://tailscale.com/kb/)
- [AWS VPC セキュリティグループ](https://docs.aws.amazon.com/vpc/latest/userguide/security-groups.html)

