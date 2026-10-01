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

$repositoryRoot = Split-Path (Split-Path -Parent $PSScriptRoot) -Parent
$scriptPath = Join-Path $repositoryRoot 'scripts\Export-PowerPlatformHttpEndpointInventory.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pp-http-inventory-combined-test-$([Guid]::NewGuid())"

try {
    function global:pac {
        param(
            [Parameter(ValueFromRemainingArguments)]
            [string[]]$Arguments
        )

        $command = $Arguments[0..1] -join ' '
        switch ($command) {
            'power-automate list-cloud-flows' {
                @'
{
  "value": [
    {
      "name": "Mock HTTP flow",
      "resourceId": "mock-flow",
      "workflowId": "00000000-0000-0000-0000-000000000001",
      "stateCode": "Activated",
      "modifiedOn": "2026-10-01T12:00:00Z",
      "ownerId": "00000000-0000-0000-0000-000000000002",
      "definition": {
        "actions": {
          "Call_API": {
            "type": "Http",
            "inputs": {
              "method": "GET",
              "uri": "https://flow.contoso.com/v1/orders?token=secret"
            }
          }
        }
      }
    }
  ]
}
'@
            }
            'power-apps get-admin-apps' {
                @'
{
  "value": [
    {
      "name": "mock-app"
    }
  ],
  "nextLink": ""
}
'@
            }
            'power-apps get-admin-app' {
                @'
{
  "name": "mock-app",
  "properties": {
    "displayName": "Mock HTTP app",
    "connectionReferences": {
      "mock-http-reference": {
        "id": "/providers/microsoft.powerapps/apis/shared_webcontentsv2",
        "displayName": "HTTP With Microsoft Entra ID",
        "parameterHints": {
          "baseResourceUrl": {
            "value": "https://graph.microsoft.com"
          }
        }
      }
    }
  }
}
'@
            }
            'canvas download' {
                $directoryIndex = [Array]::IndexOf($Arguments, '--extract-to-directory')
                if ($directoryIndex -lt 0) {
                    throw 'Mock PAC download did not receive --extract-to-directory.'
                }
                $sourceRoot = $Arguments[$directoryIndex + 1]
                $src = Join-Path $sourceRoot 'src'
                New-Item -ItemType Directory -Path (Join-Path $src 'References') -Force | Out-Null
                New-Item -ItemType Directory -Path (Join-Path $src 'Controls') -Force | Out-Null

                [ordered]@{
                    Name = 'Mock HTTP app'
                    Id = 'mock-app'
                    LocalConnectionReferences = '{}'
                } | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $src 'Properties.json') -Encoding utf8
                [ordered]@{
                    DataSources = @(
                        [ordered]@{
                            Name = 'HTTPwithMicrosoftEntraID'
                            ApiId = '/providers/microsoft.powerapps/apis/shared_webcontentsv2'
                            DatasetName = 'https://graph.microsoft.com'
                            Type = 'ConnectedDataSourceInfo'
                        }
                    )
                } | ConvertTo-Json -Depth 10 |
                    Set-Content -LiteralPath (Join-Path $src 'References\DataSources.json') -Encoding utf8
                [ordered]@{
                    TopParent = [ordered]@{
                        ControlPropertyState = @(
                            [ordered]@{
                                InvariantPropertyName = 'OnSelect'
                                InvariantScript = 'Set(result,HTTPwithMicrosoftEntraID.InvokeHttp("GET","/v1.0/users",Blank(),Blank()))'
                            }
                        )
                    }
                } | ConvertTo-Json -Depth 10 |
                    Set-Content -LiteralPath (Join-Path $src 'Controls\1.json') -Encoding utf8
                'Downloaded mock app.'
            }
            default {
                throw "Unexpected mock PAC command: $($Arguments -join ' ')"
            }
        }
    }

    $rows = @(
        & $scriptPath `
            -EnvironmentName 'mock-environment' `
            -OutputDirectory $testRoot
    )
    Assert-Equal -Expected 2 -Actual $rows.Count -Message 'Combined row count failed.'
    Assert-Equal `
        -Expected 1 `
        -Actual @($rows | Where-Object { $_.ResourceType -eq 'CloudFlow' }).Count `
        -Message 'Combined flow row count failed.'
    Assert-Equal `
        -Expected 1 `
        -Actual @($rows | Where-Object { $_.ResourceType -eq 'CanvasApp' }).Count `
        -Message 'Combined app row count failed.'

    $flow = $rows | Where-Object { $_.ResourceType -eq 'CloudFlow' }
    Assert-Equal `
        -Expected 'https://flow.contoso.com/v1/orders?<redacted>' `
        -Actual $flow.ConfiguredEndpoint `
        -Message 'Combined flow redaction failed.'

    foreach ($name in @(
            'PowerAutomateHttpEndpoints.csv',
            'PowerAppsHttpEndpoints.csv',
            'PowerPlatformHttpEndpoints.csv'
        )) {
        if (-not (Test-Path -LiteralPath (Join-Path $testRoot $name))) {
            throw "Combined report wasn't created: $name"
        }
    }

    Write-Output 'PASS: combined flow and app inventory validated.'
} finally {
    Remove-Item function:\pac -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
