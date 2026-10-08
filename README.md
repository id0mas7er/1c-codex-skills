# 1c-codex-skills

Скиллы для [Claude Code](https://claude.com/claude-code), в которых Claude поручает работу по 1С:Предприятие
[Codex CLI](https://github.com/openai/codex), а затем проверяет его результат по коду и фактам.

| Скилл | Что делает |
|---|---|
| [`codex-test-1c`](skills/codex-test-1c/SKILL.md) | Функциональное тестирование: Codex сам гоняет сценарии в тест-клиенте 1С через MCP-сервер **1c-testpilot** и пишет отчёт ✅ / ⛔ / ⚠️ |
| [`codex-review-1c`](skills/codex-review-1c/SKILL.md) | Код-ревью правок: Codex только читает исходники и возвращает находки по критичности. Сам выбирает режим: **edt** — объекты прямо в проекте 1C:EDT по путям из дерева EDT; **offline** — выгрузка Конфигуратора без git (копия файлов, диффы с бэкапом, `context.md`) |
| [`ibcmd-1c`](skills/ibcmd-1c/SKILL.md) | Загрузка и выгрузка через **ibcmd** без Конфигуратора: частичный или полный импорт из XML-выгрузки в базу + обновление конфигурации БД, выгрузка базы или отдельных объектов в XML, создание базы из `.dt`/`.cf`, резервная копия `.cf`/`.cfe` и контроль результата. Codex не нужен |

Общий принцип скиллов: Codex — исполнитель, Claude — проверяющий. Находки Codex не считаются
дефектами, пока Claude не подтвердит их по коду, метаданным или данным. Итог каждого прогона дописывается
в память проекта (`Memory Bank.md` или файл, указанный в `CLAUDE.md`/`AGENTS.md`) — так его видят следующие
сессии и другие агенты; правила записи — в SKILL.md каждого скилла.

Что-то пошло не так — смотрите [TROUBLESHOOTING.md](TROUBLESHOOTING.md) (симптом → причина → что делать).
Не нашли решения — [заведите Issue](../../issues/new/choose) по шаблону.

## Требования

- Windows, PowerShell 5.1+.
- [Claude Code](https://claude.com/claude-code) и [Codex CLI](https://github.com/openai/codex) (проверено на 0.155 и 0.160).
- Для `codex-test-1c` дополнительно:
  - 1С:Предприятие **8.3.27+** (или 8.5.1+) с лицензией на клиент, которым запускается тест-клиент;
  - MCP-сервер **1c-testpilot** (Python): исполняемый файл, например `%USERPROFILE%\.local\bin\1c-testpilot.exe`, и его `.env`.
- Для `codex-review-1c`:
  - режим **edt** — [Node.js](https://nodejs.org/) в PATH (резолвер путей дерева EDT);
  - режим **offline** — `git` в PATH (только для `git diff --no-index`, репозиторий не нужен).
- Для `ibcmd-1c`: платформа 1С 8.3.14+ с `ibcmd.exe` (входит в установку платформы), Codex не нужен.

## Установка

### Скиллы в Claude Code

Скопируйте нужные каталоги в каталог скиллов — пользовательский или проектный:

```powershell
Copy-Item -Recurse skills\codex-test-1c        "$env:USERPROFILE\.claude\skills\codex-test-1c"
Copy-Item -Recurse skills\codex-review-1c      "$env:USERPROFILE\.claude\skills\codex-review-1c"
Copy-Item -Recurse skills\ibcmd-1c             "$env:USERPROFILE\.claude\skills\ibcmd-1c"
# или в проект: <проект>\.claude\skills\<скилл>
```

Вызов: `/codex-test-1c <промт.md>` («протестируй кодексом»), `/codex-review-1c <EDT-путь, файл или объект>` («сделай ревью кодексом»), `/ibcmd-1c load|export …` («загрузи в базу», «выгрузи исходники»).

> **Переименование.** Скилл `codex-review-offline` объединён с режимом EDT и называется теперь `codex-review-1c`.
> Если ставили старый — удалите `…\.claude\skills\codex-review-offline` и скопируйте новый каталог.

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

Результат: `status.txt` (`START` / `EXIT` / `TESTPILOT_CALLS`; строка `PREFLIGHT FAIL` появляется только при сбое проверки конфига), `last_message.md`, `stdout.log`,
`stderr.log` (UTF-16). `EXIT 0` при `TESTPILOT_CALLS 0` означает, что Codex до 1С не дошёл.

Модель и уровень рассуждений тестирования раннер задаёт сам: по умолчанию `gpt-6-luna` / `max`
(`-Model`, `-Effort` — переопределить).

Главные подводные камни (подробно — в [SKILL.md](skills/codex-test-1c/SKILL.md) и [TROUBLESHOOTING.md](TROUBLESHOOTING.md)):

- Codex 0.160 вызывает MCP через мост exec: `tools.mcp__1c_testpilot__tc_session({...})`. Не запрещайте в промте «JavaScript / `tools.*`».
- `launch_client` всегда с `exe`, `version` и `user`: иначе запустится платформа из `.env` testpilot (может не быть лицензии) или появится окно входа.
- Обновление Codex может стереть секцию `[mcp_servers.1c-testpilot]` — раннер ловит это (`PREFLIGHT FAIL`).
- Рабочий каталог — полным путём, не коротким 8.3-именем (`ABCD~1`).

## codex-review-1c — код-ревью

Один скилл, два режима. Режим выбирается автоматически (`--mode edt|offline` — явно):

| Признак | Режим |
|---|---|
| аргумент — путь из дерева EDT (`Документы→МойДокумент→Формы→ФормаДокумента`) или в проекте есть `DT-INF/PROJECT.PMF` | **edt** |
| в корне `Configuration.xml`, у объектов каталоги `Ext/` (выгрузка Конфигуратора) | **offline** |
| не определить однозначно | Claude спрашивает |

Общий порядок:

1. Claude определяет, что ревьюить:
   - **edt** — резолвер [`edt-resolve.mjs`](skills/codex-review-1c/scripts/edt-resolve.mjs) переводит путь из дерева EDT в папки
     объектов (проекты рабочей области находит сам: подпапки с `src/`); имя в нескольких проектах — уточняет;
   - **offline** — кладёт в рабочий каталог (ASCII-имя) текущие файлы, диффы относительно бэкапа (CRLF нормализован)
     и `context.md`.
2. Пишет `_prompt.txt` по шаблону из SKILL.md: по умолчанию ревьюятся только правки (маркеры из CLAUDE.md проекта),
   `--all` — объекты целиком. Повторный прогон — с журналом `review.md`: Codex сначала даёт вердикт по открытым
   находкам, потом новые.
3. Запуск: [`codex-review.ps1`](skills/codex-review-1c/scripts/codex-review.ps1) —
   `codex exec --ignore-user-config --sandbox read-only`, промпт через stdin, сторож по времени, ответ в `_review.md`.
4. Claude проверяет каждую находку фактами, даёт по ней вердикт (чинить / отклонить / на решение) и обновляет журнал.

```powershell
# edt: -WorkDir — корень рабочей области EDT (где лежат проекты)
powershell -NoProfile -ExecutionPolicy Bypass -File skills\codex-review-1c\scripts\codex-review.ps1 `
  -Mode edt -WorkDir "<рабочая область EDT>" -PromptFile "<workdir>\_prompt.txt"

# offline: -WorkDir — каталог с материалами
powershell -NoProfile -ExecutionPolicy Bypass -File skills\codex-review-1c\scripts\codex-review.ps1 `
  -Mode offline -WorkDir "<workdir>" -PromptFile "<workdir>\_prompt.txt"
```

Главные подводные камни:

- Песочница Windows `elevated` блокирует даже чтение файлов («blocked by policy») — раннер передаёт `windows.sandbox="unelevated"`, запрет записи сохраняется.
- Промпт — только файлом (раннер подаёт его в stdin и закрывает поток): аргументом командной строки кириллица ломается, а незакрытый stdin вешает Codex.
- По умолчанию модель `gpt-6-sol`, уровень рассуждения `high` (`-Model`, `-Effort` — переопределить). Ревью большого объекта идёт 3–15 минут (на `max` — до 25): раннер ждёт до `-TimeoutSec` (1800 с), потом принудительно завершает Codex. Запускайте в фоне.
- Код 0 без ответа (исчерпан лимит, «at capacity») раннер считает ошибкой и печатает хвост лога — не принимайте пустоту за «замечаний нет».
- offline: `context.md` сохраняйте в UTF-8 **с BOM**; кириллица в имени самого рабочего каталога мешает Codex читать файлы (выше по пути — не мешает).

> `.ps1` хранятся в UTF-8 с BOM: Windows PowerShell 5.1 читает файлы без BOM как ANSI и ломает кириллицу.

## ibcmd-1c — загрузка и выгрузка без Конфигуратора

```powershell
# сначала посмотреть состав файлов и команды
powershell -NoProfile -ExecutionPolicy Bypass -File skills\ibcmd-1c\scripts\ibcmd-load.ps1 `
  -DbPath "C:\Bases\ERP" -User "Администратор" -BaseDir "C:\Bases\ERP_SRC\cf" -Objects "Reports\МойОтчет" -WhatIf
# затем без -WhatIf, с резервной копией и контролем размера до apply: -BackupDir "C:\Temp\bak" -Verify

# выгрузка базы в XML (ibcmd пишет только в пустой каталог; -Replace заменяет содержимое, скрытые .git/.code-index не трогает)
powershell -NoProfile -ExecutionPolicy Bypass -File skills\ibcmd-1c\scripts\ibcmd-export.ps1 `
  -DbPath "C:\Bases\ERP" -User "Администратор" -OutDir "C:\Bases\ERP_SRC\cf" -Replace

# только отдельные объекты (export objects --recursive), в пустой каталог — для сверки «что в базе»
powershell -NoProfile -ExecutionPolicy Bypass -File skills\ibcmd-1c\scripts\ibcmd-export.ps1 `
  -DbPath "C:\Bases\ERP" -User "Администратор" -OutDir "C:\Temp\check" -Objects "Document.ЗаказКлиента,Report.МойОтчет"
```

Оба скрипта принимают `-TempDir` — каталог временных файлов ibcmd, если на системном диске мало места.
В SKILL.md также: создание базы из `.dt`/`.cf`, выгрузка всех расширений, откат.

Главные подводные камни (подробно — в [SKILL.md](skills/ibcmd-1c/SKILL.md)):

- Новый объект (и новое заимствование в расширении) грузится только вместе с `Configuration.xml`, иначе «нельзя добавлять объекты метаданных без загрузки родительского объекта».
- С `Configuration.xml` расширения ibcmd проверяет всё расширение и может упасть на старых ссылках форм («неизвестный предопределенный элемент»), не связанных с правкой. Обход — `-FullImport` (полный импорт каталога расширения); `-NoCheck` — только с согласия пользователя.
- **Повторный полный импорт расширения может его испортить** (импорт «успешен», `.cfe` в разы меньше, `apply` падает). Поэтому `-FullImport` требует `-BackupDir` и сам проверяет размер до `apply` (`-Verify`, код 3 и команда отката).
- Команды без `--user` в базе с пользователями не падают, а молча висят, ожидая пароль.
- Пустой пароль: ibcmd всё равно спрашивает его с консоли — скрипты подают пароль в stdin. База без пользователей — запускать без `-User`.
- Полная справка по ключам — `ibcmd help config`; `ibcmd config import --help` показывает только список режимов.

## Структура

```
skills/codex-test-1c/
  SKILL.md                         — инструкция для Claude Code
  scripts/run-codex-test.ps1       — раннер Codex для тестирования
  scripts/preamble.md              — преамбула, дописываемая к любому промту тестирования
skills/codex-review-1c/
  SKILL.md                         — инструкция для Claude Code (режимы edt и offline)
  scripts/codex-review.ps1         — раннер Codex для ревью (read-only, сторож по времени)
  scripts/edt-resolve.mjs          — резолвер пути из дерева EDT в папки объектов
skills/ibcmd-1c/
  SKILL.md                         — инструкция для Claude Code
  scripts/ibcmd-load.ps1           — частичный/полный импорт из XML + config apply (резервная копия, -Verify, -WhatIf)
  scripts/ibcmd-export.ps1         — выгрузка конфигурации/расширения или отдельных объектов в XML
codex/config.toml.example          — подключение 1c-testpilot к Codex
claude/mcp.json.example            — (необязательно) подключение 1c-testpilot к Claude Code
examples/prompt-template.md        — шаблон промта тестирования
TROUBLESHOOTING.md                 — типичные проблемы и их решение
.github/ISSUE_TEMPLATE/            — шаблон сообщения о проблеме
```
