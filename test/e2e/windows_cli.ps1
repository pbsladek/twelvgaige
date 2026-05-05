$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir "../..")
$BaseTmp = if ($env:TWELVGAIGE_E2E_TMP) { $env:TWELVGAIGE_E2E_TMP } else { [System.IO.Path]::GetTempPath() }
$RunId = "{0}-{1}" -f $PID, ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
$E2ETmp = Join-Path $BaseTmp "twelvgaige-windows-cli-$RunId"
$Artifacts = Join-Path $E2ETmp "artifacts"
$Transcript = Join-Path $Artifacts "transcript.log"
$Step = 0
$Success = $false

if ($env:TWELVGAIGE_E2E_BIN) {
  $TwelvgaigeExe = $env:TWELVGAIGE_E2E_BIN
  $TwelvgaigePrefix = @()
} else {
  $TwelvgaigeExe = "escript"
  $TwelvgaigePrefix = @(Join-Path $RepoRoot "twelvgaige")
}

function Initialize-E2E {
  if (Test-Path $E2ETmp) {
    Remove-Item -Recurse -Force $E2ETmp
  }

  New-Item -ItemType Directory -Force $Artifacts | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $E2ETmp "install") | Out-Null
  New-Item -ItemType Directory -Force (Join-Path $E2ETmp "run") | Out-Null

  $env:TWELVGAIGE_INSTALL_DIR = Join-Path $E2ETmp "install"
  $env:TWELVGAIGE_STORE_SQLITE = Join-Path $E2ETmp "store.sqlite3"
  $env:TWELVGAIGE_RUNTIME_DIR = Join-Path $E2ETmp "run"
  $env:TWELVGAIGE_BREECH_ENDPOINT = Join-Path $env:TWELVGAIGE_RUNTIME_DIR "breech.endpoint.json"
  $env:ERL_CRASH_DUMP = Join-Path $E2ETmp "erl_crash.dump"

  "e2e temp: $E2ETmp" | Write-Host
  "bin: $TwelvgaigeExe $($TwelvgaigePrefix -join ' ')" | Set-Content -Path $Transcript
}

function Copy-TraphouseFixture {
  $Destination = Join-Path $E2ETmp "traphouse"
  Copy-Item -Recurse -Force (Join-Path $RepoRoot "docs/traphouse") $Destination
  return $Destination
}

function Invoke-TwelvgaigeOk {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs)

  $script:Step += 1
  $Stdout = Join-Path $Artifacts "$script:Step.stdout"
  $Stderr = Join-Path $Artifacts "$script:Step.stderr"
  "`n[$script:Step] ok: $TwelvgaigeExe $($TwelvgaigePrefix -join ' ') $($CommandArgs -join ' ')" |
    Add-Content -Path $Transcript

  & $TwelvgaigeExe @TwelvgaigePrefix @CommandArgs > $Stdout 2> $Stderr
  $Status = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }

  Get-Content -Path $Stdout -Raw -ErrorAction SilentlyContinue | Add-Content -Path $Transcript
  Get-Content -Path $Stderr -Raw -ErrorAction SilentlyContinue | Add-Content -Path $Transcript

  if ($Status -ne 0) {
    Write-Error "command failed with status $Status; stdout=$Stdout stderr=$Stderr"
  }

  return $Stdout
}

function Invoke-TwelvgaigeFail {
  param(
    [int]$ExpectedStatus,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs
  )

  $script:Step += 1
  $Stdout = Join-Path $Artifacts "$script:Step.stdout"
  $Stderr = Join-Path $Artifacts "$script:Step.stderr"
  "`n[$script:Step] fail($ExpectedStatus): $TwelvgaigeExe $($TwelvgaigePrefix -join ' ') $($CommandArgs -join ' ')" |
    Add-Content -Path $Transcript

  & $TwelvgaigeExe @TwelvgaigePrefix @CommandArgs > $Stdout 2> $Stderr
  $Status = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }

  Get-Content -Path $Stdout -Raw -ErrorAction SilentlyContinue | Add-Content -Path $Transcript
  Get-Content -Path $Stderr -Raw -ErrorAction SilentlyContinue | Add-Content -Path $Transcript

  if ($Status -ne $ExpectedStatus) {
    Write-Error "expected status $ExpectedStatus, got $Status; stdout=$Stdout stderr=$Stderr"
  }
}

function Assert-FileContains {
  param([string]$Path, [string]$Needle)

  $Content = Get-Content -Path $Path -Raw
  if (-not $Content.Contains($Needle)) {
    Write-Error "expected $Path to contain '$Needle'"
  }
}

try {
  Initialize-E2E
  $Traphouse = Copy-TraphouseFixture
  $Workflows = Join-Path $Traphouse "workflows"
  $SimpleYaml = Join-Path $Workflows "simple.yaml"
  $SimpleJson = Join-Path $Workflows "simple.json"
  $SimpleToml = Join-Path $Workflows "simple.toml"

  $VersionOut = Invoke-TwelvgaigeOk "version"
  Assert-FileContains $VersionOut "."

  Invoke-TwelvgaigeOk "shell" "validate" $SimpleYaml | Out-Null
  Invoke-TwelvgaigeOk "shell" "validate" $SimpleJson | Out-Null
  Invoke-TwelvgaigeOk "shell" "validate" $SimpleToml | Out-Null

  $Normalized = Invoke-TwelvgaigeOk "shell" "normalize" $SimpleToml "--format" "json"
  $NormalizedPath = Join-Path $E2ETmp "normalized.json"
  Copy-Item -Force $Normalized $NormalizedPath
  Invoke-TwelvgaigeOk "shell" "validate" $NormalizedPath | Out-Null

  $ConvertedToml = Invoke-TwelvgaigeOk "shell" "convert" $SimpleYaml "--to" "toml"
  $ConvertedTomlPath = Join-Path $E2ETmp "converted.toml"
  Copy-Item -Force $ConvertedToml $ConvertedTomlPath
  Invoke-TwelvgaigeOk "shell" "validate" $ConvertedTomlPath | Out-Null

  $ConvertedYaml = Invoke-TwelvgaigeOk "shell" "convert" $SimpleToml "--to" "yaml"
  $ConvertedYamlPath = Join-Path $E2ETmp "converted.yaml"
  Copy-Item -Force $ConvertedYaml $ConvertedYamlPath
  Invoke-TwelvgaigeOk "shell" "validate" $ConvertedYamlPath | Out-Null

  Invoke-TwelvgaigeOk "shell" "graph" $SimpleYaml "--format" "json" | Out-Null
  Invoke-TwelvgaigeOk "shell" "lint" $SimpleYaml "--strict" "--format" "json" | Out-Null

  Invoke-TwelvgaigeOk "round" "run" $SimpleYaml | Out-Null
  Invoke-TwelvgaigeOk "round" "run" $SimpleJson | Out-Null
  Invoke-TwelvgaigeOk "round" "run" $SimpleToml | Out-Null

  Invoke-TwelvgaigeFail 6 "round" "run" (Join-Path $Workflows "missing.yaml")
  Invoke-TwelvgaigeFail 4 "round" "run" $SimpleYaml "--input" "{"

  "windows cli e2e passed" | Write-Host
  $Success = $true
} finally {
  if ($Success -and $env:TWELVGAIGE_E2E_KEEP -ne "1") {
    Remove-Item -Recurse -Force $E2ETmp -ErrorAction SilentlyContinue
  } else {
    "e2e artifacts kept at $E2ETmp" | Write-Warning
  }
}
