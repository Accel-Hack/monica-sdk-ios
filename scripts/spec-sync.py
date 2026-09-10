#!/usr/bin/env python3
"""MONICA の公開契約バンドルを spec/ へ取り込む。

    python3 scripts/spec-sync.py                 取り込み直して spec.lock.json を書き換える
    python3 scripts/spec-sync.py --check         取り込み済みの spec/ が lock と一致するか（network 不要）
    python3 scripts/spec-sync.py --check-remote  さらに配信元が動いていないか

取り込むのは MONICA が https://spec.monica.accelhack.net/ に出している生成物で、
この repository はそのコピーを持つだけ。契約そのものはここでは決めない。

起点は配信元の `index.json` で、他の全ファイルのパスと sha256、バンドル全体の
`revision` がそこに並んでいる。だから

  - 何を取り込むかは配信元が決める（この repository は宣言を持たない）
  - 取得したものが壊れていないかは、索引の digest と照合して分かる
  - 上流にファイルが増えたことも分かる

が索引 1 本で済む。決定論は 3 つで守る。索引に載っているものだけを取りに行き、
受け取った byte 列をそのまま書き、索引から外れたファイルは消す。配信元の
revision が同じなら、何度実行しても同じ byte 列になる。

Python 標準ライブラリだけで動く。`swift test` には乗せない: 契約テスト
（Tests/MonicaTests/Contract/ProtocolContractTests.swift）はこの script が
取り込んだコピーと lock を読むだけで、network を使わない。
"""

import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

LOCK_FILE = "spec.lock.json"
MIRROR_DIRECTORY = "spec"
INDEX_FILE = "index.json"

# 配信元が落ちているときに CI が 10 分待たされないための上限
TIMEOUT_SECONDS = 20

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class SyncError(Exception):
    pass


def main(arguments):
    mode = "sync"
    origin_override = None
    for argument in arguments:
        if argument in ("--check", "--check-remote"):
            mode = argument[2:]
        elif argument.startswith("--origin="):
            origin_override = argument[len("--origin="):]
        elif argument in ("--help", "-h"):
            usage()
            return 0
        else:
            sys.stderr.write("unknown argument: " + argument + "\n")
            usage()
            return 2

    try:
        lock = read_lock()
        # 配信元の差し替えは手元で立てた複製から取り込むときに使う。lock に書かれた
        # origin が既定で、上書きしても lock には書き戻さない（記録は本番の配信元のまま）。
        origin = origin_override or os.environ.get("MONICA_SPEC_ORIGIN") or lock["origin"]
        origin = origin.rstrip("/")
        require_https(origin)

        if mode == "check":
            return check(lock)
        if mode == "check-remote":
            offline = check(lock)
            return check_remote(lock, origin) if offline == 0 else offline
        return sync(lock, origin)
    except SyncError as failure:
        sys.stderr.write("spec-sync: " + str(failure) + "\n")
        return 1


def usage():
    sys.stdout.write(
        "usage: python3 scripts/spec-sync.py [--check | --check-remote] [--origin=URL]\n"
        "  (no flag)       配信元から取り込み直し、spec/ と " + LOCK_FILE + " を書き換える\n"
        "  --check         spec/ が " + LOCK_FILE + " と一致するか。network を使わない\n"
        "  --check-remote  さらに配信元の revision が変わっていないか\n"
    )


# --- 取り込み --------------------------------------------------------------


