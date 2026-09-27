#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
.SYNOPSIS
    Unit tests for the pure/file-only helper functions in Update-DanglingConnectorDomain.ps1.

.DESCRIPTION
    Covers Get-ApexDomain, Get-ConnectorHostMap, and Get-AzureWebsitesTrackingUpdate by
    dot-sourcing the script (which only defines functions and returns when dot-sourced -
    it does not clone the repo, hit DNS, or write any output files).

    Deliberately out of scope: the git clone/pull, the Resolve-DnsName parallel checks,
    and CSV export. Those need a live repo checkout and/or network access and run inside
    ForEach-Object -Parallel runspaces that Pester's Mock cannot intercept, so they are
    left to be exercised manually / in a real run rather than unit-tested here.
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'Update-DanglingConnectorDomain.ps1')
}

Describe 'Get-ApexDomain' {
    It 'returns the last two labels for a simple domain' {
        Get-ApexDomain -HostName 'foo.contoso.com' | Should -Be 'contoso.com'
    }

    It 'returns the host itself when there is only one label' {
        Get-ApexDomain -HostName 'localhost' | Should -Be 'localhost'
    }

    It 'returns the last two labels for a three-label domain under a plain TLD' {
        Get-ApexDomain -HostName 'a.b.com' | Should -Be 'b.com'
    }

    It 'returns the last three labels for a known two-label public suffix' {
        Get-ApexDomain -HostName 'foo.example.co.uk' | Should -Be 'example.co.uk'
    }

    It 'does not extend beyond two labels for a two-label suffix used as the whole host' {
        Get-ApexDomain -HostName 'example.co.uk' | Should -Be 'example.co.uk'
    }

    It 'reduces azurewebsites.net hosts to their apex' {
        Get-ApexDomain -HostName 'cc-bot-master-server.azurewebsites.net' | Should -Be 'azurewebsites.net'
    }
}

Describe 'Get-ConnectorHostMap' {
    BeforeAll {
        function New-ConnectorFixture {
            param(
                [Parameter(Mandatory)][string]$RepoRoot,
                [Parameter(Mandatory)][string]$Name,
                [Parameter(Mandatory)][string]$HostValue,
                [switch]$WithScriptOverride,
                [switch]$WithDynamicHostPolicy
            )

            $dir = Join-Path $RepoRoot "certified-connectors\$Name"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            @"
{
  "swagger": "2.0",
  "host": "$HostValue",
  "basePath": "/"
}
"@ | Set-Content -LiteralPath (Join-Path $dir 'apiDefinition.swagger.json') -Encoding UTF8

            if ($WithScriptOverride) {
                '// custom host rewrite' | Set-Content -LiteralPath (Join-Path $dir 'script.csx') -Encoding UTF8
            }

            if ($WithDynamicHostPolicy) {
                @'
{
  "policyTemplateInstances": [
    { "templateId": "dynamichosturl", "parameters": {} }
  ]
}
'@ | Set-Content -LiteralPath (Join-Path $dir 'apiProperties.json') -Encoding UTF8
            }
        }
    }

    BeforeEach {
        $repoRoot = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $repoRoot | Out-Null
    }

    It 'extracts a host declared by a single connector' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Alpha' -HostValue 'alpha.azurewebsites.net'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map.Keys | Should -Contain 'alpha.azurewebsites.net'
        $map['alpha.azurewebsites.net'].SourceFiles | Should -Contain 'certified-connectors\Alpha\apiDefinition.swagger.json'
    }

    It 'normalizes host casing and strips a trailing port' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Beta' -HostValue 'BETA.AzureWebsites.NET:443'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map.Keys | Should -Contain 'beta.azurewebsites.net'
        $map.Keys | Should -Not -Contain 'BETA.AzureWebsites.NET:443'
    }

    It 'merges multiple connectors that declare the same host' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Gamma1' -HostValue 'shared.azurewebsites.net'
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Gamma2' -HostValue 'shared.azurewebsites.net'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map['shared.azurewebsites.net'].SourceFiles.Count | Should -Be 2
    }

    It 'excludes IP-literal hosts' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Delta' -HostValue '10.0.0.5'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map.Keys | Should -Not -Contain '10.0.0.5'
    }

    It 'excludes localhost' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Epsilon' -HostValue 'localhost'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map.Keys | Should -Not -Contain 'localhost'
    }

    It 'flags HasScriptOverride when a script.csx sits next to the definition' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Zeta' -HostValue 'api.contoso.com' -WithScriptOverride

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map['api.contoso.com'].HasScriptOverride | Should -BeTrue
    }

    It 'does not flag HasScriptOverride when there is no script.csx' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Eta' -HostValue 'plain.contoso.com'

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map['plain.contoso.com'].HasScriptOverride | Should -BeFalse
    }

    It 'flags HasDynamicHostPolicy from a dynamicHostUrl policyTemplateInstance' {
        New-ConnectorFixture -RepoRoot $repoRoot -Name 'Theta' -HostValue 'instance.example.com' -WithDynamicHostPolicy

        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map['instance.example.com'].HasDynamicHostPolicy | Should -BeTrue
    }

    It 'returns an empty map when there are no connector definitions' {
        $map = Get-ConnectorHostMap -ClonePath $repoRoot

        $map.Count | Should -Be 0
    }
}

