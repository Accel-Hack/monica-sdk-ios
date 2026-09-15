# MONICA iOS SDK (monica-swift)

iOS / macOS アプリで起きたエラーとクラッシュを MONICA の ingest へ送る Swift Package。
Swift Package Manager だけで配る（library product は `Monica`）。

## 対応環境

| | |
| --- | --- |
| iOS | 13.0 以上 |
| macOS | 10.15 以上 |
| Swift tools | 5.9 以上（Swift 5 language mode） |

CocoaPods / Carthage は用意しない。公開 API に `async/await` は出していない。

## インストール

`Package.swift` に足す。

```swift
dependencies: [
  .package(url: "https://github.com/Accel-Hack/monica-sdk-ios", from: "0.1.0"),
],
targets: [
  .target(name: "App", dependencies: [.product(name: "Monica", package: "monica-sdk-ios")]),
]
```

Xcode なら File → Add Package Dependencies… に同じ URL を入れ、library `Monica` をアプリの target に追加する。
`package:` に書くのは repository 名の `monica-sdk-ios`（Package 名の `monica-swift` ではない）。

## 初期化

DSN はソースに直書きせず、`.xcconfig` の build setting から `Info.plist` 経由で読む。

```swift
import Monica
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let dsn = Bundle.main.infoDictionary?["MonicaDSN"] as? String ?? ""
    var options = MonicaOptions(dsn: dsn, environment: "production")
    options.inAppModules = ["MyApp"]
    do {
      try Monica.install(options)
    } catch {
      // DSN が不正、option の値が範囲外、など
    }
    return true
  }
}
```

DSN に入れられるのは **public key（`mpk_` で始まる）だけ**。`msk_` を渡すと `install()` が
`MonicaConfigurationError.secretKeyInDSN` を投げる。scheme は `https`（`localhost` と `127.0.0.1` だけ平文 `http` を許す）。

`install()` を呼ぶまで何も送らない。2 回目の `install()` は 1 回目を閉じて置き換える。

## 使い方

`Monica.current` が installed なインスタンスを返す（未 install なら nil）。

```swift
let monica = Monica.current!

monica.captureError(error, context: CaptureContext().tag("feature", "checkout"))
monica.captureMessage("payment retry exhausted", context: CaptureContext().level(.warning))
```

`captureError` / `captureMessage` は送った event の `event_id` を返す（sampling や `beforeSend` で捨てられたときは nil）。
`CaptureContext` は `level(_:)` / `message(_:)` / `handled(_:)` / `tag(_:_:)` / `context(_:_:)` を繋いで作る。

### event になるもの

Swift の `Error` はスタックを持たないので、`captureError` を呼んだ場所のスタックが載る。
`exception.values[].type` は Swift の型名（`MyApp.CheckoutError`）、`NSError` は domain。
`NSUnderlyingErrorKey` を辿って cause chain にする（外側から内側の順、最大 8 段）。
frame の `filename` は symbol から導出する（`MyApp.Checkout.pay()` は `MyApp/Checkout.swift`、
`-[ViewController viewDidLoad]` は `MyApp/ViewController.m`）。symbol が無い frame は image 名だけになる。

### scope

scope は全 event に載る tag / context / breadcrumb / user。

```swift
monica.setUser(id: "u_123")                                  // 任意の field を渡す setUser([String: Any]?) もある
monica.setScreen("CheckoutViewController")                   // tag `screen` と breadcrumb `ui.lifecycle`
monica.addBreadcrumb(category: "ui.click", message: "submitButton")
monica.scope.setTag("tier", "premium")
monica.scope.setContext("cart", ["items": 3])
```

画面名は自動では拾わない（swizzling しない）。`setScreen()` で明示する。

### 送信タイミング

`flushInterval` ごとに送る。`level` が `fatal` の event と、queue が `batchSize` に達したときは即座に送る。
アプリ側で待ちたいときは `flush(timeout:)`（送れたら true）。