def sync(lock, origin):
    index = fetch_index(origin, lock["version"])

    # 索引が本当に取ってこられる形か。壊れた索引で mirror を消してしまうと、
    # 取り込み直す元が手元から消える。
    fetched = {}
    for path, digest in index["files"].items():
        contents = fetch(origin + "/" + lock["version"] + "/" + path)
        actual = hashlib.sha256(contents).hexdigest()
        if actual != digest:
            raise SyncError(
                path + ": 取得したものが索引の digest と違います（索引 " + digest[:12]
                + "、取得 " + actual[:12] + "）。配信中に更新された可能性があるので、やり直してください。"
            )
        fetched[path] = contents

    # 先に消す。索引が limits.json を limits.json/http.json に変えた（あるいは
    # その逆をした）とき、書き込みを先にやると os.makedirs / open が
    # FileExistsError・IsADirectoryError で落ち、しかも何度やり直しても同じ
    # ところで落ちる。取ってくるものは既に全部 memory にあるので、消してから
    # 書いても取り込みは中断に強い。
    before_contents = {}
    for path in fetched:
        target = mirror_path(lock["version"], path)
        if os.path.isfile(target):
            before_contents[path] = read_bytes(target)
    removed = prune_mirror(lock["version"], list(fetched))

    added = []
    changed = []
    for path, contents in fetched.items():
        target = mirror_path(lock["version"], path)
        before = before_contents.get(path)
        if before == contents:
            continue
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as handle:
                handle.write(contents)
        except OSError as failure:
            raise SyncError(path + ": 書き込めません: " + str(failure))
        (added if before is None else changed).append(path)

    was_revision = lock["revision"]
    lock["revision"] = index["revision"]
    lock["files"] = index["files"]
    write_lock(lock)

    print("spec-sync: %d ファイルを %s/%s から取り込んだ" % (len(fetched), origin, lock["version"]))
    if was_revision == index["revision"]:
        print("  revision " + index["revision"][:12] + "（変わらず）")
    else:
        print("  revision " + was_revision[:12] + " → " + index["revision"][:12])
    report("  追加", added)
    report("  変更", changed)
    report("  削除", removed)
    if not added and not changed and not removed:
        print("  差分なし")
    return 0


def prune_mirror(version, declared):
    """索引に無いものを spec/<version>/ から消す。空になったディレクトリも畳む。"""
    keep = set(declared)
    removed = []
    for path in mirror_files(version):
        if path in keep:
            continue
        os.remove(mirror_path(version, path))
        removed.append(path)

    # 深い側から畳まないと、親を消す時点でまだ子が残っている
    root = version_root(version)
    for directory, _, _ in sorted(os.walk(root), key=lambda entry: entry[0], reverse=True):
        if directory == root:
            continue
        try:
            os.rmdir(directory)
        except OSError:
            # 中身が残っていれば消えない。それが望む挙動
            pass

    return sorted(removed)


# --- 検査 ------------------------------------------------------------------


def check(lock):
    """取り込み済みの spec/ が lock どおりか。network を使わないので、
    契約テストの直前に毎回走らせられる。"""
    problems = []
    for path, expected in lock["files"].items():
        target = mirror_path(lock["version"], path)
        if not os.path.isfile(target):
            problems.append(path + ": 取り込まれていない")
            continue
        actual = hashlib.sha256(read_bytes(target)).hexdigest()
        if actual != expected:
            problems.append(path + ": 中身が " + LOCK_FILE + " と違う（手で直したものは次の取り込みで消える）")
    for path in mirror_files(lock["version"]):
        if path not in lock["files"]:
            problems.append(path + ": " + LOCK_FILE + " が宣言していない")

    # lock 自身の整合性。digest を書き換えて mirror と揃えただけの改竄は、
    # revision を再計算すると合わなくなる。
    recomputed = revision_of(lock["files"])
    if recomputed != lock["revision"]:
        problems.append(
            LOCK_FILE + ": revision が files から再計算した値（" + recomputed[:12] + "）と違う"
        )

    if problems:
        sys.stderr.write(
            "取り込んだ spec が " + LOCK_FILE + " と一致しません。\n  - " + "\n  - ".join(problems)
            + "\npython3 scripts/spec-sync.py で取り込み直してください。\n"
        )
        return 1

    print(
        "spec-sync: 取り込んだ %d ファイルは %s と一致（revision %s）"
        % (len(lock["files"]), LOCK_FILE, lock["revision"][:12])
    )
    return 0


