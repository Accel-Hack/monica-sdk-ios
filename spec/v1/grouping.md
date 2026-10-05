# Issue のまとめ方 (v1)

MONICA が受け取ったエラーを、どれとどれを同じ Issue にまとめるかを書く。
SDK ごとの注意（`in_app` の設定、難読化、strip したビルドなど）は各 SDK の README にある。

## 何で決まるか

- グルーピングは MONICA 側で行う。SDK は行わない。同じ SDK の版でも、MONICA 側の規則が変われば Issue の分かれ方が変わる
- `fingerprint` を渡したイベントは、その値だけで決まる。スタックも例外の型もメッセージも見ない
- `fingerprint` が無く例外があるイベントは、最も内側の例外（`cause` / `getPrevious` を辿った末端）の型と、throw 地点に近い frame 最大 5 件で決まる
- `fingerprint` も例外も無いイベントは、メッセージで決まる

## 例外のとき

- `in_app` な frame だけを見る。`in_app` な frame が 1 つも無ければ、全 frame を見る。`in_app` の判定は SDK の設定で変わる（各 SDK の README）
- 各 frame はファイルと関数名で見る。同じファイルの別の関数で起きたエラーは別の Issue になる。関数名を変えると、それ以降は別の Issue になる。無名関数・lambda・closure の通し番号（Java の `lambda$run$0` と `lambda$run$1`、Swift の `closure #1` と `closure #2`）は区別しない
- 行番号と列番号は見ない。上に行を足しても同じ Issue のまま
- スタックがあるときは、例外のメッセージを見ない。同じ場所から投げられたエラーは、メッセージが違っても同じ Issue になる
- ブラウザ（`platform: "javascript"`）では関数名を見ず、ファイルだけを見る。minify した関数名は build ごとに変わるため。同じ bundle の同じ経路で起きた同じ型のエラーは、1 つの Issue になりやすい
- 依存（`node_modules`、`vendor`）の frame は package 単位で見る。依存の中のファイルや関数は区別しない
- ファイル名に入る 16 進のハッシュ（`main.a1b2c3.js`）と配信元のホスト名は無視する。Rollup / Vite 形式のハッシュ（`index-BkX9a2Qz.js`）を無視するのはブラウザだけで、サーバー側で bundle したファイルに付くと build ごとに別の Issue になる
- 同じ関数の再帰は、深さが違っても同じ Issue になる。ただし関数名を見ない frame（ブラウザ、symbol の無い frame）では、深さの違いで別の Issue になることがある
- スタックの無い例外は、例外の型とメッセージで決まる

## メッセージ

- 半角の数字を含む語、半角の `'` か `"` で囲まれた範囲、URL、UUID は可変部として無視する。`User 42 not found` と `User 7 not found` は同じ Issue になる。全角の数字や `「」` は可変部として扱わない
- それ以外の語は区別する。`User alice not found` と `User bob not found` は別の Issue になる。値を引用符で囲めば（`User 'alice' not found`）同じ Issue になる

## 分けたいとき、まとめたいとき

- 同じ場所から性質の違うエラーが出るなら、発生した場所で専用の例外クラスを投げる。例外の型が違えば別の Issue になる
- catch の中で新しい例外を作り直して送らない。作り直すとスタックが catch の位置になり、元の場所の区別が失われる。元の例外をそのまま送るか、`cause` に入れて包む
- それでも分けられないときは `fingerprint` を渡す。`fingerprint` は既定の分け方を置き換えるので、どこで起きたかの区別も値に含める（例: `["payment.reserve", "card-declined"]`）
- 別の Issue になったものを 1 つにしたいときは、管理画面で Issue をマージする
- 管理画面の Issue 詳細の「まとめ方」で、その Issue がどの値でまとめられたかを確かめられる
