# codex-test-1c — функциональное тестирование 1С силами Codex + 1c-testpilot

Скилл для [Claude Code](https://claude.com/claude-code), который поручает [Codex CLI](https://github.com/openai/codex)
прогнать сценарии тестирования в тест-клиенте 1С:Предприятие через MCP-сервер **1c-testpilot**,
а потом разбирает отчёт.

Как это работает:

1. Вы (или Claude) пишете промт тестирования в Markdown: база, пользователь, платформа, сценарии с ожидаемым результатом, путь отчёта. Шаблон — [`examples/prompt-template.md`](examples/prompt-template.md).
2. Claude запускает Codex отдельным процессом через раннер [`run-codex-test.ps1`](skills/codex-test-1c/scripts/run-codex-test.ps1). К промту автоматически добавляется [преамбула](skills/codex-test-1c/scripts/preamble.md): неинтерактивный режим, правило трёх попыток на шаг, закрытие окон авторизации «Отменой», частичный отчёт при обрыве.
3. Codex сам запускает тест-клиент 1С, проходит сценарии через инструменты `tc_*` и пишет отчёт со статусами ✅ / ⛔ / ⚠️.
4. Claude ждёт завершения, читает отчёт и проверяет каждую ⛔ по коду и метаданным, прежде чем считать её дефектом.

Длинный прогон (20–60 минут, сотни вызовов MCP) надёжнее отдавать Codex: stdio-соединение MCP у Claude на таких прогонах может рваться.

## Требования

- Windows, PowerShell 5.1+.
- 1С:Предприятие **8.3.27+** (или 8.5.1+) с лицензией на клиент, которым будет запускаться тест-клиент.
- MCP-сервер **1c-testpilot** (Python) — исполняемый файл, например `%USERPROFILE%\.local\bin\1c-testpilot.exe`, и его `.env`.
- [Codex CLI](https://github.com/openai/codex) (проверено на 0.155 и 0.160).
- [Claude Code](https://claude.com/claude-code).

## Установка

### Claude Code

Скопируйте каталог скилла в каталог скиллов — пользовательский или проектный:

```powershell
Copy-Item -Recurse skills\codex-test-1c "$env:USERPROFILE\.claude\skills\codex-test-1c"
# или в проект: <проект>\.claude\skills\codex-test-1c
```

Скилл вызывается как `/codex-test-1c <промт.md>` или словами «протестируй кодексом».

Необязательно: чтобы Claude мог и сам работать с тест-клиентом (короткие проверки), подключите ему 1c-testpilot —
пример в [`claude/mcp.json.example`](claude/mcp.json.example) (в `.mcp.json` проекта или в настройки пользователя).

### Codex CLI

Добавьте секцию MCP-сервера в `%USERPROFILE%\.codex\config.toml` — пример в
[`codex/config.toml.example`](codex/config.toml.example). Флаги одобрения и песочницы задавать не нужно:
раннер передаёт их на каждый запуск.

Проверка (около минуты):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File skills\codex-test-1c\scripts\run-codex-test.ps1 -WorkDir "C:\Temp\codex-test\probe" -Probe
```

В `C:\Temp\codex-test\probe\last_message.md` должен быть ответ `list_profiles` с `ok: true`,
в `status.txt` — `TESTPILOT_CALLS` больше нуля.

> `.ps1` хранится в UTF-8 с BOM: PowerShell 5.1 читает файлы без BOM как ANSI и ломает кириллицу.

## Запуск полного прогона

```powershell
$p = Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',
  'skills\codex-test-1c\scripts\run-codex-test.ps1','-PromptFile','<промт.md>','-WorkDir','<полный путь рабочего каталога>',
  '-AddDir','<каталог отчёта>' -WindowStyle Hidden -PassThru; "PID $($p.Id)"
```

Результат в рабочем каталоге: `status.txt` (`START` / `PREFLIGHT` / `EXIT` / `TESTPILOT_CALLS`), `last_message.md`,
`stdout.log`, `stderr.log` (UTF-16). `EXIT 0` при `TESTPILOT_CALLS 0` означает, что Codex до 1С не дошёл.

Рабочий каталог указывайте полным путём, не коротким 8.3-именем (`ABCD~1`): с ним песочница Codex отказывает всем командам.

## Подводные камни

Подробно — в [`SKILL.md`](skills/codex-test-1c/SKILL.md). Самое важное:

- Codex 0.160 вызывает MCP через мост exec: `tools.mcp__1c_testpilot__tc_session({...})`. Не запрещайте в промте «JavaScript / `tools.*`» — это и есть рабочий путь.
- Без `default_tools_approval_mode="approve"` при `approval_policy=never` все MCP-вызовы отклоняются (раннер ставит флаг сам).
- `launch_client` всегда вызывайте с `exe`, `version` и `user`: иначе запустится платформа из `.env` testpilot (может не быть лицензии) или появится окно входа.
- Обновление Codex может стереть секцию `[mcp_servers.1c-testpilot]` — раннер это ловит (`PREFLIGHT FAIL`).

## Структура

```
skills/codex-test-1c/
  SKILL.md                    — инструкция для Claude Code
  scripts/run-codex-test.ps1  — раннер Codex
  scripts/preamble.md         — преамбула, дописываемая к любому промту
codex/config.toml.example     — подключение 1c-testpilot к Codex
claude/mcp.json.example       — (необязательно) подключение 1c-testpilot к Claude Code
examples/prompt-template.md   — шаблон промта тестирования
```
