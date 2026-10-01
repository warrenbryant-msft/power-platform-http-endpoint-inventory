[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected '$Expected' but received '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$repositoryRoot = Split-Path (Split-Path -Parent $PSScriptRoot) -Parent
$scriptPath = Join-Path $repositoryRoot 'scripts\Export-PowerAppsHttpEndpoints.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pp-http-inventory-app-test-$([Guid]::NewGuid())"
$positiveRoot = Join-Path $testRoot 'positive'
$negativeRoot = Join-Path $testRoot 'negative'
$positiveOutput = Join-Path $testRoot 'positive.csv'
$negativeOutput = Join-Path $testRoot 'negative.csv'

try {
    $positiveSrc = Join-Path $positiveRoot 'src'
    New-Item -ItemType Directory -Path (Join-Path $positiveSrc 'References') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $positiveSrc 'Controls') -Force | Out-Null

    $localConnections = [ordered]@{
        'mock-http-reference' = [ordered]@{
            connectionInstanceId = '/providers/microsoft.powerapps/apis/shared_webcontentsv2/connections/mock'
            connectionRef = [ordered]@{
                id = '/providers/microsoft.powerapps/apis/shared_webcontentsv2'
                displayName = 'HTTP With Microsoft Entra ID'
                parameterHints = [ordered]@{
                    baseResourceUrl = [ordered]@{
                        value = 'https://graph.microsoft.com'
                    }
                }
            }
            datasets = [ordered]@{
                'https://graph.microsoft.com' = [ordered]@{}
            }
            id = 'mock-http-reference'
        }
    }
    [ordered]@{
        Name = 'Mock HTTP Canvas App'
        Id = 'mock-http-canvas-app'
        LocalConnectionReferences = $localConnections | ConvertTo-Json -Depth 20 -Compress
    } | ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath (Join-Path $positiveSrc 'Properties.json') -Encoding utf8

    [ordered]@{
        DataSources = @(
            [ordered]@{
                Name = 'HTTPwithMicrosoftEntraID'
                ApiId = '/providers/microsoft.powerapps/apis/shared_webcontentsv2'
                DatasetName = 'default'
                Type = 'ConnectedDataSourceInfo'
            }
        )
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $positiveSrc 'References\DataSources.json') -Encoding utf8

    $formula = @'
Set(
    staticResult,
    HTTPwithMicrosoftEntraID.InvokeHttp(
        "GET",
        "https://api.contoso.com/v1/orders?api-key=secret",
        Blank(),
        Blank()
    )
);
Set(
    relativeResult,
    HTTPwithMicrosoftEntraID.InvokeHttp(
        "GET",
        "/v1.0/users",
        Blank(),
        Blank()
    )
);
Set(
    dynamicResult,
    HTTPwithMicrosoftEntraID.InvokeHttp(
        "GET",
        Concatenate("/v1.0/users/", User().Email),
        Blank(),
        Blank()
    )
)
'@
    [ordered]@{
        TopParent = [ordered]@{
            ControlPropertyState = @(
                [ordered]@{
                    InvariantPropertyName = 'OnSelect'
                    InvariantScript = $formula
                }
            )
        }
    } | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath (Join-Path $positiveSrc 'Controls\1.json') -Encoding utf8

    $negativeSrc = Join-Path $negativeRoot 'src'
    New-Item -ItemType Directory -Path (Join-Path $negativeSrc 'References') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $negativeSrc 'Controls') -Force | Out-Null
    [ordered]@{
        Name = 'Mock SharePoint Canvas App'
        Id = 'mock-sharepoint-canvas-app'
        LocalConnectionReferences = '{}'
    } | ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $negativeSrc 'Properties.json') -Encoding utf8
    [ordered]@{
        DataSources = @(
            [ordered]@{
                Name = 'SharePoint'
                ApiId = '/providers/microsoft.powerapps/apis/shared_sharepointonline'
                Type = 'ConnectedDataSourceInfo'
            }
        )
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $negativeSrc 'References\DataSources.json') -Encoding utf8
    [ordered]@{
        TopParent = [ordered]@{
            ControlPropertyState = @(
                [ordered]@{
                    InvariantPropertyName = 'OnSelect'
                    InvariantScript = 'Launch("https://contoso.example")'
                }
            )
        }
    } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $negativeSrc 'Controls\1.json') -Encoding utf8

    $null = & $scriptPath `
        -SourcePath $positiveRoot `
        -SourceEnvironmentName 'mock-environment' `
        -OutputPath $positiveOutput
    $positiveRows = @(Import-Csv -LiteralPath $positiveOutput)
    Assert-Equal -Expected 3 -Actual $positiveRows.Count -Message 'Positive HTTP app row count failed.'
    Assert-True `
        -Condition (@($positiveRows | Where-Object { $_.ConnectionReference -eq 'mock-http-reference' }).Count -eq 3) `
        -Message 'HTTP app connection reference correlation failed.'

    $static = $positiveRows |
        Where-Object { $_.ConfiguredEndpoint -match '^https://api\.contoso\.com' }
    Assert-Equal -Expected 'Static' -Actual $static.Classification -Message 'Static app URL classification failed.'
    Assert-Equal `
        -Expected 'https://api.contoso.com/v1/orders?<redacted>' `
        -Actual $static.ConfiguredEndpoint `
        -Message 'App query-string redaction failed.'

    $relative = $positiveRows |
        Where-Object { $_.ConfiguredEndpoint -eq 'https://graph.microsoft.com/v1.0/users' }
    Assert-Equal -Expected 'Static' -Actual $relative.Classification -Message 'Relative app URL resolution failed.'
    Assert-Equal -Expected 'Resolved' -Actual $relative.ResolutionStatus -Message 'Relative app URL status failed.'

    $dynamic = $positiveRows |
        Where-Object { $_.Classification -eq 'StaticHostDynamicPath' }
    Assert-Equal `
        -Expected 'https://graph.microsoft.com/*' `
        -Actual $dynamic.SuggestedAllowPattern `
        -Message 'Dynamic app URL allow pattern failed.'

    $null = & $scriptPath -SourcePath $negativeRoot -OutputPath $negativeOutput
    $negativeRows = @(Import-Csv -LiteralPath $negativeOutput)
    Assert-Equal -Expected 0 -Actual $negativeRows.Count -Message 'Non-HTTP app produced false positives.'
    Assert-True -Condition (Test-Path -LiteralPath $negativeOutput) -Message 'Negative report was not created.'

    Write-Output "PASS: $($positiveRows.Count) positive HTTP app rows and zero false positives validated."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
