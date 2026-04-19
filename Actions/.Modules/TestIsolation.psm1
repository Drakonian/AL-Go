# Test Isolation module for AL-Go for GitHub
# Partitions AL test codeunits by their RequiredTestIsolation / TestType properties
# and runs each partition through a test runner codeunit whose TestIsolation matches.
# See TestIsolation-ImplementationPlan.md at the repo root.

$script:CanonicalIsolation = @{
    'none'     = 'None'
    'disabled' = 'Disabled'
    'codeunit' = 'Codeunit'
    'function' = 'Function'
}

$script:CanonicalTestType = @{
    'unittest'        = 'UnitTest'
    'integrationtest' = 'IntegrationTest'
    'uncategorized'   = 'Uncategorized'
    'aitest'          = 'AITest'
}

function Get-ALTestCodeunitMetadata {
    <#
        .SYNOPSIS
            Scan AL source files under the given test app folders and return metadata
            for every test codeunit (Subtype = Test), including its RequiredTestIsolation
            and TestType property values. Missing properties default to None / UnitTest.
        .PARAMETER TestAppIds
            Hashtable mapping extension id (Guid string) to the folder containing that
            test app's source. Codeunits are tagged with the owning appId so the caller
            can route each codeunit to the correct -extensionId at run time.
        .OUTPUTS
            Array of hashtables: @{ appId; codeunitId; codeunitName; requiredIsolation; testType; filePath }
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $TestAppIds
    )

    $result = @()
    foreach ($appId in $TestAppIds.Keys) {
        $folder = $TestAppIds[$appId]
        if (-not $folder -or -not (Test-Path -Path $folder)) { continue }

        $alFiles = Get-ChildItem -Path $folder -Filter '*.al' -Recurse -File -ErrorAction SilentlyContinue
        foreach ($file in $alFiles) {
            $content = Get-Content -Path $file.FullName -Raw -Encoding utf8 -ErrorAction SilentlyContinue
            if (-not $content) { continue }

            $codeunitMatches = [regex]::Matches(
                $content,
                '(?im)^\s*codeunit\s+(\d+)\s+(?:"(?<name>[^"]+)"|(?<name>[A-Za-z_]\w*))'
            )

            for ($i = 0; $i -lt $codeunitMatches.Count; $i++) {
                $m = $codeunitMatches[$i]
                $start = $m.Index
                $end = if ($i + 1 -lt $codeunitMatches.Count) { $codeunitMatches[$i + 1].Index } else { $content.Length }
                $body = $content.Substring($start, $end - $start)

                if ($body -notmatch '(?i)(^|[\s{;])Subtype\s*=\s*Test\s*;') { continue }

                $requiredIso = 'None'
                if ($body -match '(?i)(^|[\s{;])RequiredTestIsolation\s*=\s*(\w+)\s*;') {
                    $raw = $Matches[2].ToLowerInvariant()
                    if ($script:CanonicalIsolation.ContainsKey($raw)) {
                        $requiredIso = $script:CanonicalIsolation[$raw]
                    }
                }

                $testType = 'UnitTest'
                if ($body -match '(?i)(^|[\s{;])TestType\s*=\s*(\w+)\s*;') {
                    $raw = $Matches[2].ToLowerInvariant()
                    if ($script:CanonicalTestType.ContainsKey($raw)) {
                        $testType = $script:CanonicalTestType[$raw]
                    }
                }

                $result += @{
                    appId             = "$appId"
                    codeunitId        = [int] $m.Groups[1].Value
                    codeunitName      = $m.Groups['name'].Value
                    requiredIsolation = $requiredIso
                    testType          = $testType
                    filePath          = $file.FullName
                }
            }
        }
    }
    return , $result
}

