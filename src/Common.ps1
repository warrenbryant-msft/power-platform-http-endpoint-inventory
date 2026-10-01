$ErrorActionPreference = 'Stop'

function Get-PropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            if ([string]$key -ieq $Name) {
                return $InputObject[$key]
            }
        }
        return $null
    }

    $property = $InputObject.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1
    if ($property) {
        return $property.Value
    }

    return $null
}

function Get-NestedValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string[]]$Path
    )

    $current = $InputObject
    foreach ($segment in $Path) {
        $current = Get-PropertyValue -InputObject $current -Name $segment
        if ($null -eq $current) {
            return $null
        }
    }
    return $current
}

function ConvertFrom-PacJsonOutput {
    param([Parameter(Mandatory)][object[]]$Output)

    $text = $Output -join [Environment]::NewLine
    $jsonLine = $text -split '\r?\n' |
        Where-Object { $_ -match '^\s*[\[{]' } |
        Select-Object -First 1
    if ($null -eq $jsonLine) {
        throw 'PAC returned no JSON response.'
    }

    return $text.Substring($text.IndexOf($jsonLine)) |
        ConvertFrom-Json -Depth 100
}

function Invoke-PacJson {
    param(
        [Parameter(Mandatory)][System.Management.Automation.CommandInfo]$PacCommand,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = @(& $PacCommand.Name @Arguments 2>&1)
    if ($PacCommand.CommandType -eq 'Application' -and $LASTEXITCODE -ne 0) {
        throw ($output -join [Environment]::NewLine)
    }
    return ConvertFrom-PacJsonOutput -Output $output
}

function Test-DynamicExpression {
    param([AllowEmptyString()][string]$Value)

    return $Value -match '(?i)(@\{?|parameters\s*\(|variables\s*\(|trigger(?:body|outputs)?\s*\(|outputs\s*\(|items\s*\(|concat(?:enate)?\s*\()'
}

function Remove-SensitiveUrlParts {
    param(
        [AllowEmptyString()][string]$Value,
        [switch]$RedactDynamicExpression
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    if ($RedactDynamicExpression -and
        $Value -notmatch '^https?://' -and
        (Test-DynamicExpression -Value $Value)) {
        return '@{<dynamic expression>}'
    }

    $fragmentIndex = $Value.IndexOf('#')
    if ($fragmentIndex -ge 0) {
        $Value = $Value.Substring(0, $fragmentIndex)
    }

    $queryIndex = $Value.IndexOf('?')
    if ($queryIndex -ge 0) {
        return "$($Value.Substring(0, $queryIndex))?<redacted>"
    }

    return $Value
}

function Test-PathInsideGitWorktree {
    param([Parameter(Mandatory)][string]$Path)

    $current = if (Test-Path -LiteralPath $Path -PathType Container) {
        (Resolve-Path -LiteralPath $Path).Path
    } else {
        Split-Path -Parent $Path
    }
    if ([string]::IsNullOrWhiteSpace($current)) {
        $current = (Get-Location).Path
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $true
        }
        $parent = Split-Path -Parent $current
        if ($parent -eq $current) {
            break
        }
        $current = $parent
    }
    return $false
}

function Write-InventoryCsv {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowOutputInGitWorktree
    )

    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $AllowOutputInGitWorktree -and
        (Test-PathInsideGitWorktree -Path $resolvedPath)) {
        throw "Refusing to write endpoint inventory inside a Git worktree: $resolvedPath. Choose a protected output directory or use -AllowOutputInGitWorktree."
    }

    $parent = Split-Path -Parent $resolvedPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($Rows.Count -gt 0) {
        $Rows | Export-Csv -LiteralPath $resolvedPath -NoTypeInformation -Encoding utf8
        return $resolvedPath
    }

    [IO.File]::WriteAllText(
        $resolvedPath,
        (($Headers | ForEach-Object { '"' + $_ + '"' }) -join ',') + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    return $resolvedPath
}
