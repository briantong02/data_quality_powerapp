<#
.SYNOPSIS
    Lints .pa.yaml sources for plain-scalar hazards before packing.

.DESCRIPTION
    Power Apps writes formulas as YAML scalars. An UNQUOTED (plain) scalar may not
    contain ": " (colon-space) — YAML reads that as a key/value mapping separator and
    fails with:

        error PA1001 : YamlInvalidSyntax;
        Reason: While scanning a plain scalar value, found invalid mapping.

    This bites constantly in Power Fx because record literals are written {Key: Value},
    so anything like

        OnChange: =UpdateContext({locPage: 1})

    is invalid YAML. The fix is a block scalar:

        OnChange: |
          =UpdateContext({locPage: 1})

    Block scalars are exempt: everything under "|" is literal text, colons included.

    Also flagged: " #" (starts a YAML comment mid-scalar) and a trailing ":".

    NOTE: 'pac canvas pack' does NOT parse .pa.yaml — it packs invalid YAML without
    complaint, and the failure only surfaces when Power Apps Studio opens the .msapp.
    Run this first.

.EXAMPLE
    .\tools\Test-PaYaml.ps1
    .\tools\Test-PaYaml.ps1 -Path .\src\Src -Quiet
#>
[CmdletBinding()]
param(
    [string] $Path,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated inside a param() default under Windows
# PowerShell 5.1, so resolve the default here instead.
if (-not $Path) {
    $root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $Path = Join-Path $root '..\src\Src'
}
$Path = (Resolve-Path $Path).Path

$files = Get-ChildItem -Path $Path -Filter *.pa.yaml -File | Sort-Object Name
if (-not $files) { Write-Error "No .pa.yaml files found under $Path"; exit 2 }

$totalBad = 0
$report = @()

foreach ($file in $files) {
    $lines = Get-Content -LiteralPath $file.FullName
    $bad = @()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]

        # Only inspect property lines whose value is an inline formula: "Name: =..."
        # Block scalars ("Name: |") are safe by definition and are skipped here.
        if ($line -notmatch '^\s+[A-Za-z][A-Za-z0-9]*:\s+=') { continue }

        $value = $line -replace '^\s+[A-Za-z][A-Za-z0-9]*:\s+', ''

        $reasons = @()
        if ($value -match ':\s')  { $reasons += 'colon-space' }
        if ($value -match ':$')   { $reasons += 'trailing-colon' }
        if ($value -match '\s#')  { $reasons += 'space-hash' }

        if ($reasons.Count) {
            $bad += [pscustomobject]@{
                Line   = $i + 1
                Reason = ($reasons -join '+')
                Text   = $line.Trim()
            }
        }
    }

    $totalBad += $bad.Count
    $report += [pscustomobject]@{ File = $file.Name; Bad = $bad }
}

if (-not $Quiet) {
    Write-Host ''
    foreach ($entry in $report) {
        if ($entry.Bad.Count -eq 0) {
            Write-Host ("  {0,-30} OK" -f $entry.File) -ForegroundColor DarkGreen
        }
        else {
            Write-Host ("  {0,-30} {1} problem(s)" -f $entry.File, $entry.Bad.Count) -ForegroundColor Red
            foreach ($b in $entry.Bad) {
                Write-Host ("      line {0,-5} [{1}]  {2}" -f $b.Line, $b.Reason, $b.Text) -ForegroundColor DarkYellow
            }
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Indentation of a control block. A '- name:' at indent N must be followed by
# 'Control:' at N+4. Scripted edits have broken this three times; YAML then
# fails with "did not find expected key", which points at the line AFTER the
# real mistake, so catching it here saves a round trip through Studio.
# ---------------------------------------------------------------------------
$indentBad = @()
foreach ($file in $files) {
    if ($file.Name -eq '_EditorState.pa.yaml') { continue }
    $lines = Get-Content -LiteralPath $file.FullName
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -notmatch '^(\s*)-\s+[A-Za-z][A-Za-z0-9_]*:\s*$') { continue }
        $nameIndent = $Matches[1].Length
        # find the next non-blank, non-comment line
        $j = $i + 1
        while ($j -lt $lines.Count -and ($lines[$j].Trim() -eq '' -or $lines[$j] -match '^\s*#')) { $j++ }
        if ($j -ge $lines.Count) { continue }
        $nextIndent = ($lines[$j] -replace '^(\s*).*', '$1').Length
        if ($lines[$j] -match '^\s*Control:' -and $nextIndent -ne $nameIndent + 4) {
            $indentBad += [pscustomobject]@{
                File = $file.Name; Line = $j + 1
                Text = "control block indent: '- name:' at $nameIndent but 'Control:' at $nextIndent (expected $($nameIndent + 4))"
            }
        }
    }
}
if ($indentBad) {
    Write-Host "  Control block indentation problems:" -ForegroundColor Red
    foreach ($b in $indentBad) { Write-Host ("      {0}:{1}  {2}" -f $b.File, $b.Line, $b.Text) -ForegroundColor DarkYellow }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Control names must be unique across the WHOLE APP, not just within a screen.
# Studio reports this as: PA2110 An entity with name 'x' already exists.
# ---------------------------------------------------------------------------
$allNames = @()
foreach ($file in $files) {
    if ($file.Name -eq '_EditorState.pa.yaml') { continue }
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        if ($line -match '^\s+-\s+([A-Za-z][A-Za-z0-9_]*):\s*$') {
            $allNames += [pscustomobject]@{ Name = $Matches[1]; File = $file.Name; Line = $lineNo }
        }
    }
}
$dupeGroups = $allNames | Group-Object Name | Where-Object Count -gt 1

if ($dupeGroups) {
    Write-Host "  Duplicate control names (must be unique app-wide):" -ForegroundColor Red
    foreach ($g in $dupeGroups) {
        $where = ($g.Group | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', '
        Write-Host ("      {0}  ->  {1}" -f $g.Name, $where) -ForegroundColor DarkYellow
    }
    Write-Host ''
}

if ($totalBad -gt 0 -or $dupeGroups -or $indentBad) {
    if ($indentBad) {
        Write-Host "  $($indentBad.Count) control block(s) at the wrong indent. FAIL" -ForegroundColor Red
    }
    if ($totalBad -gt 0) {
        Write-Host "  $totalBad offending plain scalar(s). FAIL" -ForegroundColor Red
    }
    if ($dupeGroups) {
        Write-Host "  $($dupeGroups.Count) duplicated control name(s). FAIL" -ForegroundColor Red
    }
    Write-Host "  Fix: change 'Prop: =formula' to a block scalar 'Prop: |' with the formula on the next line, indented +2." -ForegroundColor DarkGray
    Write-Host "        and give every control a name unique across all screens." -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

Write-Host "  0 offending plain scalars, 0 duplicate names. PASS" -ForegroundColor Green
Write-Host ''
exit 0
