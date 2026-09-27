<#
.SYNOPSIS
    Finds broken/dangling connector hosts in microsoft/PowerPlatformConnectors -
    i.e. the exact "host" a connector's swagger declares returns NXDOMAIN.

.DESCRIPTION
    Each connector in the repo declares its API host in a top-level "host" field
    inside its apiDefinition.swagger.json (e.g. "myapp.azurewebsites.net"). That
    is the literal name this script checks - NOT the apex/registrable domain
    (e.g. "azurewebsites.net"), since the apex is almost always registered even
    when the specific connector's host has been torn down. Checking the apex
    would hide exactly the broken-connector case this script is meant to find.

    1. Clones (or reuses) a shallow copy of the PowerPlatformConnectors repo.
    2. Finds every apiDefinition.swagger.json file (the only place a connector's
       host is declared) and extracts its "host" value.
    3. Resolves each unique literal host in parallel to see whether it still
       exists in DNS at all (NXDOMAIN) or is dead/torn down.
    4. Writes every host that came back NXDOMAIN to a CSV, along with which
       connector file(s) declare it, for triage.

    Caveat: a connector can override its host at runtime instead of actually
    calling the swagger's literal "host", in which case that value is just a
    required placeholder (commonly api.contoso.com, yourinstance.example.com,
    etc.) that production never contacts. Two such mechanisms are detected:
      - script.csx: custom code that rewrites the outgoing request itself.
      - a "dynamicHostUrl"/"dynamicSubdomain" policyTemplateInstance in
        apiProperties.json, which has APIM substitute a per-customer
        connectionParameter (e.g. "instanceUrl") as the real host.
    These are flagged via HasScriptOverride / HasDynamicHostPolicy so they can
    be triaged separately from genuinely dangling hosts.

    As a second signal, every NXDOMAIN host also gets its apex/registrable
    domain checked (e.g. "foo.contoso.com" -> "contoso.com") for whether the
    apex itself is registered - unless the apex is azurewebsites.net, which is
    always registered (it's Microsoft's own domain) and so isn't worth checking.
    An NXDOMAIN host whose apex is ALSO unregistered suggests the whole
    vendor/domain is gone, not just one torn-down deployment.

.PARAMETER RepoUrl
    Git URL of the repository to scan. Defaults to the upstream PowerPlatformConnectors repo.

.PARAMETER ClonePath
    Local path to clone/reuse the repository. Defaults to a folder under $env:TEMP.

.PARAMETER OutputCsv
    Path of the CSV report to write. Defaults to .\UnregisteredConnectorDomains.csv

.PARAMETER SkipClone
    If set, assumes ClonePath already contains a checkout and skips git clone/pull.

.PARAMETER IncludeAllStatuses
    If set, the CSV includes every host found (Registered/NXDOMAIN/Unknown), not just
    the broken ones. Useful for auditing/debugging the extraction logic.

.PARAMETER ThrottleLimit
    Max concurrent DNS lookups. Defaults to 16.

.PARAMETER RetryCount
    Number of times to retry a host that errors transiently (timeout/server failure)
    before giving up and marking it Unknown. Defaults to 2.

.PARAMETER AzureWebsitesTrackingFile
    Path to a JSON file that accumulates every unregistered (NXDOMAIN) *.azurewebsites.net
    host seen across runs - each entry records the domain, the date it was first seen,
    and the connector file(s) that declare it. An entry's host resolving again does NOT
    remove it. It is only removed once every connector that ever referenced it is gone
    from the current scan - i.e. no connector file in the repo declares that host any
    more, whether or not it was NXDOMAIN - since at that point the entry no longer
    corresponds to anything in the repo to triage. Defaults to
    .\UnregisteredAzureWebsitesDomains.json

.EXAMPLE
    .\Update-DanglingConnectorDomain.ps1