```swift
let sent = monica.flush(timeout: 2)
let stats = monica.stats          // queued / discarded
monica.close()                    // flush して crash handler と observer を外す
```

### クラッシュ捕捉

`captureCrashes`（既定 `true`）で signal（SIGABRT / SIGBUS / SIGFPE / SIGILL / SIGSEGV / SIGTRAP）と
未捕捉 `NSException` の handler を入れる。クラッシュはその場では送らず、ディスクに書いて
**次回起動の `install()` で `level: fatal` / `handled: false` の event として送る**。

handler を入れられなかったとき（report 置き場に書けない等）、`install()` は成功して
`Monica.current?.isCrashCaptureInstalled` が false になる。クラッシュ以外の送信は動き続ける。

スタックオーバーフローまで捕まえるには、**アプリが自前のスレッドを作る前に `install()` を呼ぶ**。

### beforeSend

送信直前に event を書き換える / 捨てる。PII の除去はここでやる。

```swift
options.beforeSend = { event, hint in
  event.remove("user")
  return event          // nil を返すと捨てる
}
```

`beforeSend` の中から `captureError` / `captureMessage` を呼んでも捨てられる。`addBreadcrumb` などは呼んでよい。
`event` から `event_id` / `timestamp` / `platform` / `environment` / `level` / `type` を消したり、
`tags` を `[String: String]` 以外にした event はその場で破棄される。

## オプション

`MonicaOptions(dsn:environment:)` で作り、残りは var に代入する。

| option | 型 | 既定 | 説明 |
| --- | --- | --- | --- |
| `dsn` | `String` | 必須 | `mpk_` の public key を含む DSN |
| `environment` | `String` | 必須 | `production` など。1〜128 code point |
| `release` | `String?` | `CFBundleShortVersionString` | |
| `inAppModules` | `[String]` | `[]`（= `CFBundleExecutable`） | frame の `in_app` 判定に使うバイナリ image 名 |
| `beforeSend` | `((MonicaEvent, CaptureHint) -> MonicaEvent?)?` | `nil` | 送信直前の書き換え。`nil` を返すと捨てる |
| `sampleRate` | `Double` | `1` | 0〜1 |
| `maxQueueSize` | `Int` | `100` | 超えたら古い順に捨てる |
| `maxBreadcrumbs` | `Int` | `50` | 超えたら古い順に捨てる |
| `batchSize` | `Int` | `30` | `min(maxQueueSize, 100)` に丸められる |
| `flushInterval` | `TimeInterval` | `5` | 秒 |
| `flushTimeout` | `TimeInterval` | `2` | 秒。`close()` が待つ時間 |
| `requestTimeout` | `TimeInterval` | `10` | 秒 |
| `maxRetries` | `Int` | `2` | 再試行回数 |
| `captureCrashes` | `Bool` | `true` | signal / NSException handler を入れる |
| `trackAppLifecycle` | `Bool` | `true` | `app.lifecycle` breadcrumb を記録する |
| `attachDeviceContext` | `Bool` | `true` | `contexts.device` / `os` / `app` を載せる |
| `transport` | `MonicaTransport?` | `nil`（= `URLSessionTransport`） | 送信経路の差し替え |
| `onDiagnostic` | `((MonicaDiagnostic) -> Void)?` | `nil`（= `os_log`） | SDK の警告の受け口。`{ _ in }` で黙る |
| `crashReportDirectory` | `URL?` | `Application Support/monica` | crash report と `session.json` の置き場 |

## 自動で収集するもの

`attachDeviceContext` が true のとき、全 event に次が載る。

| | |
| --- | --- |
| `contexts.device` | `manufacturer`（`Apple`）、`model`（`iPhone15,2`）、シミュレータでは `simulator: true` |
| `contexts.os` | `name`（`iOS` / `macOS` など）、`version` |
| `contexts.app` | `app_identifier`（bundle identifier）、`app_version`（`CFBundleShortVersionString`）、`app_build`（`CFBundleVersion`） |

