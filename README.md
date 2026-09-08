# MONICA iOS SDK (monica-swift)

iOS アプリへ組み込む MONICA の SDK。Swift Package `monica-swift`（library product `Monica`）を
Swift Package Manager だけで配る。iOS 13.0 以上、Swift 5 language mode。

設計は `monica-android` と同じで、queue、batch、sampling、`beforeSend`、envelope 分割、再送ポリシーを
Swift に写し、Apple プラットフォームで成立しない部分だけを差し替えている。

- transport は `URLSession`。ingest が要求する gzip は zlib で作る
- DSN は **public key（`mpk_`）だけ**を受け付ける。`.ipa` は誰でも展開できるので、`msk_` を渡すと
  `install` が `MonicaConfigurationError.secretKeyInDSN` を投げる
- 端末 / OS / アプリ version を `contexts` へ載せる。個体を特定する値は読まない
- クラッシュ（signal と未捕捉 `NSException`）は **ディスクに書いて次回起動時に送る**。
  Android と違い、死にかけのプロセスから HTTP は送れない
- `platform` は `swift`。言語の名前を送り、OS は `contexts.os` に載せる

```bash
swift test    # macOS で動く。Xcode のツールチェーンが要る（下の「開発」）
```

## 導入

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/Accel-Hack/monica-sdk-ios", from: "0.1.0"),
],
targets: [
  .target(name: "App", dependencies: [.product(name: "Monica", package: "monica-sdk-ios")]),
]
```

Xcode なら File → Add Package Dependencies… で同じ URL を入れる。SwiftPM は package の identity を
repository 名から採るので、`package:` に書くのは `monica-sdk-ios`（Package 名の `monica-swift` ではない）。

CocoaPods / Carthage は用意しない。`async/await` は公開 API に出していない。

## 初期化

```swift
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    var options = MonicaOptions(dsn: Secrets.monicaDSN, environment: "production")
    options.release = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    options.inAppModules = ["MyApp"]                 // 省略時は CFBundleExecutable
    options.beforeSend = { event, hint in event }    // PII の判断は利用者の責任
    do {
      try Monica.install(options)
    } catch {
      // DSN が secret key、など。ここで落とすかログにするかはアプリの判断
    }
    return true
  }
}
```

`install()` を呼ぶまで何も送らない。リンクしただけでは動き出さない。
`captureCrashes` を頼んだのに handler を入れられなかったとき（report 置き場に書けない等）は、
`install()` は成功して `isCrashCaptureInstalled` が false になる。クラッシュ以外は動き続ける。

`beforeSend` の中から `captureError` / `captureMessage` を呼んでも送られない（無限再帰を防ぐため捨てる）。
`Monica.current` や `addBreadcrumb` は呼んでよい。

```swift
let monica = Monica.current!
monica.captureError(error, context: CaptureContext().tag("feature", "checkout"))
monica.captureMessage("payment retry exhausted", context: CaptureContext().level(.warning))
monica.addBreadcrumb(category: "ui.click", message: "submitButton")
monica.setUser(id: "u_123")
monica.setScreen("CheckoutViewController")
monica.flush(timeout: 2)
```

## option

| option | 既定 | 意味 |
| --- | --- | --- |
| `dsn` | 必須 | `mpk_` の public key を含む DSN |
| `environment` | 必須 | `production` など。128 文字まで |
| `release` | `CFBundleShortVersionString` | |
| `inAppModules` | `CFBundleExecutable` | frame の `in_app` 判定。バイナリ image 名で比較する |
| `beforeSend` | なし | 送信前の最後の関門。PII の除去はここ。`nil` を返すと捨てる |
| `sampleRate` | `1.0` | |
| `maxQueueSize` / `batchSize` | `100` / `30` | `batchSize` は envelope の上限 100 と `maxQueueSize` に丸める |
| `maxBreadcrumbs` | `50` | 超えた分は古い順に落とす |
| `flushInterval` / `flushTimeout` | `5s` / `2s` | 通常時の送信間隔 |
| `requestTimeout` / `maxRetries` | `10s` / `2` | |
| `captureCrashes` | `true` | signal / NSException handler を入れる |
| `trackAppLifecycle` | `true` | foreground / background の breadcrumb |
| `attachDeviceContext` | `true` | 端末 / OS / アプリ context |
| `crashReportDirectory` | `Application Support/monica` | クラッシュ report と scope snapshot の置き場 |
| `transport` | `URLSessionTransport` | テスト用の差し替え口 |

## 自動で集めるもの / 集めないもの

`contexts.device` に `manufacturer: Apple` と model identifier（`iPhone15,2`）、`contexts.os` に `iOS` と
version、`contexts.app` に bundle identifier と version / build。foreground / background の遷移は
`app.lifecycle` breadcrumb に残す。

`identifierForVendor`、端末名、広告 ID、アカウント、位置情報は**一切読まない**。パーミッションを要求する
API も呼ばない。何が PII かはアプリ側にしか判断できないので、`setUser()` と `beforeSend` で明示した値だけを送る。

画面名は **swizzling で拾わない**。`UIViewController` のライフサイクルを横取りする公開 API が無く、
`viewDidAppear` の swizzle はアプリの挙動を変え得るため。`setScreen()` で明示する。

## エラーの表現

Swift の `Error` はスタックを持たないので、`captureError` を呼んだ場所のスタックが載る。
`exception.values[].type` は Swift の型名（`MyApp.CheckoutError`）、`NSError` は domain。
`NSUnderlyingErrorKey` を辿って cause chain にする（外側から内側の順）。

frame の `filename` は実行時に取れないので、symbol から導出する（公開契約 `payload.md` の Swift の段落）。
`MyApp.Checkout.pay()` は `MyApp/Checkout.swift`、`-[ViewController viewDidLoad]` は
`MyApp/ViewController.m`。symbol が無い frame は image 名だけになる。demangle した symbol と address は
`function` / `instruction_addr` / `image_addr` / `package` に載せ、`filename` には混ぜない。

## クラッシュ

signal（SIGABRT / SIGBUS / SIGFPE / SIGILL / SIGSEGV / SIGTRAP）は C の handler が受け、
クラッシュしたスレッドの frame pointer を歩いて **report をファイルに書き、元の disposition に戻して
return する**。OS は元の signal でプロセスを終了させるので、Apple のクラッシュログも残る。
handler 用の alternate stack は `install()` を呼んだスレッド（通常 main）にだけ登録するので、
**他スレッドのスタックオーバーフローは report が残らない**（他の種類のクラッシュは全スレッドで拾う）。
未捕捉 `NSException` は `NSSetUncaughtExceptionHandler` で名前と reason を同じ report に書く。

次回 `install()` 時に report を読み、`level: fatal` / `handled: false` の event にして最初に送る。
symbol の復元は**その時点で同じ UUID の image が load されているときだけ**行うので、クラッシュと
次回起動の間にアプリが更新されていても間違った名前は付かない。report と一緒に `session.json`
（release、environment、tags、contexts、user）を保存しておき、クラッシュ event はそれを使う。
**breadcrumb はクラッシュ event に載らない**（永続化していない）。

`session.json` には `setUser()` で渡した値がそのまま残る。端末内のアプリ container なので他アプリからは
読めないが、「スクラブ前の payload が端末に残る」ことになる。

### symbol が strip されるビルド

Xcode の archive は既定で symbol を strip する（`STRIP_INSTALLED_PRODUCT = YES`、
`STRIP_STYLE = all`）。その場合 frame は `MyApp` としか名付けられず、**同じ signal のクラッシュが
1 つの Issue に集まり、スタックも読めない**。Android の `-keepnames` に当たる条件は次のどちらか。

- app target の Build Settings で `STRIP_INSTALLED_PRODUCT = NO`（バイナリが数百 KB 大きくなる）
- dSYM を MONICA へ上げて server 側で symbolicate する（**未実装**）

## 公開契約

protocol は言語に依存しない契約なので、この repository は持たない。MONICA が
<https://spec.monica.accelhack.net/v1/> に配信しているものを取り込んだコピーが `spec/` にある。

```text
spec.lock.json   取り込んだ内容の記録（origin、version、revision、全ファイルの sha256）
spec/v1/         取り込んだコピー（package には入らない）
```

取り込みは script でやる。手で `spec/` を編集しても、次の取り込みで消える。
Python 3 の標準ライブラリだけで動き、`swift test` には乗せない。

```sh
python3 scripts/spec-sync.py                 # 配信元から取り込み直す
python3 scripts/spec-sync.py --check         # 取り込んだコピーが spec.lock.json と一致するか（network 不要）
python3 scripts/spec-sync.py --check-remote  # さらに配信元が動いていないか
```

起点は配信元の `index.json`。他の全ファイルのパスと sha256、バンドル全体の `revision` がそこに並んでいるので、
**何を取り込むかは配信元が決める**。この repository は取り込む対象の一覧を持たない。

`revision` はバンドル全体の指紋（各ファイルの `"<sha256>  <path>"` を path の byte 順に改行で繋いだ
文字列の sha256）で、版番号ではないので新旧や大小は読めない。`--check` はこれを `spec.lock.json` の
`files` から再計算するので、`spec/` を書き換えて lock の digest を揃えただけの改竄も落ちる。

契約テストは `Tests/MonicaTests/Contract/ProtocolContractTests.swift`。`swift test` の一部として走り、
spec が見つからないと skip せず失敗する。契約が変わったときに Swift だけ気付けない状態を作らないため。
schema を通ることは受理されることと同じではない（`payload.md` が prose で定めている義務がある）ので、4 層を見る。

1. `envelope.json` / `limits.json` / `error.json` が、この SDK の前提どおりであること
2. MONICA の test vector が、bundle の言うとおりの判定になること
3. この SDK が出す envelope が、schema と `payload.md` の義務（frame の向き、`in_app`、`filename` の組み方、
   fingerprint verbatim、RFC 3339 と暦の妥当性、上限での分割）を満たすこと
4. この SDK が投げる request と retry の定数が、`transport.json` の値と一致すること

schema の検証器は `Tests/MonicaTests/Contract/JSONSchema.swift` として draft 2020-12 の使っている部分集合を
自前実装し、未対応の keyword は黙って通さず例外にする。

`platform: swift` が配信中の schema に受理されることは、契約テストの 1 件（`testPlatformSwiftIsAcceptedByTheVendoredSchema`）
が単独で見る。MONICA 側が `platform` の値検証を外す変更を配信して取り込み直すまでは、この 1 件だけが落ちる。
他のテストは、その緩和を当てた schema で残りの義務をすべて検査する。

CI の `公開契約` job は `--check-remote` で配信元の `revision` を取り込み済みのものと比べる。落ちたら
`python3 scripts/spec-sync.py` で取り込み直し、`swift test` を通してから commit する。schedule でも毎日回すので、
契約が動けば PR を待たずに気付く。

### まだ実装していない契約

`transport.json` の `status` のうち、`413`（`split_and_retry`）は分割せず破棄する。`MonicaClient` が
送信前に JSON の byte 数を検査して envelope を分割しているので、ingest が `413` を返す状況を作らないことで
代えている。`error.json` の body は読んでいない（分岐は HTTP status だけで行う）。

黙って取り残されないように、契約テストは `transport.json` の section 名と status の語彙を固定している。
MONICA 側が section や status を増やすと、「この SDK が考慮していない契約が増えた」として落ちる。

## Release

SwiftPM の publish は git tag そのもの。`main` 上の commit に `X.Y.Z`（接頭辞なし）の tag を付けて push する。
`release.yml` が tag と `Monica.sdkVersion`（envelope の `sdk.version`）の一致、`swift test`、iOS 向け compile
を確かめてから GitHub Release を作る。一致しない tag は弾かれるので、版を上げるときは先に
`Sources/Monica/Monica.swift` の `sdkVersion` を直して merge する。

## 開発

```bash
swift build --build-tests && swift test     # macOS で動く。Xcode のツールチェーンが要る
```

`xcode-select` が Command Line Tools を指していると XCTest が見つからない。
`sudo xcode-select -s /Applications/Xcode.app` か、
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` で回す。

iOS 向けにコンパイルできることは CI と同じコマンドで見る。

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --scratch-path .build-ios \
  -Xswiftc -sdk -Xswiftc "$SDK" -Xswiftc -target -Xswiftc arm64-apple-ios13.0-simulator \
  -Xcc -isysroot -Xcc "$SDK" -Xcc -target -Xcc arm64-apple-ios13.0-simulator
```

シミュレータで本物のクラッシュを起こして確かめるアプリは `test/ios-sample/` にある（出荷しない、CI でも動かさない）。

## License

Apache License 2.0。`LICENSE` を見る。
