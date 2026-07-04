# [Draft] `datetime.now()` をドメイン層から追い出す — Python で書く TimeProvider パターン

## この記事の狙い

- `datetime.now()` がコードに散在するとテストが書けない／書けても脆い
- Clean Architecture のドメイン層に「時刻取得」を持ち込まないための **TimeProvider パターン**を、Python で短いコードで紹介する
- `freezegun` などのモンキーパッチ系ツールとの比較も提示し、どちらを選ぶべきかを明確にする

## 想定読者

- Python/Django/Flask/FastAPI でサーバサイドを書いている人
- 「時刻依存のテスト」で詰まった経験がある人
- Clean Architecture / DDD を読んで "ドメイン層を純粋に保つ" の実装イメージが湧いていない人

## 骨子（想定5〜6章）

### 1. はじめに: 何が困るのか

悪い例:

```python
# domain/order.py
from datetime import datetime

@dataclass
class Order:
    id: UUID
    created_at: datetime

    def is_stale(self) -> bool:
        # ← テストしたい瞬間、毎回日付が変わる
        return (datetime.now() - self.created_at).days > 30
```

- ユニットテストで「31日経った状態」を再現するのが難しい
- `datetime.now()` が Domain 層にある時点で、**ドメインに実行環境への依存**が染みている

### 2. 最初の一歩: 引数で時刻を受け取る

```python
def is_stale(self, now: datetime) -> bool:
    return (now - self.created_at).days > 30
```

- これだけで純粋関数になる
- テストが一行で書ける:

```python
assert order.is_stale(now=datetime(2026, 1, 1)) is True
```

- ただし呼び出し側が毎回 `datetime.now()` を渡すのは煩雑

### 3. TimeProvider パターン

インターフェース（Protocol）:

```python
# domain/shared/time_provider.py
from datetime import datetime
from typing import Protocol

class TimeProvider(Protocol):
    def now(self) -> datetime: ...
```

実装（Infra層）:

```python
# repositories/time/system_clock.py
from datetime import datetime, timezone

class SystemClock:
    def now(self) -> datetime:
        return datetime.now(timezone.utc)
```

Service 層で注入:

```python
class OrderService:
    def __init__(self, clock: TimeProvider, order_repo: OrderRepository):
        self.clock = clock
        self.order_repo = order_repo

    def archive_stale(self):
        now = self.clock.now()
        for order in self.order_repo.list_all():
            if order.is_stale(now):
                self.order_repo.archive(order.id)
```

### 4. テストが気持ちよくなる

```python
class FakeClock:
    def __init__(self, now: datetime):
        self._now = now
    def now(self) -> datetime:
        return self._now

def test_archive_stale():
    clock = FakeClock(datetime(2026, 3, 1))
    service = OrderService(clock, InMemoryOrderRepository(...))
    service.archive_stale()
    # ...
```

- モック不要、副作用なし、並列実行に強い
- 「任意の時刻」「時刻を進める」のも `clock._now = datetime(...)` だけで済む

### 5. `freezegun` / `pytest-freezer` との比較

| 観点 | TimeProvider | freezegun |
|---|---|---|
| 設計への侵襲 | あり（コードを書き換える） | なし（既存コードを凍結） |
| テスト速度 | 速い（モンキーパッチなし） | ランタイムで datetime を差し替える |
| 本番コードの明示性 | ◎（時刻依存が型に出る） | △（依存が隠れる） |
| 既存コードへの適用 | リファクタ必要 | すぐ使える |

- **新規コード**: TimeProvider が筋が良い
- **既存巨大コード**: freezegun からの段階移行もあり

### 6. よくある疑問

- Q: 毎回 `clock.now()` を呼ぶの？ → Service境界で1回取り、以降は `now: datetime` を渡し回すと副作用が出にくい
- Q: UUID や乱数は？ → 同じ発想で `IdProvider` / `RandomProvider` を切ると良い（次の記事ネタ）
- Q: グローバルな `monotonic()` まで抽象化する？ → パフォーマンス計測はそこまでしなくてOK

### 7. まとめ

- `datetime.now()` を Domain 層から追い出すと、純粋関数が増えてテストが書きやすくなる
- Protocol + Fake Clock で30行くらいから始められる
- freezegun との使い分けは "設計への侵襲 vs 手軽さ" のトレードオフ

## 補足メモ

- Python 3.11+ の `datetime.UTC` vs `timezone.utc` にも軽く触れる
- `zoneinfo` との組み合わせ（JST運用プロジェクトでは `ZoneInfo("Asia/Tokyo")` を返す `JstClock` を用意するなど）
- 将来的には `asyncio` 環境での `monotonic_clock` 抽象化も面白いが本記事スコープ外

## 書く前のTODO

- [ ] サンプルコードを単独で動かせる1ファイル版に整える（100行以内）
- [ ] freezegun の実コード比較を1つ書き起こす
- [ ] `IdProvider` への発展も末尾にリンク候補として用意
