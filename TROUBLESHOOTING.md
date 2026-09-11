# トラブルシューティング

`monica-swift`（iOS SDK）が出す警告の読み方と、ingest に弾かれたときの対処。

## 警告の見方

SDK が出す警告の既定の出力先は `os_log`。

| | |
| --- | --- |
| subsystem | `com.accelhack.monica` |
| category | `transport` |
| level | error（`OSLogType.error`） |

Console.app で subsystem を絞るか、シミュレータなら次で流せる。

```bash
xcrun simctl spawn booted log stream --style compact \
  --predicate 'subsystem == "com.accelhack.monica"'
```

出るのは 1 行で、`422` と `401` の 2 種類だけ。envelope 1 通につき 1 回。

```text
monica: ingest rejected the envelope with 422 (<code|unknown>): N issue(s); <path>: <message>; <path>: <message>
monica: ingest rejected the envelope with 401 (<code|unknown>); no further envelopes will be sent
```

`(<code>)` は ingest の `error.code`。body から読めなかったときは `unknown` になる。
`422` の行に並ぶのは `issues` の**先頭 10 件まで**で、残りは末尾に `; and N more` が付く（全件は
`onDiagnostic` から取れる）。DSN の key と envelope の中身は警告に載らない。

`transport` option で自作の transport に差し替えたときは、この警告も `onDiagnostic` も呼ばれない。

## ingest が envelope を拒否したとき

### 422 — envelope が schema に合っていない

`issues` の `path` が**直すべき field** を JSON path で名指す（`$.items[0].request.method` なら
1 件目の item の `request.method`）。その envelope は破棄され、再送しない。

よくある出どころ:

- `beforeSend` で field を書き換えた / 型を変えた
- `CaptureContext().context(_:_:)` や `scope.setContext(_:_:)` に渡した値の形が schema と合わない
- 取り込んでいる公開契約（`spec/`）と ingest 側の schema がずれている

### 401 — key が無効

この envelope を破棄し、**以後この transport は 1 通も送らない**（request 自体を出さない）。
DSN の public key が失効・削除・別 project のもの、といったとき。
DSN を直したうえでアプリを再起動するか、`Monica.install()` をやり直すと新しい transport ができる。

### 413 — envelope が大きすぎる

分割し直さず破棄する。`MonicaClient` が送信前に JSON 1,000,000 byte 以下へ分割しているので通常は起きない。
起きるとすれば間に proxy が挟まって上限が下がった場合で、そのときデータは黙って落ちる（警告は出ない）。

### それ以外

`429` と `5xx` は retry の対象。`400` や `404` など、ここまでに挙げた以外の `4xx` は破棄する（警告は出ない）。

## 送信結果の受け取り

`onDiagnostic` を渡すと、`os_log` の代わりに同じ警告がそのクロージャへ渡る。

```swift
options.onDiagnostic = { diagnostic in
  logger.warning("\(diagnostic.message)")
  for issue in diagnostic.result.issues {
    debugPanel.add(issue.path, issue.message)
  }
}
```

`{ _ in }` を渡せば警告は黙る。呼ばれるのは送信キュー上で、main thread ではない。

`MonicaDiagnostic`:

| field | 型 | 内容 |
| --- | --- | --- |
| `message` | `String` | 上の 1 行。全 MONICA SDK で同じ文面 |
| `result` | `MonicaTransportResult` | 下記 |

`MonicaTransportResult`:

| field | 型 | 内容 |
| --- | --- | --- |
| `accepted` | `Bool` | ingest が受理したか |
| `stopped` | `Bool` | `401` か `close()` でこの transport が停止済みか |
| `status` | `Int?` | 最後の試行の HTTP status。応答が無かった（I/O 失敗・timeout）ときと、停止済みで request を出さなかったときは nil |
| `errorCode` | `String?` | `error.code`。人が読むためのもので、分岐は `status` で書く |
| `errorMessage` | `String?` | `error.message` |
| `issues` | `[MonicaIssue]` | `error.issues`。`422` だけが持つ。**丸めず全件**入る |

`MonicaIssue` は `path` と `message`。

同じものは transport からも取れる。`MonicaTransport` には `send(_:) -> Bool` に加えて
`deliver(_:) -> MonicaTransportResult` があり、`MonicaClient` はこちらを呼ぶ。protocol の既定実装が
`send` を包むので、`send` だけ実装した transport もそのまま動く。

body の解析は `429` を除く `4xx` のときだけ。64 KiB を超える body、空・非 JSON・`error.json` に
合わない body は解析せず、`issues` 無しの破棄として扱う。`429` と `5xx` の body は読まない。

## 再送・queue の挙動

envelope 1 通の送信は最大 `maxRetries + 1` 回（既定 3 回）試す。

| 応答 | 挙動 |
| --- | --- |
| `2xx` | 受理 |
| `401` | 破棄してこの transport を停止 |
| `429` | `Retry-After` を整数秒として待つ（0〜60 秒に丸める）。整数で読めない / 無いときは backoff |
| `5xx` | backoff して retry |
| I/O 失敗・timeout | backoff して retry |
| その他の `4xx` | 破棄 |

backoff は `min(1000ms × 2^attempt, 30000ms)` を上限に、その 0.5〜1.0 倍を無作為に待つ。

retry を使い切った envelope の event は破棄され、queue には戻らない。破棄した件数は数えられ、
次に送る envelope の `discarded` に載る。queue は `maxQueueSize`（既定 100）を超えると古い順に落ちる。
`stats`（`queued` / `discarded`）で手元から見られる。

```swift
let stats = Monica.current?.stats
```

## よくある原因と対処

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `install()` が `MonicaConfigurationError.secretKeyInDSN` で失敗する | DSN の key が `msk_` | 管理画面で public（`mpk_`）の key を発行して差し替える |
| `install()` が `.insecureDSN` で失敗する | scheme が `https` でない | `https` にする。平文 `http` は `localhost` と `127.0.0.1` だけ |
| `install()` が `.invalidValue` で失敗する | option の値が範囲外（`sampleRate` が 0〜1 外、timeout が 0 以下、など） | 値を直す |
| 何も届かない。警告も出ない | `install()` を呼んでいない / `sampleRate` が小さい / `beforeSend` が nil を返している | `Monica.current` が nil でないか、`beforeSend` の戻り値を確かめる |
| `401` の警告が 1 度出たきり何も届かない | key が無効で transport が停止した | DSN を直してアプリを再起動する |
| クラッシュだけ届かない | `captureCrashes` が false / handler を入れられなかった | `Monica.current?.isCrashCaptureInstalled` を見る。false なら `crashReportDirectory` に書けているか確かめる |
| クラッシュ event に breadcrumb が無い | 仕様（breadcrumb は永続化していない） | `session.json` に残る tags / contexts / user を使う |
| クラッシュの frame が全部バイナリ名だけになる | archive で symbol が strip されている | app target の Build Settings で `STRIP_INSTALLED_PRODUCT = NO` |
| スタックオーバーフローのクラッシュだけ残らない | そのスレッドが `install()` より前から動いていた | アプリが自前のスレッドを作る前に `install()` を呼ぶ |
| 大きい event が届かない | 1 件で JSON 1,000,000 byte を超えている | context / message を減らす |
