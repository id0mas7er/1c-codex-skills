#!/usr/bin/env python3
"""Клиент к MCP-серверу v8std.ru (стандарты разработки 1С) без установки MCP.

Сервер stateless, Streamable HTTP: каждый tools/call — отдельный POST.

Примеры:
  python v8std.py search "модальные окна" --limit 5 --types standard diagnostic
  python v8std.py page std437 --body-limit 20000
  python v8std.py related std437 --relations diagnostic
  python v8std.py diag "acc 1245" "bslls:UsingModalWindows" "АПК:361"
  python v8std.py snippet --file proc.bsl
  python v8std.py snippet < proc.bsl
  python v8std.py raw v8std_search '{"query": "транзакции"}'

Адрес сервера: переменная V8STD_MCP_URL (по умолчанию https://ai.v8std.ru/mcp;
локальный Docker — http://127.0.0.1:18766/mcp).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

URL = os.environ.get("V8STD_MCP_URL", "https://ai.v8std.ru/mcp")
TIMEOUT = 60


def _parse_body(raw: str, content_type: str):
    # Ответ может прийти как JSON или как SSE-поток (event: message / data: {...}).
    if "text/event-stream" in content_type:
        result = None
        for line in raw.splitlines():
            if line.startswith("data:"):
                payload = line[5:].strip()
                if payload:
                    result = json.loads(payload)
        return result
    return json.loads(raw)


def call(tool: str, arguments: dict):
    body = json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool, "arguments": arguments},
    }, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/json, text/event-stream",
        "MCP-Protocol-Version": "2025-06-18",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8")
            msg = _parse_body(raw, resp.headers.get("Content-Type", ""))
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code}: {e.read().decode('utf-8', 'replace')[:2000]}")
    except urllib.error.URLError as e:
        sys.exit(f"Сервер недоступен ({URL}): {e.reason}")

    if msg is None:
        sys.exit("Пустой ответ сервера")
    if "error" in msg:
        sys.exit(f"Ошибка MCP: {json.dumps(msg['error'], ensure_ascii=False)}")

    result = msg.get("result", {})
    if result.get("isError"):
        texts = [c.get("text", "") for c in result.get("content", [])]
        sys.exit("Ошибка инструмента: " + "\n".join(texts))
    if "structuredContent" in result:
        return result["structuredContent"]
    # Фолбэк: текстовый контент, который обычно сам является JSON.
    texts = [c.get("text", "") for c in result.get("content", []) if c.get("type") == "text"]
    joined = "\n".join(texts)
    try:
        return json.loads(joined)
    except ValueError:
        return joined


# Служебные поля ранжирования и нормализации: нужны редко, а контекст съедают заметно.
NOISE = {"score_details", "match_reasons", "_generated_aliases", "aliases",
         "normalized_text", "tokens", "normalized_query", "semantic_enabled"}


def _strip(obj):
    if isinstance(obj, dict):
        return {k: _strip(v) for k, v in obj.items() if k not in NOISE}
    if isinstance(obj, list):
        return [_strip(v) for v in obj]
    return obj


def _print(data, full=False):
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")
    if isinstance(data, str):
        print(data)
        return
    if not full:
        data = _strip(data)
    # Страницу удобнее читать как Markdown, а не как экранированную JSON-строку.
    page = data.get("page") if isinstance(data, dict) else None
    if isinstance(page, dict) and isinstance(page.get("body_markdown"), str):
        md = page.pop("body_markdown")
        print(json.dumps(data, ensure_ascii=False, indent=2))
        print("\n----- body_markdown -----\n")
        print(md)
        return
    print(json.dumps(data, ensure_ascii=False, indent=2))


def main():
    p = argparse.ArgumentParser(description="v8std.ru: стандарты и диагностики 1С")
    p.add_argument("--full", action="store_true",
                   help="Полный ответ сервера, без удаления служебных полей (ставится до команды)")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("search", help="Поиск по базе стандартов (v8std_search)")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=10)
    s.add_argument("--types", nargs="*", help="standard diagnostic fix pattern service")
    s.add_argument("--mode", default="hybrid", choices=["hybrid", "exact", "bm25", "semantic"])
    s.add_argument("--cursor")

    g = sub.add_parser("page", help="Полный текст страницы (v8std_get_page)")
    g.add_argument("id", help="std437, алиас, путь или URL")
    g.add_argument("--body-limit", type=int, default=12000, help="1000–30000")

    r = sub.add_parser("related", help="Связанные стандарты/диагностики (v8std_get_related)")
    r.add_argument("id")
    r.add_argument("--relations", nargs="*", help="standard diagnostic edt_check related")
    r.add_argument("--limit", type=int, default=10)

    d = sub.add_parser("diag", help="Расшифровка кодов диагностик (v8std_explain_diagnostics)")
    d.add_argument("codes", nargs="*", help="Коды; если не заданы — по одному на строку из stdin")

    n = sub.add_parser("snippet", help="Сопоставить фрагмент BSL/SDBL со стандартами (v8std_explain_snippet)")
    n.add_argument("--file", help="Файл с фрагментом (UTF-8, с BOM тоже можно); иначе stdin")
    n.add_argument("--language", default="auto", choices=["auto", "bsl", "sdbl"])
    n.add_argument("--limit", type=int, default=10)

    w = sub.add_parser("raw", help="Произвольный вызов инструмента")
    w.add_argument("tool")
    w.add_argument("json_args", help="Аргументы в JSON")

    a = p.parse_args()

    def read_stdin():
        return sys.stdin.buffer.read().decode("utf-8-sig")

    if a.cmd == "search":
        args = {"query": a.query, "limit": a.limit, "mode": a.mode}
        if a.types:
            args["types"] = a.types
        if a.cursor:
            args["cursor"] = a.cursor
        out = call("v8std_search", args)
    elif a.cmd == "page":
        out = call("v8std_get_page", {"id_or_alias_or_url": a.id, "body_limit": a.body_limit})
    elif a.cmd == "related":
        args = {"id_or_alias_or_url": a.id, "limit": a.limit}
        if a.relations:
            args["relations"] = a.relations
        out = call("v8std_get_related", args)
    elif a.cmd == "diag":
        codes = a.codes or [l.strip() for l in read_stdin().splitlines() if l.strip()]
        if not codes:
            sys.exit("Не переданы коды диагностик")
        out = call("v8std_explain_diagnostics", {"codes": codes})
    elif a.cmd == "snippet":
        if a.file:
            with open(a.file, encoding="utf-8-sig") as f:
                text = f.read()
        else:
            text = read_stdin()
        if len(text) > 12000:
            sys.exit(f"Фрагмент {len(text)} символов > 12000: передайте одну релевантную процедуру")
        out = call("v8std_explain_snippet", {"snippet": text, "language": a.language, "limit": a.limit})
    else:
        out = call(a.tool, json.loads(a.json_args))

    _print(out, a.full)


if __name__ == "__main__":
    main()
