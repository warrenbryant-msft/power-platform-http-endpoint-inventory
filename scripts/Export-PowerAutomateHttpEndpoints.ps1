<#
.SYNOPSIS
Exports HTTP endpoint usage from Power Automate cloud-flow definitions.

.DESCRIPTION
Scans cloud-flow definitions for the built-in HTTP and HTTP Webhook actions and
connector-based HTTP operations such as HTTP with Microsoft Entra ID. The report
classifies each endpoint as static, static-host/dynamic-path, fully dynamic, or
relative and suggests a host-level allow pattern where one can be derived.

Live mode can use either the authenticated Power Platform CLI (recommended) or
the Microsoft.PowerApps.Administration.PowerShell module. Definition mode accepts
JSON containing a raw flow definition, a Get-AdminFlow response, or an array of
records with Definition, EnvironmentName, FlowName, and DisplayName properties.

The script deliberately excludes headers, bodies, and query-string values from
the report. It inventories configured definitions, not destinations reached in
run history. Dynamic endpoints require owner validation and might not be covered
by Power Platform connector endpoint filtering.

.EXAMPLE
.\scripts\Export-PowerAutomateHttpEndpoints.ps1 `
    -UsePacCli `
    -EnvironmentName 00000000-0000-0000-0000-000000000000 `
    -OutputPath C:\ProtectedAdminData\PowerAutomateHttpEndpoints.csv

Scans one environment by using the active PAC authentication profile. If
EnvironmentName is omitted, PAC uses the environment selected in that profile.

.EXAMPLE
Add-PowerAppsAccount
.\scripts\Export-PowerAutomateHttpEndpoints.ps1 `
    -UseAdminPowerShell `
    -EnvironmentName Default-00000000-0000-0000-0000-000000000000 `
    -OutputPath C:\ProtectedAdminData\PowerAutomateHttpEndpoints.csv

Scans one environment by using the legacy administration PowerShell module.

.EXAMPLE
.\scripts\Export-PowerAutomateHttpEndpoints.ps1 `
    -DefinitionPath .\exported-flow-definitions.json `
    -OutputPath C:\ProtectedAdminData\PowerAutomateHttpEndpoints.csv

Scans exported definitions without connecting to Power Platform.

.NOTES
Microsoft also provides Get-AdminFlowWithHttpAction, but that cmdlet only returns
flow IDs containing the built-in HTTP action. It doesn't produce endpoint URLs or
cover all connector-based HTTP operations, so this script scans full definitions.
Canvas apps are covered separately by Export-PowerAppsHttpEndpoints.ps1.
#>
[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Definition')]
    [ValidateNotNullOrEmpty()]
    [string[]]$DefinitionPath,

    [Parameter(ParameterSetName = 'Live')]
    [string[]]$EnvironmentName,

    [Parameter(ParameterSetName = 'Live')]
    [string[]]$FlowName,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$InteractiveLogin,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$UsePacCli,

    [Parameter(ParameterSetName = 'Live')]
    [switch]$UseAdminPowerShell,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [switch]$IncludeNoEndpointRows,

    [switch]$AllowPartialResults,

    [switch]$AllowOutputInGitWorktree
)

$ErrorActionPreference = 'Stop'
$script:AcquisitionErrors = [System.Collections.Generic.List[object]]::new()

$commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Common.ps1'
. $commonPath

function ConvertTo-FlowDefinition {
    param([AllowNull()][object]$FlowRecord)

    if ($null -eq $FlowRecord) {
        return $null
    }

    $definition = Get-PropertyValue -InputObject $FlowRecord -Name 'Definition'
    if ($null -eq $definition) {
        $definition = Get-NestedValue -InputObject $FlowRecord -Path @('properties', 'definition')
    }
    if ($null -eq $definition) {
        $definition = Get-NestedValue -InputObject $FlowRecord -Path @('Internal', 'properties', 'definition')
    }

    if ($null -eq $definition) {
        $actions = Get-PropertyValue -InputObject $FlowRecord -Name 'actions'
        $triggers = Get-PropertyValue -InputObject $FlowRecord -Name 'triggers'
        if ($null -ne $actions -or $null -ne $triggers) {
            $definition = $FlowRecord
        }
    }

    if ($definition -is [string]) {
        if ([string]::IsNullOrWhiteSpace($definition)) {
            return $null
        }
        return $definition | ConvertFrom-Json -Depth 100
    }

    return $definition
}