.EXAMPLE
    .\Update-DanglingConnectorDomain.ps1 -ClonePath D:\repos\PowerPlatformConnectors -SkipClone -OutputCsv .\report.csv
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', '',
    Justification = 'This is an interactive report script; Write-Host colored status output is the intended UX, not pipeline data.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSReviewUnusedParameter', 'RetryCount',
    Justification = 'Consumed via $using:RetryCount inside the ForEach-Object -Parallel scriptblock; the analyzer does not resolve $using: references.')]
[CmdletBinding()]
param(
    [string]$RepoUrl = 'https://github.com/microsoft/PowerPlatformConnectors.git',

    [string]$ClonePath = (Join-Path $env:TEMP 'PowerPlatformConnectors'),

    [string]$OutputCsv = '.\UnregisteredConnectorDomains.csv',

    [string]$AzureWebsitesTrackingFile = '.\UnregisteredAzureWebsitesDomains.json',

    [switch]$SkipClone,

    [switch]$IncludeAllStatuses,

    [int]$ThrottleLimit = 16,

    [int]$RetryCount = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper functions (pure/file-only logic - no clone/DNS - so it's unit-testable by dot-sourcing this script)

$hostFieldRegex         = [regex]'(?i)"host"\s*:\s*"(?<host>[^"/\\]+)"'
$ipRegex                = [regex]'^\d{1,3}(\.\d{1,3}){3}$'
$dynamicHostPolicyRegex = [regex]'(?i)"templateId"\s*:\s*"(dynamichosturl|dynamicsubdomain)"'

# Small set of common two-label public suffixes so apex-domain reduction (used only
# for the secondary "is the whole domain gone" check below) isn't thrown off by
# ccTLD second-level domains. Not exhaustive (not a full public suffix list).
$twoLabelSuffixes = @(
    'co.uk','org.uk','gov.uk','ac.uk','me.uk','ltd.uk','plc.uk',
    'co.jp','ne.jp','or.jp','ac.jp',
    'co.kr','or.kr',
    'co.in','net.in','org.in','gen.in','firm.in','ind.in',
    'com.au','net.au','org.au','edu.au','gov.au',
    'co.nz','net.nz','org.nz',
    'com.cn','net.cn','org.cn','gov.cn',
    'com.br','net.br','org.br',
    'com.mx','com.ar','com.co',
    'co.za','org.za',
    'com.sg','com.hk','com.tw',
    'co.il','org.il'
)

function Get-ApexDomain {
    param([Parameter(Mandatory)][string]$HostName)

    $labels = $HostName.Split('.')
    if ($labels.Count -lt 2) { return $HostName }

    $lastTwo = ($labels[-2..-1] -join '.')
    if ($labels.Count -ge 3) {
        $lastThree = ($labels[-3..-1] -join '.')
        if ($twoLabelSuffixes -contains $lastTwo) { return $lastThree }
    }
    return $lastTwo
}

function Get-ConnectorHostMap {
    <#
    .SYNOPSIS
        Scans every apiDefinition.swagger.json under $ClonePath and returns a map of
        literal connector host -> which connector file(s) declare it, plus whether a
        script.csx or dynamicHostUrl/dynamicSubdomain policy may override that host at
        runtime instead (see the script's top-level .DESCRIPTION).
    .OUTPUTS
        [hashtable] keyed by lower-cased host name, each value a pscustomobject with
        SourceFiles (HashSet[string] of repo-relative paths), HasScriptOverride, and
        HasDynamicHostPolicy.
    #>
    param([Parameter(Mandatory)][string]$ClonePath)

    $definitionFiles = @(Get-ChildItem -Path $ClonePath -Recurse -File -Force -Filter 'apiDefinition.swagger.json' -ErrorAction Stop)

    $resolvedClonePath = (Resolve-Path -LiteralPath $ClonePath -ErrorAction Stop).Path

    # Map: literal host -> set of connector definition files that declare it
    $hostMap = @{}

    foreach ($file in $definitionFiles) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
        }
        catch {
            Write-Verbose "Skipping unreadable file '$($file.FullName)': $($_.Exception.Message)"
            continue
        }
        if ([string]::IsNullOrEmpty($content)) { continue }

        $relativePath = $file.FullName.Substring($resolvedClonePath.Length).TrimStart('\', '/')

        # A connector with a script.csx runs custom code that can rewrite the outgoing
        # request's target host at runtime - the swagger "host" is then just a required
        # placeholder (commonly api.contoso.com) that is never actually contacted.
        $hasScriptOverride = Test-Path -LiteralPath (Join-Path $file.DirectoryName 'script.csx')

        # Alternatively, apiProperties.json can carry a "dynamicHostUrl"/"dynamicSubdomain"
        # policyTemplateInstance that has APIM substitute a per-customer connectionParameter
        # (e.g. "instanceUrl") as the real host - same net effect, no code required.
        $hasDynamicHostPolicy = $false
        $apiPropertiesPath = Join-Path $file.DirectoryName 'apiProperties.json'
        if (Test-Path -LiteralPath $apiPropertiesPath) {
            try {
                $apiPropertiesContent = Get-Content -LiteralPath $apiPropertiesPath -Raw -ErrorAction Stop
                $hasDynamicHostPolicy = $dynamicHostPolicyRegex.IsMatch($apiPropertiesContent)
            }
            catch {
                Write-Verbose "Skipping unreadable file '$apiPropertiesPath': $($_.Exception.Message)"
            }
        }

        foreach ($m in $hostFieldRegex.Matches($content)) {
            $rawHost = $m.Groups['host'].Value.Trim().ToLowerInvariant().TrimEnd('.')
            $rawHost = $rawHost -replace ':\d+$', ''   # strip port, e.g. "example.com:443"

            if ([string]::IsNullOrWhiteSpace($rawHost)) { continue }
            if ($rawHost -eq 'localhost') { continue }
            if ($ipRegex.IsMatch($rawHost)) { continue }
            if ($rawHost -notmatch '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') { continue }

            if (-not $hostMap.ContainsKey($rawHost)) {
                $hostMap[$rawHost] = [pscustomobject]@{
                    SourceFiles           = (New-Object System.Collections.Generic.HashSet[string])
                    HasScriptOverride     = $false
                    HasDynamicHostPolicy  = $false
                }
            }
            [void]$hostMap[$rawHost].SourceFiles.Add($relativePath)
            if ($hasScriptOverride) {
                $hostMap[$rawHost].HasScriptOverride = $true
            }
            if ($hasDynamicHostPolicy) {
                $hostMap[$rawHost].HasDynamicHostPolicy = $true
            }
        }
    }

    return $hostMap
}

function Get-AzureWebsitesTrackingUpdate {
    <#
    .SYNOPSIS
        Computes the updated azurewebsites.net tracking-file entries: prunes any
        existing entry that no connector in $HostMap references any more, and appends
        newly-discovered NXDOMAIN azurewebsites.net domains not already tracked.
    .DESCRIPTION
        Pure function - does no file I/O and needs neither a repo checkout nor DNS
        access, so it's fully unit-testable. $HostMap must reflect every host declared
        by connectors currently in the repo (regardless of their DNS status) - an
        existing entry whose domain is absent from it means every connector that ever
        declared that host is gone, not merely that the host started resolving again.
    .OUTPUTS
        [pscustomobject] with Entries (the full sorted array to persist), AddedDomains,
        and RemovedDomains.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$ExistingEntries,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$AzureNxDomains,
        [Parameter(Mandatory)][hashtable]$HostMap,
        [Parameter(Mandatory)][string]$Today
    )

    $keptEntries    = @()
    $removedEntries = @()
    foreach ($existingEntry in $ExistingEntries) {
        if ($HostMap.ContainsKey($existingEntry.domain)) {
            $keptEntries += $existingEntry
        }
        else {
            $removedEntries += $existingEntry
        }
    }

    $knownDomains = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($keptEntry in $keptEntries) {
        [void]$knownDomains.Add($keptEntry.domain)
    }

    $newEntries = @()
    foreach ($domain in $AzureNxDomains) {
        if ($knownDomains.Contains($domain)) { continue }

        $newEntries += [pscustomobject]@{
            domain     = $domain
            dateAdded  = $Today
            connectors = @($HostMap[$domain].SourceFiles | Sort-Object)
        }
        [void]$knownDomains.Add($domain)
    }

    # @() must wrap the whole pipeline, not just the concatenation: Sort-Object emits
    # nothing for an empty input, and assigning "nothing" gives $null, not an empty array.
    $allEntries = @($keptEntries + $newEntries | Sort-Object domain)

    [pscustomobject]@{
        Entries        = $allEntries
        AddedDomains   = @($newEntries | ForEach-Object { $_.domain })
        RemovedDomains = @($removedEntries | ForEach-Object { $_.domain })
    }
}

#endregion

# Everything below this point clones/pulls the repo, hits DNS, and writes output files.
# When this script is dot-sourced (e.g. by Pester tests, to reuse the functions above
# without side effects), $MyInvocation.InvocationName is '.' and none of it runs.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

#region Get the repo

if (-not $SkipClone -and -not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "git was not found on PATH. Install Git, or clone the repo yourself and re-run with -SkipClone -ClonePath <path>."
}

if (-not $SkipClone) {
    if (Test-Path -LiteralPath $ClonePath) {
        Write-Host "Repo already present at '$ClonePath' - pulling latest..." -ForegroundColor Cyan
        git -C $ClonePath pull --ff-only 2>&1 | Write-Verbose
        if ($LASTEXITCODE -ne 0) {
            throw "git pull failed with exit code $LASTEXITCODE for '$ClonePath'."
        }
    }
    else {
        Write-Host "Cloning '$RepoUrl' (shallow) into '$ClonePath'..." -ForegroundColor Cyan
        git clone --depth 1 -- $RepoUrl $ClonePath 2>&1 | Write-Verbose
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE for '$RepoUrl'."
        }
    }
}

