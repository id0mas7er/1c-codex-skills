<#
  codex-review.ps1 - run Codex CLI as a read-only reviewer of 1C sources.

  Two modes:
    offline  Codex reads a LOCAL copy of the files prepared in -WorkDir
             (sources, diff_*.txt, context.md). For Designer XML exports without git.
    edt      Codex reads the objects in place: -WorkDir is the EDT workspace root
             (the folder that contains the EDT projects); the prompt lists the object folders.

  In both modes the user config and MCP are disabled (--ignore-user-config) and the
  sandbox is read-only: Codex cannot change anything on disk.

  Params:
    -Mode        offline | edt (default: offline).
    -WorkDir     offline: folder with the review materials; edt: EDT workspace root.
    -PromptFile  UTF-8 file with the full review prompt.
    -Effort      low | medium | high | max (default: high). low - quick answer on a very large file.
    -OutFile     Where to write Codex's final message
                 (default: offline - <WorkDir>\_review.md; edt - <PromptFile folder>\_review.md).
    -Model       Codex model (default: gpt-6-sol). Needed because the user config is ignored.
    -TimeoutSec  Watchdog: kill Codex and its children after this many seconds (default: 1800).

  Notes:
    * codex.exe is picked as the NEWEST build under %LOCALAPPDATA%\OpenAI\Codex\bin\*\
      (the hashed folder name changes on every desktop-app update), then from PATH.
    * The prompt goes to Codex via stdin from a file (UTF-8, no BOM). Stdin is closed at EOF,
      so Codex never hangs on "Reading additional input from stdin...", and Cyrillic survives.
    * windows.sandbox="unelevated": the "elevated" Windows sandbox blocks every subprocess,
      even file reads ("blocked by policy"). The read-only sandbox still forbids writes.
    * Exit code 0 with an empty/missing answer means Codex did not answer at all (usage limit,
      "at capacity", auth). The runner treats it as a failure and prints the log tail.
#>
[CmdletBinding()]
param(
  [ValidateSet('offline','edt')][string]$Mode = 'offline',
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [ValidateSet('low','medium','high','max')][string]$Effort = 'high',
  [string]$OutFile,
  [string]$Model = 'gpt-6-sol',
  [int]$TimeoutSec = 1800
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $WorkDir))    { throw "WorkDir not found: $WorkDir" }
if (-not (Test-Path -LiteralPath $PromptFile)) { throw "PromptFile not found: $PromptFile" }
$WorkDir    = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
$PromptFile = (Resolve-Path -LiteralPath $PromptFile).ProviderPath

$codex = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $codex) {
  $cmd = Get-Command codex -ErrorAction SilentlyContinue
  if ($cmd) { $codex = $cmd.Source } else { throw 'codex.exe not found under %LOCALAPPDATA%\OpenAI\Codex\bin or in PATH' }
}

if (-not $OutFile) {
  if ($Mode -eq 'edt') { $OutFile = Join-Path (Split-Path -Parent $PromptFile) '_review.md' }
  else                 { $OutFile = Join-Path $WorkDir '_review.md' }
}
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }

$runDir = Split-Path -Parent $OutFile
$stdin  = Join-Path $runDir '_stdin.txt'
$stdout = Join-Path $runDir '_codex_stdout.log'
$stderr = Join-Path $runDir '_codex_stderr.log'

$prompt = (Get-Content -Raw -Encoding UTF8 -LiteralPath $PromptFile).TrimStart([char]0xFEFF)
[IO.File]::WriteAllText($stdin, $prompt, (New-Object System.Text.UTF8Encoding($false)))

function Quote([string]$s) { '"' + ($s -replace '"', '\"') + '"' }

$argList = @(
  'exec', '--skip-git-repo-check', '--ignore-user-config', '--sandbox', 'read-only',
  '-c', (Quote "model=$Model"),
  '-c', (Quote "model_reasoning_effort=$Effort"),
  '-c', 'approval_policy=never',
  '-c', (Quote 'windows.sandbox="unelevated"'),
  '-C', (Quote $WorkDir),
  '-o', (Quote $OutFile),
  '-'
) -join ' '

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $codex -ArgumentList $argList -NoNewWindow -PassThru `
  -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null = $p.Handle

$timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
if ($timedOut) {
  & taskkill.exe /F /T /PID $p.Id | Out-Null
  $p.WaitForExit()
}
$code = $p.ExitCode

Write-Output ''
Write-Output "[codex-review] mode = $Mode  codex = $codex"
Write-Output "[codex-review] exit=$code  elapsed=$([int]$sw.Elapsed.TotalSeconds)s  effort=$Effort  model=$Model"
Write-Output "[codex-review] review file: $OutFile"

$empty = -not (Test-Path -LiteralPath $OutFile) -or ((Get-Item -LiteralPath $OutFile).Length -eq 0)
if ($timedOut -or $code -ne 0 -or $empty) {
  Write-Output '[codex-review] --- codex log tail ---'
  foreach ($log in @($stderr, $stdout)) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Encoding UTF8 -Tail 20 }
  }
  if ($timedOut) { throw "codex did not finish in $TimeoutSec s and was killed" }
  if ($code -ne 0) { throw "codex exec failed with exit code $code" }
  throw 'codex exited without an answer (usage limit, "at capacity" or auth?) - see the log tail above'
}
