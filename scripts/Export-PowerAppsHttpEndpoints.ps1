<#
.SYNOPSIS
Exports HTTP endpoint usage from Power Apps canvas-app source.

.DESCRIPTION
Scans PAC-extracted canvas app source for HTTP with Microsoft Entra ID and
related HTTP connector calls. It correlates connection references, data sources,
and Power Fx formulas to resolve static URLs, relative URLs, and dynamic paths.

Source mode scans an existing directory created by:

  pac canvas download --name <app-id> --extract-to-directory <directory>

PAC mode inventories apps in one or more environments, downloads only apps whose
admin metadata contains an HTTP-family connector, scans them, and removes the
temporary source. No app is modified or executed.

Query strings and dynamic expressions are redacted in the report. Relative URLs
can only be fully resolved when the app source or admin metadata exposes the
connection's base resource URL.

This script covers canvas apps using HTTP-family connectors. It doesn't inventory
code apps, browser fetch calls, Launch() navigation, or custom connectors. Custom
connectors require a separate scan of their OpenAPI server/host definitions.

.EXAMPLE
.\scripts\Export-PowerAppsHttpEndpoints.ps1 `
    -SourcePath .\extracted-app `
    -OutputPath C:\ProtectedAdminData\PowerAppsHttpEndpoints.csv

