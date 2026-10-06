<#
  Запуск функционального тестирования 1С силами Codex через MCP 1c-testpilot.

  Использование (запускать ОТДЕЛЬНЫМ процессом, а не фоновой задачей инструмента):
    Start-Process powershell.exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',
      '<SKILL_DIR>\scripts\run-codex-test.ps1','-PromptFile','<промт.md>','-WorkDir','<полный путь каталога, без ~>',
      '-AddDir','<каталог для отчёта>' -WindowStyle Hidden -PassThru
    Пробный вызов (проверка доступа к testpilot, ~1 мин):  ... -Probe

  Результат в WorkDir: status.txt (START / PREFLIGHT / EXIT / TESTPILOT_CALLS), last_message.md, stdout.log, stderr.log.
  TESTPILOT_CALLS 0 при EXIT 0 = прогон до 1С не дошёл (см. SKILL.md, «Подводные камни»).
#>
param(
    [string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [string[]]$AddDir = @(),
    [string]$Effort = '',
    [switch]$Probe
)
$ErrorActionPreference = 'Continue'
if ($WorkDir -match '~') { throw "WorkDir задан коротким 8.3-путём ($WorkDir): песочница Codex отказывает командам ('cannot enforce split writable root sets'). Укажи полный путь." }
New-Item -ItemType Directory -Force $WorkDir | Out-Null
# Явный CODEX_HOME: секция [mcp_servers.1c-testpilot] живёт в %USERPROFILE%\.codex\config.toml.
$env:CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
$codex = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $codex) {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
    if ($cmd) { $codex = Get-Item $cmd.Source } else { throw 'codex.exe не найден ни в %LOCALAPPDATA%\OpenAI\Codex\bin, ни в PATH' }
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$status = Join-Path $WorkDir 'status.txt'
"START $(Get-Date -Format s) probe=$Probe codex=$($codex.Directory.Name)" | Out-File $status -Encoding utf8

# Preflight: обновление Codex может стереть секцию сервера из config.toml — тогда exec падает
# «Error loading config.toml: invalid transport» (флаг default_tools_approval_mode ниже создаёт неполную секцию).
$mcpList = (& $codex.FullName mcp list 2>&1 | Out-String)
if ($mcpList -notmatch '1c-testpilot') {
    "PREFLIGHT FAIL: в $env:CODEX_HOME\config.toml нет [mcp_servers.1c-testpilot] — восстановить секцию (см. SKILL.md)" | Out-File $status -Append -Encoding utf8
    "EXIT 2 $(Get-Date -Format s)" | Out-File $status -Append -Encoding utf8
    exit 2
}

if ($Probe) {
    $prompt = 'Вызови MCP-инструмент tc_session сервера 1c-testpilot с action="list_profiles" (в Codex exec: tools.mcp__1c_testpilot__tc_session({action:"list_profiles"})) и выведи его ответ дословно. Не используй cua_repl. Больше ничего не делай.'
} else {
    if (-not $PromptFile -or -not (Test-Path $PromptFile)) { throw "Нет файла промта: $PromptFile" }
    $preamble = Get-Content (Join-Path $PSScriptRoot 'preamble.md') -Raw -Encoding UTF8
    $prompt = $preamble + (Get-Content $PromptFile -Raw -Encoding UTF8)
}

# Ключевые флаги (см. SKILL.md, «Подводные камни»):
#  - пользовательский конфиг НЕ игнорируем: в нём подключён [mcp_servers.1c-testpilot];
#  - default_tools_approval_mode="approve" — иначе при approval_policy=never все MCP-вызовы отклоняются;
#  - windows.sandbox=unelevated — elevated-песочница блокирует любые подпроцессы;
#  - plugin unified-computer-use выключен: его cua_repl/js модель путает с мостом exec, а реестра MCP в нём нет;
#  - features.code_mode_host НЕ выключать: через него же exec_command/apply_patch (иначе отчёт не записать);
#  - -C = WorkDir (не каталог с чужим AGENTS.md).
$cargs = @('exec', '--skip-git-repo-check', '--sandbox', 'workspace-write',
    '-c', 'approval_policy=never',
    '-c', 'mcp_servers.1c-testpilot.default_tools_approval_mode="approve"',
    '-c', 'plugins."unified-computer-use@openai-bundled".enabled=false',
    '-c', 'windows.sandbox="unelevated"',
    '-C', $WorkDir, '-o', (Join-Path $WorkDir 'last_message.md'))
foreach ($d in $AddDir) { $cargs += @('--add-dir', $d) }
if ($Effort) { $cargs += @('-c', "model_reasoning_effort=$Effort") }
$cargs += '-'

$prompt | & $codex.FullName @cargs 1> (Join-Path $WorkDir 'stdout.log') 2> (Join-Path $WorkDir 'stderr.log')
$code = $LASTEXITCODE
$calls = @(Get-Content (Join-Path $WorkDir 'stderr.log') -Encoding Unicode -ErrorAction SilentlyContinue | Select-String '^mcp: 1c-testpilot/').Count
"EXIT $code $(Get-Date -Format s)" | Out-File $status -Append -Encoding utf8
"TESTPILOT_CALLS $calls" | Out-File $status -Append -Encoding utf8
