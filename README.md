# 1c-codex-skills

Скиллы для [Claude Code](https://claude.com/claude-code), в которых Claude поручает работу по 1С:Предприятие
[Codex CLI](https://github.com/openai/codex), а затем проверяет его результат по коду и фактам.

| Скилл | Что делает |
|---|---|
| [`codex-test-1c`](skills/codex-test-1c/SKILL.md) | Функциональное тестирование: Codex сам гоняет сценарии в тест-клиенте 1С через MCP-сервер **1c-testpilot** и пишет отчёт ✅ / ⛔ / ⚠️ |
| [`codex-review-offline`](skills/codex-review-offline/SKILL.md) | Код-ревью правок: Codex только читает локальную копию файлов, диффы относительно бэкапа и `context.md`, и возвращает находки по критичности |

Общий принцип обоих скиллов: Codex — исполнитель, Claude — проверяющий. Находки Codex не считаются
дефектами, пока Claude не подтвердит их по коду, метаданным или данным.

## Требования

- Windows, PowerShell 5.1+.
- [Claude Code](https://claude.com/claude-code) и [Codex CLI](https://github.com/openai/codex) (проверено на 0.155 и 0.160).
- Для `codex-test-1c` дополнительно:
  - 1С:Предприятие **8.3.27+** (или 8.5.1+) с лицензией на клиент, которым запускается тест-клиент;
  - MCP-сервер **1c-testpilot** (Python): исполняемый файл, например `%USERPROFILE%\.local\bin\1c-testpilot.exe`, и его `.env`.
- Для `codex-review-offline` — `git` в PATH (только для `git diff --no-index`, репозиторий не нужен).

## Установка

### Скиллы в Claude Code

Скопируйте нужные каталоги в каталог скиллов — пользовательский или проектный:

```powershell
Copy-Item -Recurse skills\codex-test-1c        "$env:USERPROFILE\.claude\skills\codex-test-1c"
Copy-Item -Recurse skills\codex-review-offline "$env:USERPROFILE\.claude\skills\codex-review-offline"
# или в проект: <проект>\.claude\skills\<скилл>
```

Вызов: `/codex-test-1c <промт.md>` («протестируй кодексом»), `/codex-review-offline <файл или объект>` («сделай ревью кодексом»).

Необязательно: чтобы Claude мог и сам работать с тест-клиентом (короткие проверки), подключите ему 1c-testpilot —
пример в [`claude/mcp.json.example`](claude/mcp.json.example) (в `.mcp.json` проекта или в настройки пользователя).

### Codex CLI (нужно только для тестирования)

Добавьте секцию MCP-сервера в `%USERPROFILE%\.codex\config.toml` — пример в
[`codex/config.toml.example`](codex/config.toml.example). Флаги одобрения и песочницы задавать не нужно:
раннеры передают их на каждый запуск. Ревью работает без MCP и пользовательского конфига.

## codex-test-1c — тестирование

1. Промт тестирования в Markdown: база, пользователь, платформа, сценарии с ожидаемым результатом, путь отчёта.
   Шаблон — [`examples/prompt-template.md`](examples/prompt-template.md).
2. Claude запускает Codex отдельным процессом через [`run-codex-test.ps1`](skills/codex-test-1c/scripts/run-codex-test.ps1).
   К промту добавляется [преамбула](skills/codex-test-1c/scripts/preamble.md): неинтерактивный режим, правило
   трёх попыток на шаг, закрытие окон авторизации «Отменой», частичный отчёт при обрыве.
3. Codex запускает тест-клиент 1С, проходит сценарии через инструменты `tc_*` и пишет отчёт.
4. Claude ждёт завершения, читает отчёт и проверяет каждую ⛔ по коду.

Проверка подключения (около минуты):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\codex-test-1c\scripts\run-codex-test.ps1 -WorkDir "C:\Temp\codex-test\probe" -Probe
```

В `C:\Temp\codex-test\probe\last_message.md` должен быть ответ `list_profiles` с `ok: true`,
в `status.txt` — `TESTPILOT_CALLS` больше нуля.

Полный прогон (20–60 минут) — отдельным процессом:

```powershell
$p = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',
  'skills\codex-test-1c\scripts\run-codex-test.ps1','-PromptFile','<промт.md>','-WorkDir','<полный путь рабочего каталога>',
  '-AddDir','<каталог отчёта>' -WindowStyle Hidden -PassThru; "PID $($p.Id)"
```

Результат: `status.txt` (`START` / `PREFLIGHT` / `EXIT` / `TESTPILOT_CALLS`), `last_message.md`, `stdout.log`,
`stderr.log` (UTF-16). `EXIT 0` при `TESTPILOT_CALLS 0` означает, что Codex до 1С не дошёл.

Главные подводные камни (подробно — в [SKILL.md](skills/codex-test-1c/SKILL.md)):

- Codex 0.160 вызывает MCP через мост exec: `tools.mcp__1c_testpilot__tc_session({...})`. Не запрещайте в промте «JavaScript / `tools.*`».
- `launch_client` всегда с `exe`, `version` и `user`: иначе запустится платформа из `.env` testpilot (может не быть лицензии) или появится окно входа.
- Обновление Codex может стереть секцию `[mcp_servers.1c-testpilot]` — раннер ловит это (`PREFLIGHT FAIL`).
- Рабочий каталог — полным путём, не коротким 8.3-именем (`ABCD~1`).

## codex-review-offline — код-ревью

Для проектов-выгрузок Конфигуратора (XML) без git: «до» берётся из папки-бэкапа, сделанной перед правкой.

1. Claude кладёт в рабочий каталог (ASCII-имя) текущие файлы, диффы относительно бэкапа (CRLF нормализован),
   `context.md` (что и зачем изменено) и `_prompt.txt` по шаблону из SKILL.md.
2. Запуск: [`codex-review.ps1`](skills/codex-review-offline/scripts/codex-review.ps1) —
   `codex exec --ignore-user-config --sandbox read-only`, ответ в `_review.md`.
3. Claude проверяет каждую находку фактами и докладывает раздельно: подтвердилось / снято / оставлено осознанно.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\codex-review-offline\scripts\codex-review.ps1 `
  -WorkDir "<workdir>" -PromptFile "<workdir>\_prompt.txt" -Effort high
```

Главные подводные камни:

- Песочница Windows `elevated` блокирует даже чтение файлов («blocked by policy») — раннер передаёт `windows.sandbox="unelevated"`, запрет записи сохраняется.
- `context.md` сохраняйте в UTF-8 **с BOM**: без него Codex читает кириллицу как ANSI.
- Кириллица в имени рабочего каталога мешает Codex читать файлы.

> `.ps1` хранятся в UTF-8 с BOM: Windows PowerShell 5.1 читает файлы без BOM как ANSI и ломает кириллицу.

## Структура

```
skills/codex-test-1c/
  SKILL.md                         — инструкция для Claude Code
  scripts/run-codex-test.ps1       — раннер Codex для тестирования
  scripts/preamble.md              — преамбула, дописываемая к любому промту тестирования
skills/codex-review-offline/
  SKILL.md                         — инструкция для Claude Code
  scripts/codex-review.ps1         — раннер Codex для ревью (read-only)
codex/config.toml.example          — подключение 1c-testpilot к Codex
claude/mcp.json.example            — (необязательно) подключение 1c-testpilot к Claude Code
examples/prompt-template.md        — шаблон промта тестирования
```