function ConvertTo-FlowRecord {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [string]$SourcePath
    )

    $internal = Get-PropertyValue -InputObject $InputObject -Name 'Internal'
    $properties = Get-PropertyValue -InputObject $InputObject -Name 'properties'

    $environment = Get-PropertyValue -InputObject $InputObject -Name 'EnvironmentName'
    if ([string]::IsNullOrWhiteSpace([string]$environment)) {
        $environment = Get-NestedValue -InputObject $internal -Path @('properties', 'environment', 'name')
    }

    $flowId = Get-PropertyValue -InputObject $InputObject -Name 'FlowName'
    if ([string]::IsNullOrWhiteSpace([string]$flowId)) {
        $flowId = Get-PropertyValue -InputObject $InputObject -Name 'name'
    }

    $displayName = Get-PropertyValue -InputObject $InputObject -Name 'DisplayName'
    if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
        $displayName = Get-PropertyValue -InputObject $properties -Name 'displayName'
    }
    if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
        $displayName = Get-NestedValue -InputObject $internal -Path @('properties', 'displayName')
    }

    $state = Get-PropertyValue -InputObject $InputObject -Name 'State'
    if ([string]::IsNullOrWhiteSpace([string]$state)) {
        $state = Get-PropertyValue -InputObject $properties -Name 'state'
    }
    if ([string]::IsNullOrWhiteSpace([string]$state)) {
        $state = Get-NestedValue -InputObject $internal -Path @('properties', 'state')
    }

    $lastModified = Get-PropertyValue -InputObject $InputObject -Name 'LastModifiedTime'
    if ($null -eq $lastModified) {
        $lastModified = Get-PropertyValue -InputObject $properties -Name 'lastModifiedTime'
    }
    if ($null -eq $lastModified) {
        $lastModified = Get-NestedValue -InputObject $internal -Path @('properties', 'lastModifiedTime')
    }

    $owner = Get-PropertyValue -InputObject $InputObject -Name 'Owner'
    if ([string]::IsNullOrWhiteSpace([string]$owner)) {
        $owner = Get-NestedValue -InputObject $InputObject -Path @('CreatedBy', 'userPrincipalName')
    }
    if ([string]::IsNullOrWhiteSpace([string]$owner)) {
        $owner = Get-NestedValue -InputObject $properties -Path @('creator', 'userPrincipalName')
    }
    if ([string]::IsNullOrWhiteSpace([string]$owner)) {
        $owner = Get-NestedValue -InputObject $internal -Path @('properties', 'creator', 'userPrincipalName')
    }

    [pscustomobject]@{
        EnvironmentName = [string]$environment
        FlowName        = [string]$flowId
        DisplayName     = [string]$displayName
        State           = [string]$state
        LastModified    = $lastModified
        Owner           = [string]$owner
        SourcePath      = $SourcePath
        Definition      = ConvertTo-FlowDefinition -FlowRecord $InputObject
    }
}

function Get-DefinitionRecordsFromPath {
    param([Parameter(Mandatory)][string[]]$Path)

    foreach ($itemPath in $Path) {
        $resolvedItems = Get-ChildItem -LiteralPath $itemPath -File -ErrorAction SilentlyContinue
        if (-not $resolvedItems -and (Test-Path -LiteralPath $itemPath -PathType Container)) {
            $resolvedItems = Get-ChildItem -LiteralPath $itemPath -File -Filter '*.json'
        }
        if (-not $resolvedItems) {
            throw "Definition path doesn't exist or contains no JSON files: $itemPath"
        }

        foreach ($file in $resolvedItems) {
            $json = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -Depth 100
            $records = @($json)
            $value = Get-PropertyValue -InputObject $json -Name 'value'
            if ($null -ne $value) {
                $records = @($value)
            }

            foreach ($record in $records) {
                ConvertTo-FlowRecord -InputObject $record -SourcePath $file.FullName
            }
        }
    }
}