if (-not (Test-Path -LiteralPath $ClonePath)) {
    throw "Clone path '$ClonePath' does not exist. Run without -SkipClone, or provide a valid -ClonePath."
}

#endregion

#region Find connector definitions and extract their declared host

Write-Host 'Finding connector definitions (apiDefinition.swagger.json) and extracting declared hosts...' -ForegroundColor Cyan

$hostMap = Get-ConnectorHostMap -ClonePath $ClonePath

Write-Host "Found $($hostMap.Count) unique connector host(s) to check." -ForegroundColor Cyan

if ($hostMap.Count -eq 0) {
    Write-Warning 'No connector hosts extracted - nothing to check.'
    return
}

#endregion

#region DNS check (parallel) - does the literal host still exist at all?

Write-Host "Checking DNS for $($hostMap.Count) hosts (throttle=$ThrottleLimit)..." -ForegroundColor Cyan

$hostsToCheck = $hostMap.Keys

$results = @($hostsToCheck | ForEach-Object -Parallel {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $hostName   = $_
    $retryCount = $using:RetryCount

    function Test-HostStatusInner {
        param([string]$HostName, [int]$Retries)

        $attempt = 0
        while ($true) {
            $attempt++
            try {
                # A_AAAA follows CNAME chains too, so this correctly reflects
                # whether the literal connector host still resolves at all.
                Resolve-DnsName -Name $HostName -Type A_AAAA -ErrorAction Stop | Out-Null
                return 'Registered'
            }
            catch {
                $msg = $_.Exception.Message

                # "DNS name does not exist" == authoritative NXDOMAIN for this exact name
                if ($msg -match 'DNS name does not exist' -or $msg -match 'RCODE_NAME_ERROR') {
                    return 'NXDOMAIN'
                }

                if ($attempt -gt $Retries) {
                    return "Unknown ($msg)"
                }
                Start-Sleep -Milliseconds (300 * $attempt)
            }
        }
    }

    $status = Test-HostStatusInner -HostName $hostName -Retries $retryCount

    [pscustomobject]@{
        Domain = $hostName
        Status = $status
    }
} -ThrottleLimit $ThrottleLimit)