def check_remote(lock, origin):
    """配信元が動いたかどうか。SDK が古い契約に従い続けるのを止める。

    revision はバンドル全体の指紋なので、まず 1 個だけ比べれば足りる。違っていた
    ときだけ、どのファイルがどう動いたかを索引から出す。"""
    index = fetch_index(origin, lock["version"])
    if index["revision"] == lock["revision"]:
        print(
            "spec-sync: %s/%s の revision は取り込み済みのものと一致（%s）"
            % (origin, lock["version"], lock["revision"][:12])
        )
        return 0

    moved = []
    for path, digest in index["files"].items():
        if path not in lock["files"]:
            moved.append("追加 " + path)
        elif lock["files"][path] != digest:
            moved.append("変更 " + path)
    for path in lock["files"]:
        if path not in index["files"]:
            moved.append("削除 " + path)

    sys.stderr.write(
        origin + "/" + lock["version"] + " の公開契約が動いています。\n"
        + "  revision " + lock["revision"][:12] + " → " + index["revision"][:12] + "\n"
        + "  - " + "\n  - ".join(sorted(moved)) + "\n"
        + "python3 scripts/spec-sync.py で取り込み直し、契約テスト（swift test）を通してから commit してください。\n"
    )
    return 1


# --- 索引 ------------------------------------------------------------------


def fetch_index(origin, version):
    """配信元の索引。ここが取り込みの唯一の起点。"""
    url = origin + "/" + version + "/" + INDEX_FILE
    try:
        raw = fetch(url)
    except SyncError as failure:
        raise SyncError(
            url + " が取れません（" + str(failure) + "）。\n"
            "  索引はバンドルの生成物なので、配信元がまだ更新されていない場合もここで止まります。"
        )

    index = json.loads(raw.decode("utf-8"))
    if not isinstance(index, dict) or not all(key in index for key in ("version", "revision", "files")):
        raise SyncError(url + ": version、revision、files のどれかがありません")
    # 索引の `base` は「このバンドルを生成した配信元」の記録で、取得先の設定では
    # ない。mirror や手元に立てたものから取り込むと origin と食い違うのが正常な
    # ので、検証には使わない。信じるのはこちらが設定した origin と各 digest。
    if index["version"] != version:
        raise SyncError(
            url + ": 索引の version が " + json.dumps(index["version"]) + " で、要求した " + version + " と違います"
        )
    if not isinstance(index["files"], list) or not index["files"]:
        raise SyncError(url + ": files が空です")

    files = {}
    order = []
    for entry in index["files"]:
        if not isinstance(entry, dict) or "path" not in entry or "sha256" not in entry:
            raise SyncError(url + ": files の要素に path と sha256 がありません")
        path = str(entry["path"])
        require_safe_path(path)
        if path == INDEX_FILE:
            # 索引は自分の digest を持てないので、自分を載せない
            raise SyncError(url + ": 索引が自分自身を載せています")
        if path in files:
            raise SyncError(url + ": " + path + " が索引に 2 回出ています")
        if not re.fullmatch(r"[0-9a-f]{64}", str(entry["sha256"])):
            raise SyncError(url + ": " + path + " の sha256 が 64 桁の hex ではありません")
        files[path] = str(entry["sha256"])
        order.append(path)

    # files が path の byte 順に並ぶことは索引側の保証（バンドルの README に
    # 明記されている）。revision をこちらが lock から再計算するので、並びが
    # 変わると一致しなくなる。保証が崩れたことに気付けるよう、黙って
    # 並べ替えずに拒否する。
    if sorted(order, key=byte_order) != order:
        raise SyncError(url + ": files が path の byte 順に並んでいません")
    recomputed = revision_of(files)
    if recomputed != index["revision"]:
        raise SyncError(
            url + ": revision が files から再計算した値と違います（索引 "
            + str(index["revision"])[:12] + "、再計算 " + recomputed[:12] + "）"
        )

    return {"revision": str(index["revision"]), "files": files}


def byte_order(path):
    return path.encode("utf-8")


def revision_of(files):
    """バンドル全体の指紋。`"<sha256>  <path>"` を path の byte 順に改行で繋いだ
    文字列の sha256（末尾に改行を付けない）。MONICA 側の生成器と同じ定義。"""
    lines = [files[path] + "  " + path for path in sorted(files, key=byte_order)]
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


# --- lock ------------------------------------------------------------------


