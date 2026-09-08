#!/usr/bin/env python3
"""MONICA の ingest の stand-in。手元のシミュレータから送った envelope を受け、
vendoring した公開契約（spec/v1/envelope.json）で検証して 202 / 4xx を返す。

    python3 test/ios-sample/tools/stub-ingest.py            # 127.0.0.1:8787
    python3 test/ios-sample/tools/stub-ingest.py --port 9000 --record /path/to/items.jsonl

SDK は localhost / 127.0.0.1 に限って平文 http を許すので、DSN を
`http://mpk_local@localhost:8787/sample` にすればシミュレータ（Mac 本体の localhost）
から届く。stg の ingest は本物の鍵と配信済みの schema が要るので、SDK 自体の挙動を
見るときはこちらを使う。

検証は契約テスト（Tests/MonicaTests/Contract/JSONSchema.swift）と同じ部分集合の
JSON Schema draft 2020-12 で行い、未対応の keyword が schema に現れたら黙って通さず
起動時に止まる。Python 3 標準ライブラリだけで動く。

`platform` だけは契約テストと同じ扱いをする: vendoring した schema がまだ閉じた enum で
`swift` を弾くなら、MONICA 側で配信予定の緩和（空でない 64 文字以内の文字列）を当てて
受理する。緩和が配信されて取り込み直せば何もしない。`--strict` でこの扱いを止められる。
"""

import argparse
import gzip
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
SCHEMA_PATH = os.path.join(ROOT, "spec", "v1", "envelope.json")

SUPPORTED = {
    "$schema", "$id", "title", "description", "type", "properties", "required", "$ref", "$defs",
    "enum", "const", "anyOf", "not", "minLength", "maxLength", "minItems", "maxItems", "minimum",
    "pattern", "format", "items", "additionalProperties", "propertyNames",
}


class Schema:
    def __init__(self, root):
        self.root = root
        self._audit(root, "#")

    def _audit(self, schema, path):
        for keyword, value in schema.items():
            if keyword not in SUPPORTED:
                raise SystemExit("stub-ingest: unsupported JSON Schema keyword %r at %s" % (keyword, path))
            if keyword in ("properties", "$defs"):
                for name, sub in value.items():
                    self._audit(sub, path + "/" + keyword + "/" + name)
            elif keyword in ("items", "not", "additionalProperties", "propertyNames"):
                self._audit(value, path + "/" + keyword)
            elif keyword == "anyOf":
                for index, sub in enumerate(value):
                    self._audit(sub, "%s/anyOf/%d" % (path, index))

    def resolve(self, reference):
        node = self.root
        for segment in reference.lstrip("#").split("/"):
            if segment:
                node = node[segment]
        return node

    def validate(self, instance):
        issues = []
        self._validate(instance, self.root, "$", issues)
        return issues

    @staticmethod
    def _is_type(name, value):
        if name == "object":
            return isinstance(value, dict)
        if name == "array":
            return isinstance(value, list)
        if name == "string":
            return isinstance(value, str)
        if name == "boolean":
            return isinstance(value, bool)
        if name == "null":
            return value is None
        if name == "number":
            return isinstance(value, (int, float)) and not isinstance(value, bool)
        if name == "integer":
            return (isinstance(value, int) and not isinstance(value, bool)) or (isinstance(value, float) and value.is_integer())
        return False

    def _validate(self, value, schema, path, issues):
        if "$ref" in schema:
            self._validate(value, self.resolve(schema["$ref"]), path, issues)
        if "type" in schema and not self._is_type(schema["type"], value):
            issues.append({"path": path, "message": "expected " + schema["type"]})
            return
        if "enum" in schema and value not in schema["enum"]:
            issues.append({"path": path, "message": "not one of %s" % schema["enum"]})
        if "const" in schema and value != schema["const"]:
            issues.append({"path": path, "message": "expected the constant %r" % schema["const"]})
        if "anyOf" in schema:
            if not any(self._passes(value, variant) for variant in schema["anyOf"]):
                issues.append({"path": path, "message": "matches none of anyOf"})
        if "not" in schema and self._passes(value, schema["not"]):
            issues.append({"path": path, "message": "matches the schema it must not"})
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                issues.append({"path": path, "message": "shorter than minLength %d" % schema["minLength"]})
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                issues.append({"path": path, "message": "longer than maxLength %d" % schema["maxLength"]})
            if "pattern" in schema and re.search(schema["pattern"], value) is None:
                issues.append({"path": path, "message": "does not match pattern " + schema["pattern"]})
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                issues.append({"path": path, "message": "below minimum %s" % schema["minimum"]})
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                issues.append({"path": path, "message": "fewer than minItems %d" % schema["minItems"]})
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                issues.append({"path": path, "message": "more than maxItems %d" % schema["maxItems"]})
            if "items" in schema:
                for index, element in enumerate(value):
                    self._validate(element, schema["items"], "%s[%d]" % (path, index), issues)
        if isinstance(value, dict):
            for name in schema.get("required", []):
                if name not in value:
                    issues.append({"path": path + "." + name, "message": "required"})
            properties = schema.get("properties", {})
            for name, sub in properties.items():
                if name in value:
                    self._validate(value[name], sub, path + "." + name, issues)
            if "additionalProperties" in schema:
                for name, child in value.items():
                    if name not in properties:
                        self._validate(child, schema["additionalProperties"], path + "." + name, issues)
            if "propertyNames" in schema:
                for name in value:
                    self._validate(name, schema["propertyNames"], path + "." + name, issues)

    def _passes(self, value, schema):
        sub = []
        self._validate(value, schema, "$", sub)
        return not sub