#endregion

#region Apex-domain registration check for NXDOMAIN hosts (skip azurewebsites.net)

# For every host that came back NXDOMAIN, also check whether its apex/registrable
# domain is registered at all. azurewebsites.net is skipped - it's Microsoft's own
# domain and always registered, so checking it would just waste a DNS query.
$apexesToCheck = @(
    $results |
        Where-Object { $_.Status -eq 'NXDOMAIN' } |
        ForEach-Object { Get-ApexDomain -HostName $_.Domain } |
        Where-Object { $_ -ne 'azurewebsites.net' } |
        Select-Object -Unique
)

$apexStatusMap = @{}

if ($apexesToCheck.Count -gt 0) {
    Write-Host "Checking $($apexesToCheck.Count) apex domain(s) for registration (NS lookup)..." -ForegroundColor Cyan

    $apexResults = @($apexesToCheck | ForEach-Object -Parallel {
        Set-StrictMode -Version Latest
        $ErrorActionPreference = 'Stop'

        $apexDomain = $_
        $retryCount = $using:RetryCount

        function Test-ApexStatusInner {
            param([string]$ApexDomain, [int]$Retries)

            $attempt = 0
            while ($true) {
                $attempt++
                try {
                    # NS is the right record type at an apex: a registered/delegated
                    # domain always has NS records, even with no website behind it.
                    Resolve-DnsName -Name $ApexDomain -Type NS -ErrorAction Stop | Out-Null
                    return 'Registered'
                }
                catch {
                    $msg = $_.Exception.Message
                    if ($msg -match 'DNS name does not exist' -or $msg -match 'RCODE_NAME_ERROR') {
                        return 'NXDOMAIN'
                    }
                    if ($attempt -gt $Retries) {
                        return "Unknown ($msg)"
                    }
                    Start-Sleep -Milliseconds (300 * $attempt)
                }
            }
        }

        [pscustomobject]@{
            ApexDomain = $apexDomain
            Status     = Test-ApexStatusInner -ApexDomain $apexDomain -Retries $retryCount
        }
    } -ThrottleLimit $ThrottleLimit)

    foreach ($ar in $apexResults) {
        $apexStatusMap[$ar.ApexDomain] = $ar.Status
    }
}

