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
$scriptPath = Join-Path $repositoryRoot 'scripts\Export-PowerAutomateHttpEndpoints.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Scanner script not found: $scriptPath"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pp-http-inventory-flow-test-$([Guid]::NewGuid())"
$fixturePath = Join-Path $testRoot 'definitions.json'
$emptyFixturePath = Join-Path $testRoot 'definitions-without-http.json'
$outputPath = Join-Path $testRoot 'inventory.csv'
$emptyOutputPath = Join-Path $testRoot 'empty-inventory.csv'
$liveOutputPath = Join-Path $testRoot 'live-inventory.csv'
$pacOutputPath = Join-Path $testRoot 'pac-inventory.csv'
$originalModulePath = $env:PSModulePath

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null

    $fixture = @'
[
  {
    "EnvironmentName": "env-prod",
    "FlowName": "flow-static",
    "DisplayName": "Static and nested HTTP",
    "State": "Started",
    "Definition": {
      "actions": {
        "Call_Static": {
          "type": "Http",
          "inputs": {
            "method": "GET",
            "uri": "https://api.contoso.com/v1/orders?api-key=secret"
          }
        },
        "Condition": {
          "type": "If",
          "expression": true,
          "actions": {
            "Call_Dynamic_Path": {
              "type": "Http",
              "inputs": {
                "method": "GET",
                "uri": "https://api.fabrikam.com/v2/@{variables('id')}"
              }
            }
          },
          "else": {
            "actions": {}
          }
        }
      }
    }
  },
  {
    "EnvironmentName": "env-prod",
    "FlowName": "flow-entra",
    "DisplayName": "HTTP with Entra",
    "Definition": {
      "actions": {
        "Call_Graph": {
          "type": "OpenApiConnection",
          "inputs": {
            "host": {
              "apiId": "/providers/Microsoft.PowerApps/apis/shared_webcontents",
              "connectionName": "shared_webcontents",
              "operationId": "InvokeHttp"
            },
            "parameters": {
              "dataset": "https://graph.microsoft.com",
              "request/method": "GET",
              "request/url": "/v1.0/users"
            }
          }
        }
      }
    }
  },
  {
    "EnvironmentName": "env-test",
    "FlowName": "flow-webhook",
    "DisplayName": "Dynamic webhook",
    "Definition": {
      "actions": {
        "Subscribe": {
          "type": "HttpWebhook",
          "inputs": {
            "subscribe": {
              "method": "POST",
              "uri": "@{triggerBody()?['callbackUrl']}"
            }
          }
        }
      }
    }
  },
  {
    "EnvironmentName": "env-test",
    "FlowName": "flow-missing",
    "DisplayName": "HTTP endpoint not exposed",
    "Definition": {
      "actions": {
        "Call_Unresolved": {
          "type": "Http",
          "inputs": {
            "method": "GET"
          }
        }
      }
    }
  },
  {
    "EnvironmentName": "env-test",
    "FlowName": "flow-sharepoint",
    "DisplayName": "Non-HTTP connector",
    "Definition": {
      "actions": {
        "Create_Item": {
          "type": "OpenApiConnection",
          "inputs": {
            "host": {
              "apiId": "/providers/Microsoft.PowerApps/apis/shared_sharepointonline",
              "connectionName": "shared_sharepointonline",
              "operationId": "PostItem"
            },
            "parameters": {
              "item/url": "https://should-not-be-included.example"
            }
          }
        }
      }
    }
  }
]
'@
    $fixture | Set-Content -LiteralPath $fixturePath -Encoding utf8

    $null = & $scriptPath `
        -DefinitionPath $fixturePath `
        -OutputPath $outputPath `
        -IncludeNoEndpointRows

    $rows = @(Import-Csv -LiteralPath $outputPath)
    Assert-Equal -Expected 5 -Actual $rows.Count -Message 'Unexpected endpoint row count.'

    $static = $rows | Where-Object { $_.FlowName -eq 'flow-static' -and $_.ActionPath -match 'Call_Static$' }
    Assert-Equal -Expected 'Static' -Actual $static.Classification -Message 'Static endpoint classification failed.'
    Assert-Equal -Expected 'https://api.contoso.com/v1/orders?<redacted>' -Actual $static.ConfiguredEndpoint -Message 'Query-string redaction failed.'
    Assert-Equal -Expected 'https://api.contoso.com/*' -Actual $static.SuggestedAllowPattern -Message 'Static allow pattern failed.'

    $dynamicPath = $rows | Where-Object { $_.ActionPath -match 'Call_Dynamic_Path$' }
    Assert-Equal -Expected 'StaticHostDynamicPath' -Actual $dynamicPath.Classification -Message 'Nested dynamic-path classification failed.'
    Assert-Equal -Expected 'https://api.fabrikam.com/*' -Actual $dynamicPath.SuggestedAllowPattern -Message 'Dynamic-path allow pattern failed.'

    $entra = $rows | Where-Object { $_.FlowName -eq 'flow-entra' }
    Assert-Equal -Expected 'HTTP with Microsoft Entra ID' -Actual $entra.Connector -Message 'HTTP with Entra connector detection failed.'
    Assert-Equal -Expected 'https://graph.microsoft.com/v1.0/users' -Actual $entra.ConfiguredEndpoint -Message 'Base URL and relative path reconstruction failed.'

    $webhook = $rows | Where-Object { $_.FlowName -eq 'flow-webhook' }
    Assert-Equal -Expected 'Dynamic' -Actual $webhook.Classification -Message 'Dynamic webhook classification failed.'
    Assert-Equal -Expected 'HTTP Webhook' -Actual $webhook.Connector -Message 'Webhook detection failed.'
    Assert-Equal -Expected '@{<dynamic expression>}' -Actual $webhook.ConfiguredEndpoint -Message 'Dynamic expression redaction failed.'

    $missing = $rows | Where-Object { $_.FlowName -eq 'flow-missing' }
    Assert-Equal -Expected 'NotExposed' -Actual $missing.Classification -Message 'Missing endpoint handling failed.'

    Assert-True `
        -Condition (-not ($rows | Where-Object { $_.FlowName -eq 'flow-sharepoint' })) `
        -Message 'A non-HTTP connector was incorrectly included.'

    $emptyFixture = @'
[
  {
    "EnvironmentName": "env-test",
    "FlowName": "flow-sharepoint-only",
    "DisplayName": "No HTTP actions",
    "Definition": {
      "actions": {
        "Create_Item": {
          "type": "OpenApiConnection",
          "inputs": {
            "host": {
              "apiId": "/providers/Microsoft.PowerApps/apis/shared_sharepointonline",
              "connectionName": "shared_sharepointonline",
              "operationId": "PostItem"
            }
          }
        }
      }
    }
  }
]
'@
    $emptyFixture | Set-Content -LiteralPath $emptyFixturePath -Encoding utf8

    $null = & $scriptPath -DefinitionPath $emptyFixturePath -OutputPath $emptyOutputPath
    Assert-True -Condition (Test-Path -LiteralPath $emptyOutputPath) -Message 'Empty inventory CSV was not created.'
    Assert-Equal -Expected 0 -Actual @(Import-Csv -LiteralPath $emptyOutputPath).Count -Message 'Empty inventory should contain headers only.'

    $mockModuleRoot = Join-Path $testRoot 'Modules\Microsoft.PowerApps.Administration.PowerShell'
    New-Item -ItemType Directory -Path $mockModuleRoot | Out-Null
    $mockModule = @'
function Get-AdminPowerAppEnvironment {
    [pscustomobject]@{ EnvironmentName = 'mock-env' }
}

function Get-AdminFlow {
    param(
        [string]$EnvironmentName,
        [string]$FlowName
    )

    if ([string]::IsNullOrWhiteSpace($FlowName)) {
        return [pscustomobject]@{
            EnvironmentName = $EnvironmentName
            FlowName        = 'mock-flow'
            DisplayName     = 'Mock live flow summary'
        }
    }

    return [pscustomobject]@{
        EnvironmentName = $EnvironmentName
        FlowName        = $FlowName
        DisplayName     = 'Mock live flow detail'
        State           = 'Started'
        Internal        = [pscustomobject]@{
            properties = [pscustomobject]@{
                definition = [pscustomobject]@{
                    actions = [pscustomobject]@{
                        Call_Mock = [pscustomobject]@{
                            type   = 'Http'
                            inputs = [pscustomobject]@{
                                method = 'GET'
                                uri    = 'https://mock.contoso.com/health'
                            }
                        }
                    }
                }
            }
        }
    }
}

function Add-PowerAppsAccount {}

Export-ModuleMember -Function Get-AdminPowerAppEnvironment, Get-AdminFlow, Add-PowerAppsAccount
'@
    $mockModule | Set-Content `
        -LiteralPath (Join-Path $mockModuleRoot 'Microsoft.PowerApps.Administration.PowerShell.psm1') `
        -Encoding utf8

    $env:PSModulePath = "$(Split-Path -Parent $mockModuleRoot)$([IO.Path]::PathSeparator)$originalModulePath"
    $null = & $scriptPath `
        -UseAdminPowerShell `
        -EnvironmentName 'mock-env' `
        -OutputPath $liveOutputPath

    $liveRows = @(Import-Csv -LiteralPath $liveOutputPath)
    Assert-Equal -Expected 1 -Actual $liveRows.Count -Message 'Live-mode mock returned an unexpected row count.'
    Assert-Equal -Expected 'mock-flow' -Actual $liveRows[0].FlowName -Message 'Live-mode flow identity failed.'
    Assert-Equal -Expected 'https://mock.contoso.com/health' -Actual $liveRows[0].ConfiguredEndpoint -Message 'Live-mode definition fallback failed.'

    function global:pac {
        param(
            [Parameter(ValueFromRemainingArguments)]
            [string[]]$Arguments
        )

        @'
{
  "value": [
    {
      "name": "Mock PAC flow",
      "resourceId": "mock-pac-flow",
      "workflowId": "00000000-0000-0000-0000-000000000001",
      "stateCode": "Activated",
      "modifiedOn": "2026-10-01T12:00:00Z",
      "ownerId": "00000000-0000-0000-0000-000000000002",
      "definition": {
        "actions": {
          "Call_PAC": {
            "type": "Http",
            "inputs": {
              "method": "GET",
              "uri": "https://pac.contoso.com/status"
            }
          }
        }
      }
    }
  ]
}
'@
    }

    $null = & $scriptPath `
        -UsePacCli `
        -EnvironmentName 'mock-pac-env' `
        -OutputPath $pacOutputPath

    $pacRows = @(Import-Csv -LiteralPath $pacOutputPath)
    Assert-Equal -Expected 1 -Actual $pacRows.Count -Message 'PAC mode returned an unexpected row count.'
    Assert-Equal -Expected 'mock-pac-flow' -Actual $pacRows[0].FlowName -Message 'PAC mode flow identity failed.'
    Assert-Equal -Expected 'https://pac.contoso.com/status' -Actual $pacRows[0].ConfiguredEndpoint -Message 'PAC mode endpoint extraction failed.'

    Write-Output "PASS: $($rows.Count) offline rows, $($liveRows.Count) module row, and $($pacRows.Count) PAC row validated."
} finally {
    Remove-Item function:\pac -Force -ErrorAction SilentlyContinue
    Remove-Module Microsoft.PowerApps.Administration.PowerShell -Force -ErrorAction SilentlyContinue
    $env:PSModulePath = $originalModulePath
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
