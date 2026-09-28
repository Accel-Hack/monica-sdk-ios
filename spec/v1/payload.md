# Payload の生成義務 (v1)

envelope の形は [`envelope.json`](./envelope.json) が決める。schema を通っても
grouping が壊れる書き方があるので、SDK が守るべきことをここに書く。

## 例外チェーンとフレームの並び順

- `exception.values` は外側から内側の順に並べる（`cause` / `getPrevious` を辿った順）
- `stacktrace.frames` は古い呼び出し元から throw 地点の順に並べる。全プラットフォームで同じ向きにする
- 並び順が逆だと、同じ例外が別の Issue になる。ここが言語ごとにズレやすい

## timestamp

- `sent_at`、`timestamp`、breadcrumb の `timestamp` は RFC 3339 の date-time にする。timezone を必ず付ける（`2026-08-30T09:00:00+09:00` か `...Z`）
- `T` の代わりに空白を使わない。暦として存在しない日付を送らない。どちらも `422` になる
- 公開している JSON Schema は形（`pattern`）までを表す。各欄が範囲内か（月が 12 以下、日がその月に実在する、時刻と offset が 23:59 以下）は表せないので、MONICA 側の検証だけが弾く。schema を通ったことを送信可否の判断に使わない

## in_app

- `in_app` は「利用者が書いたコードか」を SDK が判定した結果。`node_modules` / `vendor` / 標準ライブラリ / フレームワークは `false`
- 判定基準は SDK の設定で決める（例: Java の `inAppPackage`、JS の bundle 内かどうか）
- `in_app` を全フレームで `false` にすると、そのエラーはフレームワークの位置で group される

## filename

- `filename` は空文字にしない
- Java / Android は宣言クラスの package と `StackTraceElement.getFileName()` を連結して組み立てる。例: `com/example/app/service/OrderService.java`
- `$` を含む内部クラスや `lambda$…` は `function` 側に残す。`filename` を書き換えて表現しない
- native method には行番号が無い。`lineno` を省く

## fingerprint

- `fingerprint` は利用者が明示的にグルーピングを指定するための順序付き文字列配列。空配列にしない
- 値はそのまま使われる。SDK 側で trim・正規化・結合をしない
- 要素に区切り文字が入っていても衝突しない。SDK 側で escape しない

## tags と contexts

- `tags` は索引される。値は文字列だけにし、`user_id` のような高カーディナリティ値を入れない
- `contexts` は索引されない。構造を持つ付帯情報はこちらに入れる
- PII の除去は利用者の責任。SDK は推測で値を落とさず、`beforeSend` で利用者に選ばせる

## client_report と稼働確認

- `client_report` は単独の envelope で送る。error と同じ envelope に混ぜない。混ぜても受理はされる
- 送るのは init 時（`trigger: "start"`）と、直近 `presence.interval_ms`（既定 86400000 ミリ秒）に `202` を受け取った envelope が 1 通も無いとき（`"interval"`）だけ。再送中の envelope は数えない。他の envelope が受理されていれば稼働はそれで分かるので、沈黙しているときにだけ送る。`close()` での `"stop"` は任意で、MONICA は診断用に残すだけ
- status ごとの挙動とリトライは他の envelope と同じ。`401` で送信を止め、`429` / `5xx` は backoff し、尽きたら捨てて次の interval で送り直す。`discarded` にはそれまでに捨てた件数を載せ、`202` で 0 に戻す
- `release` は SDK に設定されていれば載せる。`timestamp` は SDK 側の時計で、MONICA は診断用に残すだけ。最終受信は MONICA の受信時刻で測る
- interval の下限は `presence.min_interval_ms`（60000 ミリ秒）。SDK はこれ未満の値を使わない
- 長寿命プロセス（Node.js、Java、常駐する PHP）はタイマーで `interval` を送る。serverless（Cloudflare Workers、Next.js の server、AWS Lambda）は isolate ごとに `start` を 1 回だけ送り、タイマーを持たない。日次のタイマーは serverless では発火しない
- PHP の php-fpm はリクエストごとにプロセスが始まる。前回の送信時刻をローカル（APCu か一時ファイルの mtime）に持ち、interval 以内なら送らない
- 配布物（browser とモバイル）は public key を使い、端末ごとに interval に 1 回だけ送る。前回 `202` を受けた時刻を端末のストレージ（browser は `localStorage`、無ければ `sessionStorage`。Android は SharedPreferences、iOS は UserDefaults）に持ち、プロセスやタブを再起動しても interval 以内なら送らない
- モバイル（Android / iOS）はプロセス起動時と、フォアグラウンド復帰時に判定して `"start"` を送る。バックグラウンドではタイマーを持たない。`"stop"` は送らない（OS が kill するので確実に送れない）。`platform` は error item と同じ値で、Android は `java`、iOS は `swift`
- browser はページ読み込み時に判定して `"start"` を送り、`"interval"` のタイマーを持たない。何日も開きっぱなしのタブは数えない
- 配布物はさらに `presence.sample_rate`（既定 1、0〜1）の確率で間引ける。既定は間引かない。母数が小さい配布物では間引きが沈黙の誤判定に直結するため、大規模な配布物だけが MONICA の project 設定で下げる。組み込む側のアプリに option は持たせない
- rate limit は通常の envelope と同じ枠で数える。`client_report` だけの特例は無い
- `202` の応答に `presence.override_headers` の header（`X-Monica-Presence-Interval-Ms` と `X-Monica-Presence-Sample-Rate`）があれば値を保存し、次の判定から interval と sample rate に使う。値は指数表記を使わない 10 進数（interval は整数のミリ秒）。配布物は端末のストレージ、サーバ SDK はプロセス内に持つ。header が無い応答では保存した値を消さない。値が壊れている（数値でない、interval が整数でないか `presence.min_interval_ms` 未満、rate が `presence.min_sample_rate`（0.01）未満か 1 より大きい）ときはその header を無視する。優先順位は MONICA の設定 > 契約の既定値

## 確かめ方

[`vectors/envelope/`](./vectors/envelope) の test vectors を自言語で回す。
`valid: true` は受理され、`valid: false` は拒否されなければならない。
`schema_rejects: false` の vector は、公開している JSON Schema では通るが
MONICA 側の検証では拒否される（schema は形の検査で、意味の検査までは
表現できない）。