#endregion

#region Build report and export

$maxSampleFiles = 5

$report = foreach ($r in $results) {
    $hostInfo = $hostMap[$r.Domain]
    if (-not $hostInfo) { continue }

    $sourceFiles = @($hostInfo.SourceFiles | Sort-Object)
    $sampleFiles = (@($sourceFiles | Select-Object -First $maxSampleFiles)) -join '; '
    if ($sourceFiles.Count -gt $maxSampleFiles) {
        $sampleFiles += " (+$($sourceFiles.Count - $maxSampleFiles) more)"
    }

    $apexDomain = $null
    $apexStatus = ''
    if ($r.Status -eq 'NXDOMAIN') {
        $apexDomain = Get-ApexDomain -HostName $r.Domain
        $apexStatus = if ($apexDomain -eq 'azurewebsites.net') {
            'Skipped (azurewebsites.net)'
        }
        else {
            $apexStatusMap[$apexDomain]
        }
    }

    [pscustomobject]@{
        Domain               = $r.Domain
        Status               = $r.Status
        HasScriptOverride    = $hostInfo.HasScriptOverride
        HasDynamicHostPolicy = $hostInfo.HasDynamicHostPolicy
        ApexDomain           = $apexDomain
        ApexStatus           = $apexStatus
        FileCount            = $sourceFiles.Count
        SampleFiles          = $sampleFiles
    }
}

$report = @($report | Sort-Object Status, Domain)