function Get-LiveFlowRecords {
    param(
        [string[]]$RequestedEnvironments,
        [string[]]$RequestedFlows,
        [switch]$Login
    )

    $moduleName = 'Microsoft.PowerApps.Administration.PowerShell'
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "$moduleName isn't installed. Install it from an approved package source, or use -DefinitionPath for offline analysis."
    }
    Import-Module $moduleName -ErrorAction Stop

    if ($Login) {
        Add-PowerAppsAccount | Out-Null
    }

    $environmentIds = @($RequestedEnvironments)
    if ($environmentIds.Count -eq 0) {
        try {
            $environmentIds = @(
                Get-AdminPowerAppEnvironment |
                    ForEach-Object { $_.EnvironmentName } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
        } catch {
            throw "Unable to enumerate environments. Authenticate with Add-PowerAppsAccount or use -InteractiveLogin. $($_.Exception.Message)"
        }
    }

    foreach ($environmentId in $environmentIds) {
        Write-Verbose "Enumerating flows in environment $environmentId"
        try {
            if ($RequestedFlows.Count -gt 0) {
                $flows = foreach ($requestedFlow in $RequestedFlows) {
                    Get-AdminFlow -EnvironmentName $environmentId -FlowName $requestedFlow
                }
            } else {
                $flows = @(Get-AdminFlow -EnvironmentName $environmentId)
            }
        } catch {
            $script:AcquisitionErrors.Add([pscustomobject]@{
                EnvironmentName = $environmentId
                FlowName        = ''
                Error           = $_.Exception.Message
            })
            continue
        }

        foreach ($flow in @($flows)) {
            $flowId = Get-PropertyValue -InputObject $flow -Name 'FlowName'
            if ([string]::IsNullOrWhiteSpace([string]$flowId)) {
                $flowId = Get-PropertyValue -InputObject $flow -Name 'name'
            }

            try {
                $definition = ConvertTo-FlowDefinition -FlowRecord $flow
                if ($null -eq $definition -and -not [string]::IsNullOrWhiteSpace([string]$flowId)) {
                    $flow = Get-AdminFlow -EnvironmentName $environmentId -FlowName $flowId
                }
                $record = ConvertTo-FlowRecord -InputObject $flow
                if ([string]::IsNullOrWhiteSpace($record.EnvironmentName)) {
                    $record.EnvironmentName = $environmentId
                }
                $record
            } catch {
                $script:AcquisitionErrors.Add([pscustomobject]@{
                    EnvironmentName = $environmentId
                    FlowName        = [string]$flowId
                    Error           = $_.Exception.Message
                })
            }
        }
    }
}

function Get-PacFlowRecords {
    param(
        [string[]]$RequestedEnvironments,
        [string[]]$RequestedFlows
    )

    $pacCommand = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pacCommand) {
        throw 'Power Platform CLI (pac) is required when -UsePacCli is specified.'
    }

    $environmentIds = @($RequestedEnvironments)
    if ($environmentIds.Count -eq 0) {
        $environmentIds = @('')
    }

    foreach ($environmentId in $environmentIds) {
        $arguments = [System.Collections.Generic.List[string]]::new()
        $arguments.Add('power-automate')
        $arguments.Add('list-cloud-flows')
        if (-not [string]::IsNullOrWhiteSpace($environmentId)) {
            $arguments.Add('--environment')
            $arguments.Add($environmentId)
        }
        $arguments.Add('--json')

        Write-Verbose "Enumerating flows through PAC for environment '$environmentId'"
        try {
            $output = @(& $pacCommand.Name @arguments 2>&1)
            if ($pacCommand.CommandType -eq 'Application' -and $LASTEXITCODE -ne 0) {
                throw ($output -join [Environment]::NewLine)
            }
            $json = ConvertFrom-PacJsonOutput -Output $output
        } catch {
            $script:AcquisitionErrors.Add([pscustomobject]@{
                EnvironmentName = $environmentId
                FlowName        = ''
                Error           = $_.Exception.Message
            })
            continue
        }

        $flows = @($json)
        $value = Get-PropertyValue -InputObject $json -Name 'value'
        if ($null -ne $value) {
            $flows = @($value)
        }

        foreach ($flow in $flows) {
            $resourceId = [string](Get-PropertyValue -InputObject $flow -Name 'resourceId')
            $workflowId = [string](Get-PropertyValue -InputObject $flow -Name 'workflowId')
            $displayName = [string](Get-PropertyValue -InputObject $flow -Name 'name')

            if ($RequestedFlows.Count -gt 0 -and
                $resourceId -notin $RequestedFlows -and
                $workflowId -notin $RequestedFlows -and
                $displayName -notin $RequestedFlows) {
                continue
            }

            $state = Get-PropertyValue -InputObject $flow -Name 'stateCode'
            if ($null -eq $state) {
                $state = Get-PropertyValue -InputObject $flow -Name 'statusCode'
            }

            [pscustomobject]@{
                EnvironmentName = $environmentId
                FlowName        = $(if (-not [string]::IsNullOrWhiteSpace($resourceId)) { $resourceId } else { $workflowId })
                DisplayName     = $displayName
                State           = [string]$state
                LastModified    = Get-PropertyValue -InputObject $flow -Name 'modifiedOn'
                Owner           = [string](Get-PropertyValue -InputObject $flow -Name 'ownerId')
                SourcePath      = 'pac power-automate list-cloud-flows'
                Definition      = ConvertTo-FlowDefinition -FlowRecord $flow
            }
        }
    }
}

