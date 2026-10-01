<#
.SYNOPSIS
Exports a combined HTTP endpoint inventory for cloud flows and canvas apps.

.DESCRIPTION
Runs the workload-specific scanners through the active PAC CLI authentication
profile and writes three reports:

- PowerAutomateHttpEndpoints.csv
- PowerAppsHttpEndpoints.csv
- PowerPlatformHttpEndpoints.csv

The combined report normalizes resource identity, connector, location, endpoint,
classification, and suggested allow pattern across both workloads.

.EXAMPLE
.\scripts\Export-PowerPlatformHttpEndpointInventory.ps1 `
    -EnvironmentName 00000000-0000-0000-0000-000000000000 `
    -OutputDirectory C:\ProtectedAdminData\HttpEndpointInventory
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$EnvironmentName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [switch]$IncludeNoEndpointRows,

    [switch]$AllowPartialResults,

    [switch]$AllowOutputInGitWorktree
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'src\Common.ps1')

$resolvedOutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
    $OutputDirectory
)
if (-not $AllowOutputInGitWorktree -and
    (Test-PathInsideGitWorktree -Path $resolvedOutputDirectory)) {
    throw "Refusing to write endpoint inventory inside a Git worktree: $resolvedOutputDirectory. Choose a protected output directory or use -AllowOutputInGitWorktree."
}
New-Item -ItemType Directory -Path $resolvedOutputDirectory -Force | Out-Null

$flowReportPath = Join-Path $resolvedOutputDirectory 'PowerAutomateHttpEndpoints.csv'
$appReportPath = Join-Path $resolvedOutputDirectory 'PowerAppsHttpEndpoints.csv'
$combinedReportPath = Join-Path $resolvedOutputDirectory 'PowerPlatformHttpEndpoints.csv'

$flowScript = Join-Path $PSScriptRoot 'Export-PowerAutomateHttpEndpoints.ps1'
$appScript = Join-Path $PSScriptRoot 'Export-PowerAppsHttpEndpoints.ps1'

$flowRows = @(
    & $flowScript `
        -UsePacCli `
        -EnvironmentName $EnvironmentName `
        -OutputPath $flowReportPath `
        -IncludeNoEndpointRows:$IncludeNoEndpointRows `
        -AllowPartialResults:$AllowPartialResults `
        -AllowOutputInGitWorktree:$AllowOutputInGitWorktree
)
$appRows = @(
    & $appScript `
        -UsePacCli `
        -EnvironmentName $EnvironmentName `
        -OutputPath $appReportPath `
        -AllowPartialResults:$AllowPartialResults `
        -AllowOutputInGitWorktree:$AllowOutputInGitWorktree
)

$combinedRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $flowRows) {
    $combinedRows.Add([pscustomobject][ordered]@{
        EnvironmentName       = $row.EnvironmentName
        ResourceType          = 'CloudFlow'
        ResourceId            = $row.FlowName
        ResourceName          = $row.DisplayName
        State                 = $row.State
        LastModified          = $row.LastModified
        Owner                 = $row.Owner
        Connector             = $row.Connector
        ConnectorId           = $row.ConnectorId
        OperationId           = $row.OperationId
        Location              = $row.ActionPath
        Parameter             = $row.EndpointParameter
        ConfiguredEndpoint    = $row.ConfiguredEndpoint
        Classification        = $row.Classification
        StaticHost            = $row.StaticHost
        SuggestedAllowPattern = $row.SuggestedAllowPattern
        ResolutionStatus      = 'ConfiguredDefinition'
        SourcePath            = $row.SourcePath
    })
}
foreach ($row in $appRows) {
    $combinedRows.Add([pscustomobject][ordered]@{
        EnvironmentName       = $row.EnvironmentName
        ResourceType          = 'CanvasApp'
        ResourceId            = $row.AppId
        ResourceName          = $row.AppName
        State                 = ''
        LastModified          = ''
        Owner                 = ''
        Connector             = $row.Connector
        ConnectorId           = $row.ConnectorId
        OperationId           = $row.OperationId
        Location              = $row.FormulaPath
        Parameter             = $row.DataSourceName
        ConfiguredEndpoint    = $row.ConfiguredEndpoint
        Classification        = $row.Classification
        StaticHost            = $row.StaticHost
        SuggestedAllowPattern = $row.SuggestedAllowPattern
        ResolutionStatus      = $row.ResolutionStatus
        SourcePath            = $row.SourcePath
    })
}

$headers = @(
    'EnvironmentName', 'ResourceType', 'ResourceId', 'ResourceName', 'State',
    'LastModified', 'Owner', 'Connector', 'ConnectorId', 'OperationId',
    'Location', 'Parameter', 'ConfiguredEndpoint', 'Classification', 'StaticHost',
    'SuggestedAllowPattern', 'ResolutionStatus', 'SourcePath'
)
$writtenPath = Write-InventoryCsv `
    -Rows @($combinedRows) `
    -Headers $headers `
    -Path $combinedReportPath `
    -AllowOutputInGitWorktree:$AllowOutputInGitWorktree

Write-Verbose "Wrote $($combinedRows.Count) combined endpoint rows to $writtenPath"
$combinedRows
