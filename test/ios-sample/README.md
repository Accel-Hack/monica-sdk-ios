# monica-ios-sample

`monica-swift` をシミュレータ（または実機）で動かして確かめるためのアプリ。**出荷しない。CI でも動かさない。**
Xcode と iOS runtime が要るため手元専用。

signal handler が本物のクラッシュで動くこと、次回起動で fatal が届くことは単体テストでは半分しか
確かめられない（テストは `raise(2)` で handler を通すだけ）。このアプリで確かめるのは次の 7 点。

| 確認すること | どこで見るか |
| --- | --- |
| message / handled error が届く | console の `accepted`。管理画面の Issues で `platform` が `swift`、`sdk.name` が `monica-swift` |
| user、breadcrumb、screen tag が載る | Issues の event 詳細 |
| Swift の trap で report が書かれ、次回起動で fatal が届く | クラッシュ後に再起動し、console の `beforeSend … level=fatal` → `accepted` |
| NSException でも同じ | `-crash nsexception` で起動 |
| frame が symbolicate され、in_app の filename が `MonicaSample/….swift` | fatal event の frames、console の `grouping=` |
| ビルドをまたいで同じ grouping 入力 | `beforeSend` が出す `grouping=`（innermost type と in_app filename）が再ビルド後も一致 |
| strip されたビルドで in_app frame が `MonicaSample` だけに退化する | 下の §5 |

## 前提

| | 値 | 理由 |
| --- | --- | --- |
| Xcode | 26.x（確認したのは 26.6） | `swift test` と iOS simulator SDK。`xcode-select` が Command Line Tools を指しているなら `DEVELOPER_DIR` で指定する |
| iOS runtime | Xcode > Settings > Components か `xcodebuild -downloadPlatform iOS` | Xcode 本体には同梱されない |
| XcodeGen | `brew install xcodegen` | `.xcodeproj` をコミットしないため。`project.yml` が正 |
| deployment target | **13.0** | SDK の下限。ここで動くことを確かめたいので上げない |
| SDK の参照 | `path: ../..`（この repository の root） | 手元の変更をそのまま試すため。公開版を試すなら URL 参照に書き換える |

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select を変えたくない場合
```

## 1. DSN

管理画面（staging）で検証用 project の API key を **public** で発行して DSN をコピーする。
Settings の「Test」で鍵が生きていることを先に見ておく（SDK を疑う前の対照実験）。

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # MONICA_DSN を埋める。xcconfig では // がコメントなので https:/$()/ と書く
# または build setting で
xcodebuild ... MONICA_DSN='https://mpk_xxx@<ingest host>/<slug>'
```

DSN が空でもビルドは通る。その場合アプリは placeholder の鍵で install し、ingest が 401 を返すので
console に `REJECTED` と出る（401 のあと transport は送信を止める。`transport.json` の `drop_and_stop`）。

## 2. project を生成してビルド

```bash
cd test/ios-sample
xcodegen generate
xcodebuild -project MonicaSample.xcodeproj -scheme MonicaSample -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
```

## 3. 実行と観測

SDK 自身は何もログしない。観測点はサンプル側の `beforeSend` と `LoggingTransport`（`[MonicaSample]` で始まる行）。

```bash
xcrun simctl boot 'iPhone 17'
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/MonicaSample.app
xcrun simctl spawn booted log stream --style compact --predicate 'eventMessage CONTAINS "[MonicaSample]"' &
xcrun simctl launch booted net.accelhack.monica.sample
```

画面のボタンを上から順に押す。到達は管理画面の `/projects/<slug>/issues` と `/projects/<slug>/ingestion` で見る。

ボタン 1〜3 とクラッシュは launch argument からも起こせる（起動 0.5 秒後に動く）。

```bash
xcrun simctl launch booted net.accelhack.monica.sample -auto 1              # setUser → message → handled error → flush
xcrun simctl launch booted net.accelhack.monica.sample -crash swift         # fatalError → SIGTRAP
xcrun simctl launch booted net.accelhack.monica.sample -crash nsexception   # NSArray の範囲外 → NSException
```

期待する順序:

```
[MonicaSample] crashing with fatalError
（プロセス死。ここでは何も送らない。Application Support/monica/pending-crash.bin が書かれる）
--- 再起動 ---
[MonicaSample] beforeSend event_id=… level=fatal grouping=SIGTRAP in_app=["MonicaSample/Checkout.swift", "MonicaSample/MainViewController.swift", …]
[MonicaSample] accepted 1 item(s), NNNms
[MonicaSample] MONICA installed: 0 queued
```

report の置き場は `xcrun simctl get_app_container booted net.accelhack.monica.sample data` の
`Library/Application Support/monica/`。`session.json` に release / environment / tags / user が入っている。

## 4. stg に向ける前に、手元の stand-in で見る

`tools/stub-ingest.py` は ingest の stand-in。この repository が vendoring している公開契約
（`spec/v1/envelope.json`）で envelope を検証して 202 / 4xx を返し、item ごとに 1 行（grouping 入力を含む）を出す。
Python 3 の標準ライブラリだけで動く。

```bash
python3 test/ios-sample/tools/stub-ingest.py &                           # 127.0.0.1:8787
xcodebuild ... MONICA_DSN='http://mpk_local@localhost:8787/sample' build   # SDK は localhost だけ平文 http を許す
```

MONICA 側で `platform` の値検証を外す変更が配信されるまでは、stg の ingest は `platform: swift` を
422 で弾く。stand-in は契約テストと同じく、vendoring した schema がまだ `swift` を弾く間だけ
その緩和を当てて受理する（起動時にその旨を出す。`--strict` で止められる）。

## 5. strip されたビルドで何が起きるか

Release + `DEPLOYMENT_POSTPROCESSING=YES`（archive と同じ条件）で組むと symbol が strip され、
fatal の frame は `MonicaSample` としか名付けられない。console の `grouping=` が
`SIGTRAP in_app=["MonicaSample", "MonicaSample", "MonicaSample"]` になることを確認する。
`STRIP_INSTALLED_PRODUCT=NO` を足すと元に戻る。Release では `Checkout.explode()` が inline されるので
Debug より frame が少なく、grouping 入力も Debug とは一致しない。同じ構成で組んだビルド同士は一致する。

```bash
xcodebuild -project MonicaSample.xcodeproj -scheme MonicaSample -configuration Release \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build-release \
  DEPLOYMENT_POSTPROCESSING=YES build
```
