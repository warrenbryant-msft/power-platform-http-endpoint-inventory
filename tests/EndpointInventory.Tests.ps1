$ErrorActionPreference = 'Stop'

Describe 'Power Platform HTTP endpoint inventory' {
    It 'validates Power Automate fixtures' {
        $output = & "$PSScriptRoot\cases\Test-PowerAutomateFixtures.ps1"
        if (($output -join [Environment]::NewLine) -notmatch 'PASS: 5 offline rows') {
            throw 'Power Automate fixture validation did not return its success marker.'
        }
    }

    It 'validates Power Apps fixtures' {
        $output = & "$PSScriptRoot\cases\Test-PowerAppsFixtures.ps1"
        if (($output -join [Environment]::NewLine) -notmatch 'PASS: 3 positive HTTP app rows') {
            throw 'Power Apps fixture validation did not return its success marker.'
        }
    }

    It 'validates combined report normalization' {
        $output = & "$PSScriptRoot\cases\Test-CombinedInventory.ps1"
        if (($output -join [Environment]::NewLine) -notmatch 'PASS: combined flow and app inventory') {
            throw 'Combined fixture validation did not return its success marker.'
        }
    }

    It 'blocks endpoint reports inside Git worktrees' {
        $output = & "$PSScriptRoot\cases\Test-OutputSafety.ps1"
        if (($output -join [Environment]::NewLine) -notmatch 'PASS: Git worktree output safety') {
            throw 'Output safety validation did not return its success marker.'
        }
    }
}
