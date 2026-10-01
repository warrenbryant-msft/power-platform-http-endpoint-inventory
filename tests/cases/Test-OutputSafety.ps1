[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path (Split-Path -Parent $PSScriptRoot) -Parent
. (Join-Path $repositoryRoot 'src\Common.ps1')

$blockedPath = Join-Path $repositoryRoot 'blocked-endpoint-report.csv'
$wasBlocked = $false
try {
    Write-InventoryCsv `
        -Rows @() `
        -Headers @('ConfiguredEndpoint') `
        -Path $blockedPath | Out-Null
} catch {
    if ($_.Exception.Message -match 'Refusing to write endpoint inventory inside a Git worktree') {
        $wasBlocked = $true
    } else {
        throw
    }
} finally {
    if (Test-Path -LiteralPath $blockedPath) {
        Remove-Item -LiteralPath $blockedPath -Force
    }
}

if (-not $wasBlocked) {
    throw 'Git worktree output safety check did not block the report.'
}

Write-Output 'PASS: Git worktree output safety validated.'