.EXAMPLE
.\scripts\Export-PowerAppsHttpEndpoints.ps1 `
    -UsePacCli `
    -EnvironmentName 00000000-0000-0000-0000-000000000000 `
    -OutputPath C:\ProtectedAdminData\PowerAppsHttpEndpoints.csv
#>
[CmdletBinding(DefaultParameterSetName = 'Source')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Source')]
    [ValidateNotNullOrEmpty()]
    [string[]]$SourcePath,

    [Parameter(Mandatory, ParameterSetName = 'Pac')]
    [switch]$UsePacCli,

    [Parameter(Mandatory, ParameterSetName = 'Pac')]
    [ValidateNotNullOrEmpty()]
    [string[]]$EnvironmentName,

    [Parameter(ParameterSetName = 'Source')]
    [string]$AppName,

    [Parameter(ParameterSetName = 'Source')]
    [string]$AppId,

    [Parameter(ParameterSetName = 'Source')]
    [string]$SourceEnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [switch]$AllowPartialResults,

    [switch]$AllowOutputInGitWorktree
)

$ErrorActionPreference = 'Stop'
$script:AcquisitionErrors = [System.Collections.Generic.List[object]]::new()

$commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Common.ps1'
. $commonPath

function Test-HttpConnectorId {
    param([AllowEmptyString()][string]$ConnectorId)

    return $ConnectorId -match '(?i)(shared_webcontentsv2|shared_webcontents|shared_http|shared_webhook|/apis/http(?:$|/))'
}

function Get-EndpointClassification {
    param(
        [AllowEmptyString()][string]$Endpoint,
        [bool]$IsDynamic
    )

    if ($Endpoint -match '^(?<scheme>https?)://(?<authority>[^/?#]+)') {
        $staticHost = "$($Matches.scheme)://$($Matches.authority)"
        return [pscustomobject]@{
            Classification        = $(if ($IsDynamic) { 'StaticHostDynamicPath' } else { 'Static' })
            StaticHost            = $staticHost
            SuggestedAllowPattern = "$staticHost/*"
        }
    }

    return [pscustomobject]@{
        Classification        = $(if ($IsDynamic) { 'Dynamic' } else { 'RelativeStatic' })
        StaticHost            = ''
        SuggestedAllowPattern = ''
    }
}

function Get-UrlValues {
    param(
        [AllowNull()][object]$Node,
        [string]$Path = 'root'
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [string]) {
        if ($Node -match '^https?://') {
            [pscustomobject]@{ Path = $Path; Value = $Node }
        }
        return
    }

    if ($Node -is [ValueType]) {
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [System.Collections.IDictionary] -and
        $Node.PSObject.TypeNames -notcontains 'System.Management.Automation.PSCustomObject') {
        $index = 0
        foreach ($item in $Node) {
            Get-UrlValues -Node $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    foreach ($property in $Node.PSObject.Properties) {
        if ($property.Name -match '^https?://') {
            [pscustomobject]@{ Path = "$Path.$($property.Name)"; Value = $property.Name }
        }
        Get-UrlValues -Node $property.Value -Path "$Path.$($property.Name)"
    }
}

function ConvertFrom-JsonString {
    param([AllowNull()][object]$Value)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    try {
        return $Value | ConvertFrom-Json -Depth 100
    } catch {
        return $null
    }
}

function Get-ConnectionDescriptors {
    param(
        [AllowNull()][object]$Properties,
        [AllowNull()][object]$AdminApp
    )

    $descriptors = [System.Collections.Generic.List[object]]::new()

    $localReferences = ConvertFrom-JsonString (
        Get-PropertyValue -InputObject $Properties -Name 'LocalConnectionReferences'
    )
    if ($null -ne $localReferences) {
        foreach ($reference in $localReferences.PSObject.Properties) {
            $value = $reference.Value
            $connectionRef = Get-PropertyValue -InputObject $value -Name 'connectionRef'
            $connectorId = [string](Get-PropertyValue -InputObject $connectionRef -Name 'id')
            if (-not (Test-HttpConnectorId -ConnectorId $connectorId)) {
                continue
            }

            $baseUrl = @(
                Get-UrlValues -Node (Get-PropertyValue -InputObject $connectionRef -Name 'parameterHints')
                Get-UrlValues -Node (Get-PropertyValue -InputObject $value -Name 'datasets')
            ) | Select-Object -ExpandProperty Value -First 1

            $descriptors.Add([pscustomobject]@{
                ReferenceId = $reference.Name
                ConnectorId = $connectorId
                DisplayName = [string](Get-PropertyValue -InputObject $connectionRef -Name 'displayName')
                BaseUrl     = [string]$baseUrl
            })
        }
    }

    $adminReferences = Get-NestedValue -InputObject $AdminApp -Path @('properties', 'connectionReferences')
    if ($null -ne $adminReferences) {
        foreach ($reference in $adminReferences.PSObject.Properties) {
            $value = $reference.Value
            $connectorId = [string](Get-PropertyValue -InputObject $value -Name 'id')
            if (-not (Test-HttpConnectorId -ConnectorId $connectorId)) {
                continue
            }

            $baseUrl = @(
                Get-UrlValues -Node (Get-PropertyValue -InputObject $value -Name 'parameterHints')
                Get-UrlValues -Node (Get-PropertyValue -InputObject $value -Name 'dataSets')
            ) | Select-Object -ExpandProperty Value -First 1

            $existing = $descriptors |
                Where-Object { $_.ReferenceId -eq $reference.Name } |
                Select-Object -First 1
            if ($existing) {
                if ([string]::IsNullOrWhiteSpace($existing.BaseUrl)) {
                    $existing.BaseUrl = [string]$baseUrl
                }
                continue
            }

            $descriptors.Add([pscustomobject]@{
                ReferenceId = $reference.Name
                ConnectorId = $connectorId
                DisplayName = [string](Get-PropertyValue -InputObject $value -Name 'displayName')
                BaseUrl     = [string]$baseUrl
            })
        }
    }

    return $descriptors
}

function Get-DataSourceDescriptors {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Connections
    )

    $dataSourcesFile = Get-ChildItem -LiteralPath $RootPath -Recurse -File -Filter 'DataSources.json' |
        Select-Object -First 1
    if (-not $dataSourcesFile) {
        return
    }

    $document = Get-Content -LiteralPath $dataSourcesFile.FullName -Raw |
        ConvertFrom-Json -Depth 100
    foreach ($dataSource in @(Get-PropertyValue -InputObject $document -Name 'DataSources')) {
        $connectorId = [string](Get-PropertyValue -InputObject $dataSource -Name 'ApiId')
        if (-not (Test-HttpConnectorId -ConnectorId $connectorId)) {
            continue
        }

        $connection = $Connections |
            Where-Object { $_.ConnectorId -ieq $connectorId } |
            Select-Object -First 1
        $datasetName = [string](Get-PropertyValue -InputObject $dataSource -Name 'DatasetName')
        $baseUrl = if ($datasetName -match '^https?://') {
            $datasetName
        } elseif ($connection) {
            $connection.BaseUrl
        } else {
            ''
        }

        [pscustomobject]@{
            Name         = [string](Get-PropertyValue -InputObject $dataSource -Name 'Name')
            ConnectorId  = $connectorId
            Connector    = $(if ($connectorId -match '(?i)webcontentsv2') {
                    'HTTP with Microsoft Entra ID'
                } elseif ($connectorId -match '(?i)webcontents') {
                    'HTTP with Microsoft Entra ID (preauthorized)'
                } elseif ($connectorId -match '(?i)webhook') {
                    'HTTP Webhook'
                } else {
                    'HTTP'
                })
            ReferenceId  = $(if ($connection) { $connection.ReferenceId } else { '' })
            BaseUrl      = [string]$baseUrl
        }
    }
}

function Get-FormulaStrings {
    param([Parameter(Mandatory)][string]$RootPath)

    foreach ($file in Get-ChildItem -LiteralPath $RootPath -Recurse -File) {
        $relativePath = $file.FullName.Substring($RootPath.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        if ($file.Extension -in @('.yaml', '.yml')) {
            [pscustomobject]@{
                Path    = $relativePath
                Formula = Get-Content -LiteralPath $file.FullName -Raw
            }
            continue
        }

        if ($file.Extension -ne '.json') {
            continue
        }

        try {
            $document = Get-Content -LiteralPath $file.FullName -Raw |
                ConvertFrom-Json -Depth 100
        } catch {
            continue
        }

        function Visit-FormulaNode {
            param(
                [AllowNull()][object]$Node,
                [string]$Path = 'root'
            )

            if ($null -eq $Node -or $Node -is [ValueType]) {
                return
            }
            if ($Node -is [string]) {
                return
            }
            if ($Node -is [System.Collections.IEnumerable] -and
                $Node -isnot [System.Collections.IDictionary] -and
                $Node.PSObject.TypeNames -notcontains 'System.Management.Automation.PSCustomObject') {
                $index = 0
                foreach ($item in $Node) {
                    Visit-FormulaNode -Node $item -Path "$Path[$index]"
                    $index++
                }
                return
            }

            foreach ($property in $Node.PSObject.Properties) {
                if ($property.Value -is [string] -and
                    $property.Name -match '(?i)(InvariantScript|AutoRuleBindingString|Formula|Rule|Expression)') {
                    [pscustomobject]@{
                        Path    = "$relativePath`:$Path.$($property.Name)"
                        Formula = $property.Value
                    }
                }
                Visit-FormulaNode -Node $property.Value -Path "$Path.$($property.Name)"
            }
        }

        Visit-FormulaNode -Node $document
    }
}

