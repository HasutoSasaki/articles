---
title: "Go言語 defer Close()の謎を1分で解決"
emoji: "🤔"
type: "tech" # tech: 技術記事 / idea: アイデア
topics: ["go", "golang"]
published: true
---

## 概要

Go言語の学習中に、defer のことをきちんと理解してなかったために、コードリーディングでつまづいた話を書きます。

## 生まれた疑問

Go言語でファイル操作を学んでいると、こんなコードをよく見かけます：

```go
file, err := os.Create("test.txt")
if err != nil {
    log.Fatal(err)
}
defer file.Close() // ここでClose()

file.WriteString("Hello World") // なぜClose()の後で書き込める？
```

**「`defer file.Close()` でファイルを閉じているのに、なぜその後で `file.WriteString()` できるの？」**

## 実際に挙動を見てみましょう

下記のGo Playgroundで実際に実行できます。

https://go.dev/play/


```go
package main

import (
    "fmt"
    "os"
)

func main() {
    fmt.Println("1. ファイルを開く")
    file, err := os.Create("test.txt")
    if err != nil {
        panic(err)
    }
    
    fmt.Println("2. defer file.Close() を設定")
    defer func() {
        fmt.Println("5. ファイルを閉じる")
        file.Close()
    }()
    
    fmt.Println("3. ファイルに書き込み")
    file.WriteString("Hello World")
    
    fmt.Println("4. 関数終了直前")
}
```

**実行結果：**
```
1. ファイルを開く
2. defer file.Close() を設定  
3. ファイルに書き込み
4. 関数終了直前
5. ファイルを閉じる
```

## 答え：deferは関数終了時に実行される

**ポイント：** `defer` は「今すぐ実行」ではなく「関数終了時に実行」されます。

つまり実際の処理順序は：
1. ファイルを開く
2. defer文を**登録**（まだ実行されない）
3. ファイル操作を実行
4. 関数終了
5. defer文が実行される（ここで初めてClose()）

## なぜこの書き方をするの？

### 1. エラーが起きてもCloseされる
```go
func readFile() {
    file, err := os.Open("data.txt")
    if err != nil {
        return // ここで関数終了してもClose()される
    }
    defer file.Close()
    
    // 何かエラーが起きても必ずClose()される
    data := make([]byte, 1000)
    file.Read(data)
}
```

### 2. Close()の書き忘れを防ぐ
ファイルを開いたらすぐに `defer file.Close()` と書く習慣をつけることで、Close忘れによるリソースリークを防げます。

## まとめ

- `defer` = 関数終了時に実行
- `defer file.Close()` の後でファイル操作できるのは当然
- エラー処理とリソース管理を確実に行うためのGoの定番パターン