function Group-ALTestsByIsolation {
    <#
        .SYNOPSIS
            Group test codeunit metadata by (requiredIsolation, testType) and resolve
            each group to a test runner codeunit id based on the supplied settings.
        .PARAMETER Metadata
            Output of Get-ALTestCodeunitMetadata.
        .PARAMETER Settings
            The testIsolation nested settings object (from GetDefaultSettings / merged user settings).
        .OUTPUTS
            Array of partitions: @{ runnerCodeunitId; isolationLabel; testType; codeunits[] }.
            codeunits[] preserves the shape from Get-ALTestCodeunitMetadata including appId.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array] $Metadata,

        [Parameter(Mandatory = $true)]
        $Settings
    )

    $typeFilter = @($Settings.testTypeFilter)
    $filtered = if ($typeFilter.Count -gt 0) {
        @($Metadata | Where-Object { $typeFilter -contains $_.testType })
    }
    else {
        @($Metadata)
    }

    $grouped = [ordered]@{}
    foreach ($item in $filtered) {
        $iso = $item.requiredIsolation

        $runnerId = 0
        $missing = $false
        if ($iso -ieq 'None') {
            $runnerId = [int] $Settings.defaultRunnerCodeunitId
        }
        else {
            $mapped = [int] $Settings.runners."$iso"
            if ($mapped -le 0) {
                $missing = $true
            }
            else {
                $runnerId = $mapped
            }
        }

        if ($missing) {
            if ($Settings.failOnMissingRequiredIsolationRunner) {
                throw "No test runner mapped for RequiredTestIsolation = $iso (codeunit $($item.codeunitId) '$($item.codeunitName)' in $($item.filePath)). Configure testIsolation.runners.$iso or set testIsolation.failOnMissingRequiredIsolationRunner = false."
            }
            Write-Warning "No test runner mapped for RequiredTestIsolation = $iso (codeunit $($item.codeunitId) '$($item.codeunitName)'). Falling back to defaultRunnerCodeunitId = $($Settings.defaultRunnerCodeunitId). Tests may fail if the default runner's TestIsolation does not satisfy the codeunit's requirement."
            $runnerId = [int] $Settings.defaultRunnerCodeunitId
        }

        $key = "$iso|$($item.testType)"
        if (-not $grouped.Contains($key)) {
            $grouped[$key] = @{
                runnerCodeunitId = $runnerId
                isolationLabel   = $iso
                testType         = $item.testType
                codeunits        = @()
            }
        }
        $grouped[$key].codeunits += $item
    }

    return , @($grouped.Values)
}

function New-PartitionedTestRunnerScriptBlock {
    <#
        .SYNOPSIS
            Build a scriptblock compatible with Run-AlPipeline's -RunTestsInBcContainer
            override. Run-AlPipeline invokes the override once per test app; our
            scriptblock takes the hashtable of parameters it built (containing
            extensionId, containerName, disabledTests, JUnit/XUnit file, auth, etc.)
            and invokes Run-TestsInBcContainer once per (partition, codeunit) that
            belongs to the current app. Each invocation forces -testCodeunit to a
            single id and -testRunnerCodeunitId to the partition's mapped runner.
            Result-file appending is preserved because we forward the file params
            Run-AlPipeline already set (AppendTo*ResultFile = $true).
        .PARAMETER Partitions
            Output of Group-ALTestsByIsolation. Closed over by the returned scriptblock.
        .OUTPUTS
            [scriptblock] returning $true if all invocations reported success.
    #>
    Param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array] $Partitions
    )

    $capturedPartitions = $Partitions

    return {
        Param([Hashtable] $parameters)

        $appId = "$($parameters.extensionId)"
        $allPassed = $true
        $invocations = 0

        foreach ($p in $capturedPartitions) {
            $cusInApp = @($p.codeunits | Where-Object { "$($_.appId)" -eq $appId })
            if ($cusInApp.Count -eq 0) { continue }

            foreach ($cu in $cusInApp) {
                $call = @{}
                foreach ($k in $parameters.Keys) { $call[$k] = $parameters[$k] }
                $call['testCodeunit'] = "$($cu.codeunitId)"
                if ([int]$p.runnerCodeunitId -gt 0) {
                    $call['testRunnerCodeunitId'] = "$($p.runnerCodeunitId)"
                }

                Write-Host "Running codeunit $($cu.codeunitId) '$($cu.codeunitName)' isolation=$($p.isolationLabel) type=$($p.testType) runner=$($p.runnerCodeunitId) app=$appId"
                $invocations++

                $passed = Run-TestsInBcContainer @call
                if (-not $passed) { $allPassed = $false }
            }
        }

        Write-Host "Partitioned test run for app $appId complete. Invocations: $invocations. All passed: $allPassed"
        return $allPassed
    }.GetNewClosure()
}

Export-ModuleMember -Function Get-ALTestCodeunitMetadata, Group-ALTestsByIsolation, New-PartitionedTestRunnerScriptBlock