function Get-CallArgumentText {
    param(
        [Parameter(Mandatory)][string]$Formula,
        [Parameter(Mandatory)][int]$OpenParenthesisIndex
    )

    $depth = 0
    $inString = $false
    for ($index = $OpenParenthesisIndex; $index -lt $Formula.Length; $index++) {
        $character = $Formula[$index]
        if ($character -eq '"') {
            if ($inString -and $index + 1 -lt $Formula.Length -and $Formula[$index + 1] -eq '"') {
                $index++
                continue
            }
            $inString = -not $inString
            continue
        }
        if ($inString) {
            continue
        }
        if ($character -eq '(') {
            $depth++
        } elseif ($character -eq ')') {
            $depth--
            if ($depth -eq 0) {
                return $Formula.Substring(
                    $OpenParenthesisIndex + 1,
                    $index - $OpenParenthesisIndex - 1
                )
            }
        }
    }

    return $null
}

function Split-PowerFxArguments {
    param([Parameter(Mandatory)][string]$ArgumentText)

    $arguments = [System.Collections.Generic.List[string]]::new()
    $start = 0
    $depth = 0
    $inString = $false
    for ($index = 0; $index -lt $ArgumentText.Length; $index++) {
        $character = $ArgumentText[$index]
        if ($character -eq '"') {
            if ($inString -and $index + 1 -lt $ArgumentText.Length -and $ArgumentText[$index + 1] -eq '"') {
                $index++
                continue
            }
            $inString = -not $inString
            continue
        }
        if ($inString) {
            continue
        }
        if ($character -eq '(' -or $character -eq '{' -or $character -eq '[') {
            $depth++
        } elseif ($character -eq ')' -or $character -eq '}' -or $character -eq ']') {
            $depth--
        } elseif ($character -eq ',' -and $depth -eq 0) {
            $arguments.Add($ArgumentText.Substring($start, $index - $start).Trim())
            $start = $index + 1
        }
    }
    $arguments.Add($ArgumentText.Substring($start).Trim())
    return $arguments
}