Describe 'Get-AzureWebsitesTrackingUpdate' {
    BeforeAll {
        $today = '2026-09-27'
    }

    It 'keeps an existing entry whose connector still declares the host, even if still NXDOMAIN' {
        $existing = @([pscustomobject]@{ domain = 'still-broken.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })
        $hostMap  = @{ 'still-broken.azurewebsites.net' = [pscustomobject]@{ SourceFiles = @('a.json') } }

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @('still-broken.azurewebsites.net') -HostMap $hostMap -Today $today

        $result.Entries.domain | Should -Contain 'still-broken.azurewebsites.net'
        $result.RemovedDomains | Should -BeNullOrEmpty
    }

    It 'keeps an existing entry whose host started resolving again, as long as a connector still declares it' {
        $existing = @([pscustomobject]@{ domain = 'recovered.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })
        $hostMap  = @{ 'recovered.azurewebsites.net' = [pscustomobject]@{ SourceFiles = @('a.json') } }

        # Not in AzureNxDomains -> it resolves now, but the connector referencing it is still in the repo.
        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @() -HostMap $hostMap -Today $today

        $result.Entries.domain | Should -Contain 'recovered.azurewebsites.net'
        $result.RemovedDomains | Should -BeNullOrEmpty
    }

    It 'removes an existing entry once no connector declares its domain any more' {
        $existing = @([pscustomobject]@{ domain = 'gone.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('old.json') })
        $hostMap  = @{}

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @() -HostMap $hostMap -Today $today

        $result.RemovedDomains | Should -Contain 'gone.azurewebsites.net'
        $result.Entries.Count | Should -Be 0
    }

    It 'adds a newly discovered NXDOMAIN azurewebsites.net domain not already tracked' {
        $hostMap = @{ 'new-dead.azurewebsites.net' = [pscustomobject]@{ SourceFiles = @('new.json') } }

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries @() -AzureNxDomains @('new-dead.azurewebsites.net') -HostMap $hostMap -Today $today

        $result.AddedDomains | Should -Contain 'new-dead.azurewebsites.net'
        ($result.Entries | Where-Object domain -eq 'new-dead.azurewebsites.net').dateAdded | Should -Be $today
        ($result.Entries | Where-Object domain -eq 'new-dead.azurewebsites.net').connectors | Should -Contain 'new.json'
    }

    It 'does not duplicate or re-date a domain that is already tracked' {
        $existing = @([pscustomobject]@{ domain = 'already.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })
        $hostMap  = @{ 'already.azurewebsites.net' = [pscustomobject]@{ SourceFiles = @('a.json') } }

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @('already.azurewebsites.net') -HostMap $hostMap -Today $today

        $result.AddedDomains | Should -BeNullOrEmpty
        $matches = @($result.Entries | Where-Object domain -eq 'already.azurewebsites.net')
        $matches.Count | Should -Be 1
        $matches[0].dateAdded | Should -Be '2026-01-01'
    }

    It 'adds and removes domains in the same run, and sorts the result by domain' {
        $existing = @([pscustomobject]@{ domain = 'zzz-gone.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('old.json') })
        $hostMap  = @{ 'aaa-new.azurewebsites.net' = [pscustomobject]@{ SourceFiles = @('new.json') } }

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @('aaa-new.azurewebsites.net') -HostMap $hostMap -Today $today

        $result.AddedDomains | Should -Contain 'aaa-new.azurewebsites.net'
        $result.RemovedDomains | Should -Contain 'zzz-gone.azurewebsites.net'
        $result.Entries.domain | Should -Be @('aaa-new.azurewebsites.net')
    }

    It 'returns an empty Entries array when everything tracked is pruned and nothing new is found' {
        $existing = @([pscustomobject]@{ domain = 'gone1.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })

        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existing -AzureNxDomains @() -HostMap @{} -Today $today

        $result.Entries | Should -BeNullOrEmpty
        $result.RemovedDomains | Should -Contain 'gone1.azurewebsites.net'
    }

    It 'handles an empty existing-entries list with no new domains' {
        $result = Get-AzureWebsitesTrackingUpdate -ExistingEntries @() -AzureNxDomains @() -HostMap @{} -Today $today

        $result.Entries | Should -BeNullOrEmpty
        $result.AddedDomains | Should -BeNullOrEmpty
        $result.RemovedDomains | Should -BeNullOrEmpty
    }
}

Describe 'Set-AzureNameAvailability' {
    BeforeAll {
        $today = '2026-09-28'
    }

    It 'stamps an entry with a fresh live result' {
        $entries = @([pscustomobject]@{ domain = 'foo.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })
        $map     = @{ 'foo.azurewebsites.net' = [pscustomobject]@{ NameAvailable = $true; Reason = 'Available' } }

        $result = Set-AzureNameAvailability -Entries $entries -AvailabilityMap $map -Today $today

        $result[0].nameAvailable | Should -BeTrue
        $result[0].nameAvailabilityReason | Should -Be 'Available'
        $result[0].nameCheckedDate | Should -Be $today
    }

    It 'stamps an unavailable name with its reason' {
        $entries = @([pscustomobject]@{ domain = 'foo.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') })
        $map     = @{ 'foo.azurewebsites.net' = [pscustomobject]@{ NameAvailable = $false; Reason = 'AlreadyExists' } }

        $result = Set-AzureNameAvailability -Entries $entries -AvailabilityMap $map -Today $today

        $result[0].nameAvailable | Should -BeFalse
        $result[0].nameAvailabilityReason | Should -Be 'AlreadyExists'
    }

    It 'preserves an existing entry''s prior availability when the map has no fresh result for it' {
        $entries = @([pscustomobject]@{
            domain                 = 'foo.azurewebsites.net'
            dateAdded              = '2026-01-01'
            connectors              = @('a.json')
            nameAvailable           = $true
            nameAvailabilityReason  = 'AlreadyClaimedByUs'
            nameCheckedDate         = '2026-09-01'
        })

        $result = Set-AzureNameAvailability -Entries $entries -AvailabilityMap @{} -Today $today

        $result[0].nameAvailable | Should -BeTrue
        $result[0].nameAvailabilityReason | Should -Be 'AlreadyClaimedByUs'
        $result[0].nameCheckedDate | Should -Be '2026-09-01'
    }

    It 'leaves a brand new entry with no availability fields when the map has nothing for it' {
        $entries = @([pscustomobject]@{ domain = 'brand-new.azurewebsites.net'; dateAdded = $today; connectors = @('a.json') })

        $result = Set-AzureNameAvailability -Entries $entries -AvailabilityMap @{} -Today $today

        $result[0].nameAvailable | Should -BeNullOrEmpty
        $result[0].nameAvailabilityReason | Should -BeNullOrEmpty
        $result[0].nameCheckedDate | Should -BeNullOrEmpty
    }

    It 'preserves domain/dateAdded/connectors unchanged' {
        $entries = @([pscustomobject]@{ domain = 'foo.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json', 'b.json') })

        $result = Set-AzureNameAvailability -Entries $entries -AvailabilityMap @{} -Today $today

        $result[0].domain | Should -Be 'foo.azurewebsites.net'
        $result[0].dateAdded | Should -Be '2026-01-01'
        $result[0].connectors | Should -Be @('a.json', 'b.json')
    }

    It 'processes multiple entries independently' {
        $entries = @(
            [pscustomobject]@{ domain = 'a.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('a.json') }
            [pscustomobject]@{ domain = 'b.azurewebsites.net'; dateAdded = '2026-01-01'; connectors = @('b.json') }
        )
        $map = @{ 'a.azurewebsites.net' = [pscustomobject]@{ NameAvailable = $true; Reason = 'Available' } }

        $result = @(Set-AzureNameAvailability -Entries $entries -AvailabilityMap $map -Today $today)

        $result.Count | Should -Be 2
        ($result | Where-Object domain -eq 'a.azurewebsites.net').nameAvailable | Should -BeTrue
        ($result | Where-Object domain -eq 'b.azurewebsites.net').nameAvailable | Should -BeNullOrEmpty
    }
}