def read_lock():
    path = os.path.join(ROOT, LOCK_FILE)
    try:
        with open(path, "rb") as handle:
            lock = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError) as failure:
        raise SyncError(LOCK_FILE + " が読めません: " + path + " (" + str(failure) + ")")
    if not isinstance(lock, dict) or not all(key in lock for key in ("origin", "version", "revision", "files")):
        raise SyncError(LOCK_FILE + " に origin、version、revision、files のどれかがありません")
    if not isinstance(lock["files"], dict):
        raise SyncError(LOCK_FILE + " の files が object ではありません")
    version = str(lock["version"])
    if not re.fullmatch(r"v[0-9]+", version):
        raise SyncError(LOCK_FILE + ": version は v1 のような形にしてください")

    files = {}
    for path, digest in lock["files"].items():
        require_safe_path(str(path))
        files[str(path)] = digest if isinstance(digest, str) else ""

    return {
        "origin": str(lock["origin"]).rstrip("/"),
        "version": version,
        "revision": str(lock["revision"]),
        "files": {path: files[path] for path in sorted(files, key=byte_order)},
    }


def write_lock(lock):
    ordered = {
        "origin": lock["origin"],
        "version": lock["version"],
        "revision": lock["revision"],
        "files": {path: lock["files"][path] for path in sorted(lock["files"], key=byte_order)},
    }
    with open(os.path.join(ROOT, LOCK_FILE), "w", encoding="utf-8") as handle:
        json.dump(ordered, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


# --- 取得 ------------------------------------------------------------------


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """索引は信頼の起点そのもの（全ファイルの digest と revision を載せている）。
    リダイレクトを追うと、その起点が黙って別のホスト・別の scheme に差し替わる。
    https を強制している意味も無くなるので、3xx はエラーにする。SDK 本体の
    RedirectRefusingDelegate と同じ態度。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise SyncError(req.full_url + ": HTTP " + str(code) + " のリダイレクト（" + newurl + "）は追いません")


OPENER = urllib.request.build_opener(NoRedirects)


def fetch(url):
    """配信元から 1 ファイル。200 以外と、JSON として壊れている .json は失敗にする。
    半端な取り込みを commit させないため、呼び出し側は 1 つでも失敗したら止まる。"""
    request = urllib.request.Request(url, headers={"Accept": "*/*", "User-Agent": "monica-sdk-ios spec-sync"})
    try:
        with OPENER.open(request, timeout=TIMEOUT_SECONDS) as response:
            if response.status != 200:
                raise SyncError(url + ": HTTP " + str(response.status))
            contents = response.read()
    except urllib.error.HTTPError as failure:
        raise SyncError(url + ": HTTP " + str(failure.code))
    except urllib.error.URLError as failure:
        raise SyncError(url + ": " + str(failure.reason))
    except OSError as failure:
        raise SyncError(url + ": " + str(failure))

    if not contents:
        raise SyncError(url + ": 本文が空です")
    if url.endswith(".json"):
        try:
            json.loads(contents.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise SyncError(url + ": JSON として読めません")
    return contents


# --- パス ------------------------------------------------------------------


def version_root(version):
    return os.path.join(ROOT, MIRROR_DIRECTORY, version)


def require_safe_path(path):
    """索引が指すパスが spec/ の外を指さないことを、書く前に確かめる。索引は
    network から来るので、`..` が入っていないことを自分で見る必要がある。"""
    for segment in path.split("/"):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", segment) or ".." in segment:
            raise SyncError(path + ": 使えないパスです")


def mirror_path(version, path):
    require_safe_path(path)
    return os.path.join(version_root(version), *path.split("/"))


def mirror_files(version):
    """spec/<version>/ にある全ファイル。索引との差を両方向で見るために使う。"""
    root = version_root(version)
    if not os.path.isdir(root):
        return []
    found = []
    for directory, _, names in os.walk(root):
        for name in names:
            full = os.path.join(directory, name)
            found.append(os.path.relpath(full, root).replace(os.sep, "/"))
    return sorted(found, key=byte_order)


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def require_https(origin):
    # 契約を平文で取ってくると、取り込んだ内容を誰でも差し替えられる。
    if not origin.startswith("https://") and not origin.startswith("http://127.0.0.1"):
        raise SyncError("配信元は https にしてください: " + origin)


def report(label, paths):
    for path in paths:
        print(label + " " + path)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