function ConvertFrom-PowerFxString {
    param([Parameter(Mandatory)][string]$Expression)

    $trimmed = $Expression.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed[0] -eq '"' -and $trimmed[-1] -eq '"') {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace('""', '"')
    }
    return $null
}

function Get-PowerFxHttpCalls {
    param(
        [Parameter(Mandatory)][object]$FormulaRecord,
        [Parameter(Mandatory)][object]$DataSource
    )

    $escapedName = [regex]::Escape($DataSource.Name)
    $pattern = "(?i)(?:'$escapedName'|$escapedName)\s*\.\s*(?<operation>InvokeHttp|GetWebResource|HttpRequest)\s*\("
    foreach ($match in [regex]::Matches($FormulaRecord.Formula, $pattern)) {
        $openIndex = $match.Index + $match.Length - 1
        $argumentText = Get-CallArgumentText `
            -Formula $FormulaRecord.Formula `
            -OpenParenthesisIndex $openIndex
        if ($null -eq $argumentText) {
            continue
        }

        $arguments = @(Split-PowerFxArguments -ArgumentText $argumentText)
        $urlIndex = if ($match.Groups['operation'].Value -ieq 'GetWebResource') { 0 } else { 1 }
        if ($arguments.Count -le $urlIndex) {
            continue
        }

        [pscustomobject]@{
            Operation  = $match.Groups['operation'].Value
            Expression = $arguments[$urlIndex]
            FormulaPath = $FormulaRecord.Path
        }
    }
}

function ConvertTo-EndpointRow {
    param(
        [Parameter(Mandatory)][object]$Call,
        [Parameter(Mandatory)][object]$DataSource,
        [Parameter(Mandatory)][object]$App
    )

    $literal = ConvertFrom-PowerFxString -Expression $Call.Expression
    $isDynamic = $null -eq $literal
    $resolutionStatus = 'Resolved'

    if (-not $isDynamic) {
        $configuredEndpoint = $literal
        if ($configuredEndpoint -notmatch '^https?://' -and
            -not [string]::IsNullOrWhiteSpace($DataSource.BaseUrl)) {
            $configuredEndpoint = "$($DataSource.BaseUrl.TrimEnd('/'))/$($configuredEndpoint.TrimStart('/'))"
        } elseif ($configuredEndpoint -notmatch '^https?://') {
            $resolutionStatus = 'BaseUrlUnresolved'
        }
    } else {
        $absolutePrefix = [regex]::Match($Call.Expression, '(?i)"(?<url>https?://[^"]+)"')
        if ($absolutePrefix.Success) {
            $configuredEndpoint = $absolutePrefix.Groups['url'].Value
        } elseif (-not [string]::IsNullOrWhiteSpace($DataSource.BaseUrl)) {
            $configuredEndpoint = "$($DataSource.BaseUrl.TrimEnd('/'))/<dynamic Power Fx expression>"
        } else {
            $configuredEndpoint = '<dynamic Power Fx expression>'
            $resolutionStatus = 'BaseUrlUnresolved'
        }
    }

    $sanitized = Remove-SensitiveUrlParts -Value $configuredEndpoint
    $classification = Get-EndpointClassification `
        -Endpoint $sanitized `
        -IsDynamic $isDynamic

    [pscustomobject][ordered]@{
        EnvironmentName       = $App.EnvironmentName
        ResourceType          = 'CanvasApp'
        AppId                 = $App.AppId
        AppName               = $App.AppName
        Connector             = $DataSource.Connector
        ConnectorId           = $DataSource.ConnectorId
        DataSourceName        = $DataSource.Name
        ConnectionReference   = $DataSource.ReferenceId
        OperationId           = $Call.Operation
        FormulaPath           = $Call.FormulaPath
        ConfiguredEndpoint    = $sanitized
        Classification        = $classification.Classification
        StaticHost            = $classification.StaticHost
        SuggestedAllowPattern = $classification.SuggestedAllowPattern
        ResolutionStatus      = $resolutionStatus
        SourcePath            = $App.SourcePath
    }
}

