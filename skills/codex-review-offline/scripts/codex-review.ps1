<#
  codex-review.ps1 - run Codex CLI as a read-only reviewer over a LOCAL copy of 1C sources.
  User config and MCP are disabled (--ignore-user-config): Codex only reads files in -WorkDir.

  Params:
    -WorkDir     Local folder with the files to review (sources, diff_*.txt, context.md).
    -PromptFile  UTF-8 file with the full review prompt.
    -Effort      low | medium | high (default: medium). Use low for very large files.
    -OutFile     Where to write Codex's final message (default: <WorkDir>\_review.md).
    -Model       Codex model (default: gpt-5.5). Needed because the user config is ignored.

  Notes:
    * codex.exe is picked as the NEWEST build under %LOCALAPPDATA%\OpenAI\Codex\bin\*\
      (the hashed folder name changes on every desktop-app update), then from PATH.
    * Prompt is piped via stdin (UTF-8) with EOF close, so Codex does not block waiting
      for input, and Cyrillic survives the pipe.
    * windows.sandbox="unelevated": the "elevated" Windows sandbox blocks every subprocess,
      even file reads ("blocked by policy"). The read-only sandbox still forbids writes.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WorkDir,
  [Parameter(Mandatory=$true)][string]$PromptFile,
  [ValidateSet('low','medium','high')][string]$Effort = 'medium',
  [string]$OutFile,
  [string]$Model = 'gpt-5.5'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path -LiteralPath $WorkDir))    { throw "WorkDir not found: $WorkDir" }
if (-not (Test-Path -LiteralPath $PromptFile)) { throw "PromptFile not found: $PromptFile" }

$codex = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $codex) {
  $cmd = Get-Command codex -ErrorAction SilentlyContinue
  if ($cmd) { $codex = $cmd.Source } else { throw 'codex.exe not found under %LOCALAPPDATA%\OpenAI\Codex\bin or in PATH' }
}

if (-not $OutFile) { $OutFile = Join-Path $WorkDir '_review.md' }
if (Test-Path -LiteralPath $OutFile) { Remove-Item -LiteralPath $OutFile -Force }

$prompt = (Get-Content -Raw -Encoding UTF8 -LiteralPath $PromptFile).TrimStart([char]0xFEFF)
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$prompt | & $codex exec --skip-git-repo-check --ignore-user-config --sandbox read-only `
  -c "model=$Model" `
  -c "model_reasoning_effort=$Effort" `
  -c approval_policy=never `
  -c 'windows.sandbox="unelevated"' `
  -C $WorkDir -o $OutFile -
$code = $LASTEXITCODE

Write-Output ''
Write-Output "[codex-review] codex = $codex"
Write-Output "[codex-review] exit=$code  elapsed=$([int]$sw.Elapsed.TotalSeconds)s  effort=$Effort  model=$Model"
Write-Output "[codex-review] review file: $OutFile"
if ($code -ne 0) { throw "codex exec failed with exit code $code" }