def error_body(code, message, issues=None):
    body = {"error": {"code": code, "message": message}}
    if issues is not None:
        body["error"]["issues"] = issues
    return json.dumps(body).encode("utf-8")


def grouping_inputs(item):
    """What MONICA groups on: the innermost exception type and the in_app filenames."""
    if "fingerprint" in item:
        return "custom fingerprint=%s" % item["fingerprint"]
    values = (item.get("exception") or {}).get("values") or []
    if not values:
        return "message=%r" % item.get("message", "")
    innermost = values[-1]
    frames = ((innermost.get("stacktrace") or {}).get("frames")) or []
    in_app = [frame.get("filename") for frame in frames if frame.get("in_app")]
    return "%s in_app=%s" % (innermost.get("type"), in_app)


def make_handler(schema, record):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, body):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/v1/envelope":
                return self.reply(404, error_body("not_found", "no such route"))
            key = self.headers.get("X-Monica-Key", "")
            if self.headers.get("Content-Encoding") != "gzip":
                return self.reply(400, error_body("bad_request", "Content-Encoding: gzip is required"))
            if not key.startswith("mpk_"):
                return self.reply(401, error_body("unauthorized", "a public mpk_ key is required"))
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            try:
                envelope = json.loads(gzip.decompress(raw).decode("utf-8"))
            except (OSError, ValueError) as failure:
                return self.reply(400, error_body("bad_request", "body is not gzipped JSON: %s" % failure))
            issues = schema.validate(envelope)
            if issues:
                print("422", json.dumps(issues)[:400], flush=True)
                return self.reply(422, error_body("invalid_envelope", "The envelope does not match the MONICA schema", issues))
            for item in envelope["items"]:
                if item.get("type") != "error":
                    print("skipped unknown item type %r" % item.get("type"), flush=True)
                    continue
                values = (item.get("exception") or {}).get("values") or []
                print(json.dumps({
                    "sdk": envelope["sdk"], "platform": item.get("platform"), "level": item.get("level"),
                    "environment": item.get("environment"), "release": item.get("release"),
                    "type": values[0].get("type") if values else None, "message": item.get("message"),
                    "mechanism": values[0].get("mechanism") if values else None,
                    "frames": len(((values[0].get("stacktrace") or {}).get("frames")) or []) if values else 0,
                    "grouping": grouping_inputs(item), "tags": item.get("tags"), "user": item.get("user"),
                    "breadcrumbs": ["%s:%s" % (crumb.get("category"), crumb.get("message")) for crumb in item.get("breadcrumbs", [])],
                }, ensure_ascii=False), flush=True)
                if record:
                    record.write(json.dumps(item, ensure_ascii=False) + "\n")
                    record.flush()
            self.reply(202, json.dumps({"accepted": len(envelope["items"])}).encode("utf-8"))

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--record", help="受理した item を 1 行 1 JSON で追記するファイル")
    parser.add_argument("--strict", action="store_true", help="platform の緩和を当てず、vendoring した schema をそのまま使う")
    arguments = parser.parse_args()
    with open(SCHEMA_PATH, "r", encoding="utf-8") as handle:
        root = json.load(handle)
    platform = root["$defs"]["errorItem"]["properties"]["platform"]
    if not arguments.strict and "swift" not in platform.get("enum", ["swift"]):
        root["$defs"]["errorItem"]["properties"]["platform"] = {"type": "string", "minLength": 1, "maxLength": 64}
        print("stub-ingest: vendoring した schema は platform \"swift\" を弾くので、配信予定の緩和を当てて受理する（--strict で止める）", flush=True)
    schema = Schema(root)
    record = open(arguments.record, "a", encoding="utf-8") if arguments.record else None
    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), make_handler(schema, record))
    print("stub ingest on http://127.0.0.1:%d/v1/envelope (schema %s)" % (arguments.port, os.path.relpath(SCHEMA_PATH, ROOT)), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