function Get-CanvasAppEndpointRows {
    param(
        [Parameter(Mandatory)][string]$RootPath,
        [AllowNull()][object]$AdminApp,
        [string]$Environment,
        [string]$OverrideAppName,
        [string]$OverrideAppId,
        [string]$SourceLabel
    )

    $resolvedRoot = (Resolve-Path -LiteralPath $RootPath).Path
    $propertiesFile = Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Filter 'Properties.json' |
        Select-Object -First 1
    $properties = if ($propertiesFile) {
        Get-Content -LiteralPath $propertiesFile.FullName -Raw |
            ConvertFrom-Json -Depth 100
    } else {
        $null
    }

    $resolvedAppName = $OverrideAppName
    if ([string]::IsNullOrWhiteSpace($resolvedAppName)) {
        $resolvedAppName = [string](Get-NestedValue -InputObject $AdminApp -Path @('properties', 'displayName'))
    }
    if ([string]::IsNullOrWhiteSpace($resolvedAppName)) {
        $resolvedAppName = [string](Get-PropertyValue -InputObject $properties -Name 'Name')
    }

    $resolvedAppId = $OverrideAppId
    if ([string]::IsNullOrWhiteSpace($resolvedAppId)) {
        $resolvedAppId = [string](Get-PropertyValue -InputObject $AdminApp -Name 'name')
    }
    if ([string]::IsNullOrWhiteSpace($resolvedAppId)) {
        $resolvedAppId = [string](Get-PropertyValue -InputObject $properties -Name 'Id')
    }

    $appRecord = [pscustomobject]@{
        EnvironmentName = $Environment
        AppId           = $resolvedAppId
        AppName         = $resolvedAppName
        SourcePath      = $(if ([string]::IsNullOrWhiteSpace($SourceLabel)) {
                $resolvedRoot
            } else {
                $SourceLabel
            })
    }
    $connections = @(
        Get-ConnectionDescriptors -Properties $properties -AdminApp $AdminApp
    )
    $dataSources = @(
        Get-DataSourceDescriptors -RootPath $resolvedRoot -Connections $connections
    )
    $formulas = @(Get-FormulaStrings -RootPath $resolvedRoot)

    $seen = @{}
    foreach ($dataSource in $dataSources) {
        foreach ($formula in $formulas) {
            foreach ($call in @(Get-PowerFxHttpCalls -FormulaRecord $formula -DataSource $dataSource)) {
                $row = ConvertTo-EndpointRow -Call $call -DataSource $dataSource -App $appRecord
                $key = "$($row.AppId)|$($row.DataSourceName)|$($row.OperationId)|$($row.FormulaPath)|$($row.ConfiguredEndpoint)"
                if ($seen.ContainsKey($key)) {
                    continue
                }
                $seen[$key] = $true
                $row
            }
        }
    }
}

function Get-SkipToken {
    param([AllowEmptyString()][string]$NextLink)

    if ([string]::IsNullOrWhiteSpace($NextLink)) {
        return $null
    }
    $match = [regex]::Match($NextLink, '(?:\?|&)(?:%24|\$)skiptoken=([^&]+)', 'IgnoreCase')
    if (-not $match.Success) {
        return $null
    }
    return [uri]::UnescapeDataString($match.Groups[1].Value)
}

function Get-PacAdminApps {
    param(
        [Parameter(Mandatory)][System.Management.Automation.CommandInfo]$PacCommand,
        [Parameter(Mandatory)][string]$Environment
    )

    $skipToken = $null
    do {
        $arguments = [System.Collections.Generic.List[string]]::new()
        foreach ($value in @(
                'power-apps', 'get-admin-apps',
                '--environment', $Environment,
                '--top', '100',
                '--json'
            )) {
            $arguments.Add($value)
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken)) {
            $arguments.Add('--skiptoken')
            $arguments.Add($skipToken)
        }

        $page = Invoke-PacJson -PacCommand $PacCommand -Arguments $arguments
        foreach ($app in @($page.value)) {
            $app
        }
        $skipToken = Get-SkipToken -NextLink ([string]$page.nextLink)
    } while (-not [string]::IsNullOrWhiteSpace($skipToken))
}