`trackAppLifecycle` が true のとき、`active` / `inactive` / `background` / `foreground` / `memory_warning` の遷移を
category `app.lifecycle` の breadcrumb に残す（UIKit のあるプラットフォームだけ。macOS では記録しない）。

`identifierForVendor`、端末名、広告 ID、アカウント、位置情報は**一切読まない**。パーミッションを要求する API も呼ばない。
利用者を指す値は `setUser()` と `beforeSend` で明示したものだけが送られる。

## 送信結果と診断

ingest が envelope を拒んだとき、SDK は `os_log`（subsystem `com.accelhack.monica` / category `transport`）へ
1 行の警告を出す。`onDiagnostic` を渡すと、同じ警告と ingest の応答を自分のログ基盤やデバッグ画面へ流せる。

警告の読み方、status ごとの対処、`onDiagnostic` が受け取る値、retry と queue の挙動は
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) に書いてある。

## 制約

- DSN に secret key（`msk_`）は渡せない。`install()` が失敗する
- breadcrumb はクラッシュ event に載らない（永続化していない）
- `session.json`（release / environment / tags / contexts / user）は crash report と一緒に端末内のアプリ container に残る。
  `setUser()` に渡した値はスクラブ前の形でそこに書かれる
- `install()` より前から動いていたスレッドではスタックオーバーフローを捕まえられない
- Xcode の archive は既定で symbol を strip する（`STRIP_INSTALLED_PRODUCT = YES`）。その場合 frame は
  バイナリ名（`MyApp`）としか名付けられず、同じ signal のクラッシュが 1 つの Issue にまとまる。
  app target の Build Settings で `STRIP_INSTALLED_PRODUCT = NO` にすると元の symbol が残る
- dSYM を上げて server 側で symbolicate する経路は無い
- envelope は送信前に JSON 1,000,000 byte 以下へ分割される。1 件で超える event は破棄する
- ingest が `413` を返した場合、分割し直さず破棄する

## ライセンス

Apache License 2.0。`LICENSE` を見る。

---

## 開発者向け

### ビルドとテスト

```bash
swift build --build-tests && swift test
```

macOS で動く。Xcode のツールチェーンが要る。`xcode-select` が Command Line Tools を指していると
XCTest が見つからないので、`sudo xcode-select -s /Applications/Xcode.app` か
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` で回す。

iOS 向けにコンパイルできることは CI と同じコマンドで見る。

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --scratch-path .build-ios \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios13.0-simulator \
  -Xcc -isysroot -Xcc "$SDK" -Xcc -target -Xcc arm64-apple-ios13.0-simulator
```

### 公開契約（spec/）

`spec/` は <https://spec.monica.accelhack.net/v1/> から取り込んだコピー、`spec.lock.json` はその記録。
手で `spec/` を編集しても次の取り込みで消える。

```bash
python3 scripts/spec-sync.py                 # 取り込み直す
python3 scripts/spec-sync.py --check         # spec.lock.json と一致するか（network 不要）
python3 scripts/spec-sync.py --check-remote  # さらに配信元と一致するか
```

契約テストは `Tests/MonicaTests/Contract/` にあり、`swift test` の一部として走る。

### リリース

1. `Sources/Monica/Monica.swift` の `sdkVersion` を上げて `main` へ merge する
2. その commit に `X.Y.Z`（接頭辞なし）の tag を打って push する

`release.yml` が tag と `sdkVersion` の一致、`spec-sync.py --check`、`swift test`、iOS 向け compile を確かめてから
GitHub Release を作る。

### sample app

シミュレータで本物のクラッシュを起こして確かめるアプリが `test/ios-sample/` にある（出荷しない、CI でも動かさない）。
手順は [test/ios-sample/README.md](test/ios-sample/README.md)。