function Get-ObjectEntries {
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject -or $InputObject -is [string]) {
        return
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            [pscustomobject]@{ Name = [string]$key; Value = $InputObject[$key] }
        }
        return
    }

    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.MemberType -in @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) {
            [pscustomobject]@{ Name = $property.Name; Value = $property.Value }
        }
    }
}

function Get-HttpOperations {
    param(
        [AllowNull()]
        [object]$Node,

        [string]$Path = 'actions'
    )

    if ($null -eq $Node -or $Node -is [string]) {
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [System.Collections.IDictionary] -and
        $Node.PSObject.TypeNames -notcontains 'System.Management.Automation.PSCustomObject') {
        $index = 0
        foreach ($item in $Node) {
            Get-HttpOperations -Node $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    $type = [string](Get-PropertyValue -InputObject $Node -Name 'type')
    $inputs = Get-PropertyValue -InputObject $Node -Name 'inputs'
    if (-not [string]::IsNullOrWhiteSpace($type) -and $null -ne $inputs) {
        $apiId = [string](Get-NestedValue -InputObject $inputs -Path @('host', 'apiId'))
        $connectionName = [string](Get-NestedValue -InputObject $inputs -Path @('host', 'connectionName'))
        $operationId = [string](Get-NestedValue -InputObject $inputs -Path @('host', 'operationId'))
        $connectorIdentity = "$apiId $connectionName"

        $isHttp = $type -in @('Http', 'HttpWebhook') -or
            $connectorIdentity -match '(?i)(shared_webcontents|shared_http|shared_webhook|/apis/http(?:\s|$))'

        if ($isHttp) {
            $connector = 'HTTP'
            if ($type -eq 'HttpWebhook' -or $connectorIdentity -match '(?i)webhook') {
                $connector = 'HTTP Webhook'
            } elseif ($connectorIdentity -match '(?i)shared_webcontents') {
                $connector = 'HTTP with Microsoft Entra ID'
            } elseif ($type -notin @('Http', 'HttpWebhook')) {
                $connector = 'HTTP connector'
            }

            [pscustomobject]@{
                ActionPath     = $Path
                Type           = $type
                Connector      = $connector
                ConnectorId    = ($apiId, $connectionName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '
                OperationId    = $operationId
                Inputs         = $inputs
            }
        }
    }

    foreach ($entry in Get-ObjectEntries -InputObject $Node) {
        Get-HttpOperations -Node $entry.Value -Path "$Path.$($entry.Name)"
    }
}

function Get-EndpointLeaves {
    param(
        [AllowNull()]
        [object]$Node,

        [string]$Path = 'inputs'
    )

    if ($null -eq $Node) {
        return
    }

    if ($Node -is [string] -or $Node -is [ValueType]) {
        $leafName = ($Path -split '[./_\-]')[-1].ToLowerInvariant()
        if ($leafName -in @('uri', 'url', 'endpoint', 'path', 'dataset', 'baseresourceurl', 'resourceuri', 'hosturl')) {
            [pscustomobject]@{
                ParameterPath = $Path
                LeafName      = $leafName
                Value         = [string]$Node
            }
        }
        return
    }

    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [System.Collections.IDictionary] -and
        $Node.PSObject.TypeNames -notcontains 'System.Management.Automation.PSCustomObject') {
        $index = 0
        foreach ($item in $Node) {
            Get-EndpointLeaves -Node $item -Path "$Path[$index]"
            $index++
        }
        return
    }

    foreach ($entry in Get-ObjectEntries -InputObject $Node) {
        Get-EndpointLeaves -Node $entry.Value -Path "$Path.$($entry.Name)"
    }
}

function Get-EndpointClassification {
    param([AllowEmptyString()][string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        return [pscustomobject]@{ Classification = 'NotExposed'; Host = ''; SuggestedAllowPattern = '' }
    }

    if ($Endpoint -match '^(?<scheme>https?)://(?<authority>[^/?#]+)(?<remainder>.*)$') {
        $hostIsDynamic = Test-DynamicExpression -Value $Matches.authority
        $isDynamic = Test-DynamicExpression -Value $Endpoint
        $classification = 'Static'
        if ($hostIsDynamic) {
            $classification = 'Dynamic'
        } elseif ($isDynamic) {
            $classification = 'StaticHostDynamicPath'
        }

        $staticHost = "$($Matches.scheme)://$($Matches.authority)"
        $suggestedRule = ''
        if (-not $hostIsDynamic) {
            $suggestedRule = "$staticHost/*"
        }

        return [pscustomobject]@{
            Classification      = $classification
            Host                = $staticHost
            SuggestedAllowPattern = $suggestedRule
        }
    }

    if (Test-DynamicExpression -Value $Endpoint) {
        return [pscustomobject]@{ Classification = 'Dynamic'; Host = ''; SuggestedAllowPattern = '' }
    }

    return [pscustomobject]@{ Classification = 'RelativeStatic'; Host = ''; SuggestedAllowPattern = '' }
}

function Get-OperationEndpointRows {
    param(
        [Parameter(Mandatory)]
        [object]$Operation,

        [switch]$IncludeMissing
    )

    $leaves = @(Get-EndpointLeaves -Node $Operation.Inputs)
    $baseLeaves = @($leaves | Where-Object { $_.LeafName -in @('dataset', 'baseresourceurl', 'resourceuri', 'hosturl') })
    $primaryLeaves = @($leaves | Where-Object { $_.LeafName -in @('uri', 'url', 'endpoint') })
    $pathLeaves = @($leaves | Where-Object { $_.LeafName -eq 'path' })

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($leaf in $primaryLeaves) {
        $endpoint = $leaf.Value
        $source = $leaf.ParameterPath
        if ($endpoint -notmatch '^https?://' -and $baseLeaves.Count -gt 0) {
            $base = [string]$baseLeaves[0].Value
            if ($base -match '^https?://') {
                $endpoint = "$($base.TrimEnd('/'))/$($endpoint.TrimStart('/'))"
                $source = "$($baseLeaves[0].ParameterPath) + $source"
            }
        }
        $candidates.Add([pscustomobject]@{ ParameterPath = $source; Endpoint = $endpoint })
    }

    if ($candidates.Count -eq 0 -and $baseLeaves.Count -gt 0) {
        foreach ($leaf in $baseLeaves) {
            $candidates.Add([pscustomobject]@{ ParameterPath = $leaf.ParameterPath; Endpoint = $leaf.Value })
        }
    }

    if ($candidates.Count -eq 0 -and $pathLeaves.Count -gt 0) {
        foreach ($leaf in $pathLeaves) {
            $candidates.Add([pscustomobject]@{ ParameterPath = $leaf.ParameterPath; Endpoint = $leaf.Value })
        }
    }

    $seen = @{}
    foreach ($candidate in $candidates) {
        $sanitized = Remove-SensitiveUrlParts `
            -Value ([string]$candidate.Endpoint) `
            -RedactDynamicExpression
        if ($seen.ContainsKey($sanitized)) {
            continue
        }
        $seen[$sanitized] = $true
        $classification = Get-EndpointClassification -Endpoint $sanitized
        [pscustomobject]@{
            ParameterPath        = $candidate.ParameterPath
            ConfiguredEndpoint   = $sanitized
            Classification       = $classification.Classification
            StaticHost           = $classification.Host
            SuggestedAllowPattern = $classification.SuggestedAllowPattern
        }
    }

    if ($candidates.Count -eq 0 -and $IncludeMissing) {
        [pscustomobject]@{
            ParameterPath         = ''
            ConfiguredEndpoint    = ''
            Classification        = 'NotExposed'
            StaticHost            = ''
            SuggestedAllowPattern = ''
        }
    }
}

function New-InventoryRow {
    param(
        [Parameter(Mandatory)][object]$FlowRecord,
        [Parameter(Mandatory)][object]$Operation,
        [Parameter(Mandatory)][object]$Endpoint
    )

    [pscustomobject][ordered]@{
        EnvironmentName       = $FlowRecord.EnvironmentName
        FlowName              = $FlowRecord.FlowName
        DisplayName           = $FlowRecord.DisplayName
        State                 = $FlowRecord.State
        LastModified          = $FlowRecord.LastModified
        Owner                 = $FlowRecord.Owner
        Connector             = $Operation.Connector
        ConnectorId           = $Operation.ConnectorId
        OperationId           = $Operation.OperationId
        ActionPath            = $Operation.ActionPath
        EndpointParameter     = $Endpoint.ParameterPath
        ConfiguredEndpoint    = $Endpoint.ConfiguredEndpoint
        Classification        = $Endpoint.Classification
        StaticHost            = $Endpoint.StaticHost
        SuggestedAllowPattern = $Endpoint.SuggestedAllowPattern
        SourcePath            = $FlowRecord.SourcePath
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Definition') {
    $flowRecords = @(Get-DefinitionRecordsFromPath -Path $DefinitionPath)
} elseif ($UsePacCli) {
    $flowRecords = @(
        Get-PacFlowRecords `
            -RequestedEnvironments $EnvironmentName `
            -RequestedFlows $FlowName
    )
} else {
    if (-not $UseAdminPowerShell) {
        throw 'Choose a live acquisition method: -UsePacCli (recommended) or -UseAdminPowerShell.'
    }
    $flowRecords = @(
        Get-LiveFlowRecords `
            -RequestedEnvironments $EnvironmentName `
            -RequestedFlows $FlowName `
            -Login:$InteractiveLogin
    )
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($flowRecord in $flowRecords) {
    if ($null -eq $flowRecord.Definition) {
        $script:AcquisitionErrors.Add([pscustomobject]@{
            EnvironmentName = $flowRecord.EnvironmentName
            FlowName        = $flowRecord.FlowName
            Error           = 'Flow definition was not returned.'
        })
        continue
    }

    $actions = Get-PropertyValue -InputObject $flowRecord.Definition -Name 'actions'
    foreach ($operation in @(Get-HttpOperations -Node $actions)) {
        foreach ($endpoint in @(Get-OperationEndpointRows -Operation $operation -IncludeMissing:$IncludeNoEndpointRows)) {
            $results.Add((New-InventoryRow -FlowRecord $flowRecord -Operation $operation -Endpoint $endpoint))
        }
    }
}

$headers = @(
    'EnvironmentName', 'FlowName', 'DisplayName', 'State', 'LastModified',
    'Owner', 'Connector', 'ConnectorId', 'OperationId', 'ActionPath',
    'EndpointParameter', 'ConfiguredEndpoint', 'Classification', 'StaticHost',
    'SuggestedAllowPattern', 'SourcePath'
)
$writtenPath = Write-InventoryCsv `
    -Rows @($results) `
    -Headers $headers `
    -Path $OutputPath `
    -AllowOutputInGitWorktree:$AllowOutputInGitWorktree
Write-Verbose "Wrote $($results.Count) endpoint rows to $writtenPath"

if ($script:AcquisitionErrors.Count -gt 0) {
    $errorPath = "$writtenPath.errors.csv"
    $script:AcquisitionErrors | Export-Csv -LiteralPath $errorPath -NoTypeInformation -Encoding utf8
    $message = "Endpoint inventory is incomplete: $($script:AcquisitionErrors.Count) flow or environment acquisition errors. See $errorPath."
    if (-not $AllowPartialResults) {
        throw $message
    }
    Write-Warning $message
}

$results