function Get-PacCanvasEndpointRows {
    param([Parameter(Mandatory)][string[]]$Environments)

    $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pacCommand) {
        throw 'Power Platform CLI (pac) is required for -UsePacCli.'
    }

    foreach ($environment in $Environments) {
        Write-Verbose "Enumerating Power Apps in environment '$environment'"
        try {
            $apps = @(Get-PacAdminApps -PacCommand $pacCommand -Environment $environment)
        } catch {
            $script:AcquisitionErrors.Add([pscustomobject]@{
                EnvironmentName = $environment
                AppId           = ''
                Error           = $_.Exception.Message
            })
            continue
        }

        foreach ($appSummary in $apps) {
            $appId = [string](Get-PropertyValue -InputObject $appSummary -Name 'name')
            try {
                $detail = Invoke-PacJson -PacCommand $pacCommand -Arguments @(
                    'power-apps', 'get-admin-app',
                    '--environment', $environment,
                    '--app', $appId,
                    '--json'
                )
                $references = Get-NestedValue -InputObject $detail -Path @('properties', 'connectionReferences')
                $httpReferences = @(
                    $references.PSObject.Properties |
                        Where-Object {
                            Test-HttpConnectorId -ConnectorId ([string]$_.Value.id)
                        }
                )
                if ($httpReferences.Count -eq 0) {
                    continue
                }

                $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pp-http-inventory-canvas-$([Guid]::NewGuid())"
                try {
                    New-Item -ItemType Directory -Path $tempRoot | Out-Null
                    $sourceDirectory = Join-Path $tempRoot 'source'
                    $downloadOutput = @(
                        & $pacCommand.Name canvas download `
                            --environment $environment `
                            --name $appId `
                            --extract-to-directory $sourceDirectory `
                            --overwrite 2>&1
                    )
                    if ($pacCommand.CommandType -eq 'Application' -and $LASTEXITCODE -ne 0) {
                        throw ($downloadOutput -join [Environment]::NewLine)
                    }

                    Get-CanvasAppEndpointRows `
                        -RootPath $sourceDirectory `
                        -AdminApp $detail `
                        -Environment $environment `
                        -OverrideAppName ([string]$detail.properties.displayName) `
                        -OverrideAppId $appId `
                        -SourceLabel 'pac canvas download'
                } finally {
                    if (Test-Path -LiteralPath $tempRoot) {
                        Remove-Item -LiteralPath $tempRoot -Recurse -Force
                    }
                }
            } catch {
                $script:AcquisitionErrors.Add([pscustomobject]@{
                    EnvironmentName = $environment
                    AppId           = $appId
                    Error           = $_.Exception.Message
                })
            }
        }
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Source') {
    $rows = @(
        foreach ($path in $SourcePath) {
            Get-CanvasAppEndpointRows `
                -RootPath $path `
                -Environment $SourceEnvironmentName `
                -OverrideAppName $AppName `
                -OverrideAppId $AppId
        }
    )
} else {
    $rows = @(Get-PacCanvasEndpointRows -Environments $EnvironmentName)
}

$headers = @(
    'EnvironmentName', 'ResourceType', 'AppId', 'AppName', 'Connector',
    'ConnectorId', 'DataSourceName', 'ConnectionReference', 'OperationId',
    'FormulaPath', 'ConfiguredEndpoint', 'Classification', 'StaticHost',
    'SuggestedAllowPattern', 'ResolutionStatus', 'SourcePath'
)
$writtenPath = Write-InventoryCsv `
    -Rows $rows `
    -Headers $headers `
    -Path $OutputPath `
    -AllowOutputInGitWorktree:$AllowOutputInGitWorktree
Write-Verbose "Wrote $($rows.Count) Power Apps endpoint rows to $writtenPath"

if ($script:AcquisitionErrors.Count -gt 0) {
    $errorPath = "$writtenPath.errors.csv"
    $script:AcquisitionErrors |
        Export-Csv -LiteralPath $errorPath -NoTypeInformation -Encoding utf8
    $message = "Power Apps endpoint inventory is incomplete: $($script:AcquisitionErrors.Count) acquisition errors. See $errorPath."
    if (-not $AllowPartialResults) {
        throw $message
    }
    Write-Warning $message
}

$rows
