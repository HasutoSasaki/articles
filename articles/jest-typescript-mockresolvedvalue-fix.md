---
title: "Jest mockResolvedValueの型エラーを1分で解決"
emoji: "🧪"
type: "tech"
topics: ["初心者向け","jest", "typescript", "testing", "javascript"]
published: true
---

## 概要

個人開発中に該当のエラーに遭遇し、AIに尋ねたのですが回りくどい解決策を提案されてしまい、「初めから公式を参照した方が早かったな」という体験をしたため、記事として投稿することにしました。

https://jestjs.io/docs/mock-function-api#mockfnmockresolvedvaluevalue

## 問題

Jest + TypeScriptの組み合わせで`mockResolvedValue`を使うときに、下記のような型エラーに遭遇することがあります：

```typescript
// ❌ 型エラー
const mockFn = jest.fn().mockResolvedValue({ id: 'test' });
// Error: 型 'object' の引数を型 'never' のパラメーターに割り当てることはできません
```

## 原因

このエラーの原因は、`jest.fn()`を型情報なしで呼び出すことです。TypeScriptが戻り値の型を推論できないため、`mockResolvedValue`の引数が`never`型になってしまいます。

```typescript
jest.fn() // → 型が不明
  .mockResolvedValue() // → 引数がnever型になる
```

## 解決方法

**`jest.fn`に型引数を明示的に指定する**ことで解決できます。

```typescript
// ✅ 解決
import { jest } from '@jest/globals';

const mockFn = jest.fn<() => Promise<{ id: string }>>()
  .mockResolvedValue({ id: 'test' });
```

### 実際の使用例

実際のテストコードで見てみましょう。

**Before: 型エラーが発生**

```typescript
jest.mock('./service', () => ({
  Service: jest.fn().mockImplementation(() => ({
    getData: jest.fn().mockResolvedValue({ result: 'success' })
  }))
}));
```

**After: 型安全**

```typescript
interface Result {
  result: string;
}

const mockGetData = jest.fn<() => Promise<Result>>()
  .mockResolvedValue({ result: 'success' });

jest.mock('./service', () => ({
  Service: jest.fn().mockImplementation(() => ({
    getData: mockGetData
  }))
}));
```

## さまざまなパターン

### 引数がある関数の場合

```typescript
// 引数がある関数の型定義
const mockFnWithArgs = jest.fn<(id: string) => Promise<{ name: string }>>()
  .mockResolvedValue({ name: 'test user' });
```

### 複数の引数がある場合

```typescript
const mockComplexFn = jest.fn<(id: string, options: { limit: number }) => Promise<Item[]>>()
  .mockResolvedValue([{ id: '1', name: 'item1' }]);
```

## ポイント

1. **`jest.fn<関数の型>()`で型を明示**
2. **引数がある場合：`jest.fn<(arg: string) => Promise<Result>>()`**


## まとめ

Jest + TypeScriptで`mockResolvedValue`の型エラーが出たら、`jest.fn`に型引数を明示的に指定するだけで解決できます。この方法により、型安全性を保ちながらテストコードを書くことができます。