$nxRows        = @($report | Where-Object { $_.Status -eq 'NXDOMAIN' })
$nxCount       = $nxRows.Count
$nxOverrideCt  = @($nxRows | Where-Object { $_.HasScriptOverride -or $_.HasDynamicHostPolicy }).Count
$nxApexDeadCt  = @($nxRows | Where-Object { $_.ApexStatus -eq 'NXDOMAIN' }).Count
$registeredCt  = @($report | Where-Object { $_.Status -eq 'Registered' }).Count
$unknownCt     = @($report | Where-Object { $_.Status -like 'Unknown*' }).Count

Write-Host ''
Write-Host "Summary: $registeredCt resolving, $nxCount NXDOMAIN (broken), $unknownCt unknown/errored." -ForegroundColor Green
if ($nxCount -gt 0) {
    Write-Host "  of which $nxOverrideCt have a script.csx or dynamicHostUrl/dynamicSubdomain policy that may override the host at runtime (likely placeholder) and $($nxCount - $nxOverrideCt) do not (likely genuinely broken)." -ForegroundColor Yellow
    Write-Host "  of the NXDOMAIN hosts, $nxApexDeadCt also have an unregistered apex domain (whole vendor domain appears gone, not just one deployment)." -ForegroundColor Yellow
}

$toExport = @(if ($IncludeAllStatuses) { $report } else { $report | Where-Object { $_.Status -eq 'NXDOMAIN' } })

$toExport | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

Write-Host "Wrote $($toExport.Count) row(s) to '$OutputCsv'." -ForegroundColor Green

#endregion

#region Track unregistered azurewebsites.net domains (adds new dead hosts; prunes entries no connector references any more)

$azureNxDomains = @($nxRows | Where-Object { $_.ApexDomain -eq 'azurewebsites.net' } | ForEach-Object { $_.Domain })

$existingEntries = @()
if (Test-Path -LiteralPath $AzureWebsitesTrackingFile) {
    $existingContent = Get-Content -LiteralPath $AzureWebsitesTrackingFile -Raw -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($existingContent)) {
        try {
            $existingEntries = @(ConvertFrom-Json -InputObject $existingContent -ErrorAction Stop)
        }
        catch {
            throw "Failed to parse existing tracking file '$AzureWebsitesTrackingFile' as JSON: $($_.Exception.Message)"
        }
    }
}

if ($existingEntries.Count -gt 0 -or $azureNxDomains.Count -gt 0) {
    Write-Host ''
    Write-Host "Updating azurewebsites.net tracking file '$AzureWebsitesTrackingFile'..." -ForegroundColor Cyan

    $update = Get-AzureWebsitesTrackingUpdate -ExistingEntries $existingEntries -AzureNxDomains $azureNxDomains -HostMap $hostMap -Today (Get-Date).ToString('yyyy-MM-dd')

    if ($update.RemovedDomains.Count -gt 0) {
        Write-Host "  Removed $($update.RemovedDomains.Count) domain(s) no connector declares any more: $($update.RemovedDomains -join ', ')" -ForegroundColor Yellow
    }

    if ($update.AddedDomains.Count -gt 0 -or $update.RemovedDomains.Count -gt 0) {
        if ($update.Entries.Count -eq 0) {
            Set-Content -LiteralPath $AzureWebsitesTrackingFile -Value '[]' -Encoding UTF8 -ErrorAction Stop
        }
        else {
            $update.Entries | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $AzureWebsitesTrackingFile -Encoding UTF8 -ErrorAction Stop
        }

        $keptCount = $update.Entries.Count - $update.AddedDomains.Count
        Write-Host "  Added $($update.AddedDomains.Count) new domain(s); $keptCount pre-existing entry/entries kept. Total tracked: $($update.Entries.Count)." -ForegroundColor Green
    }
    else {
        Write-Host "  No changes - tracking file unchanged ($($existingEntries.Count) entries)." -ForegroundColor Green
    }
}

#endregion
