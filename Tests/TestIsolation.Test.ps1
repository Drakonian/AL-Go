Import-Module (Join-Path $PSScriptRoot '../Actions/.Modules/TestIsolation.psm1') -Force

Describe 'TestIsolation' {

    BeforeAll {
        function New-TempFolder {
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString())
            New-Item -Path $p -ItemType Directory | Out-Null
            return $p
        }

        function New-AppFolder {
            param([string] $Root, [string] $AppId, [string] $AppName)
            $folder = Join-Path $Root $AppName
            New-Item -Path $folder -ItemType Directory | Out-Null
            @{ id = $AppId; name = $AppName } | ConvertTo-Json | Set-Content -Path (Join-Path $folder 'app.json') -Encoding utf8
            return $folder
        }

        function New-ALFile {
            param([string] $Folder, [string] $Name, [string] $Content)
            $p = Join-Path $Folder $Name
            Set-Content -Path $p -Value $Content -Encoding utf8
            return $p
        }
    }

    Context 'Get-ALTestCodeunitMetadata' {

        It 'extracts a plain test codeunit with defaults (None / UnitTest)' {
            $root = New-TempFolder
            try {
                $folder = New-AppFolder -Root $root -AppId 'aaa' -AppName 'App1'
                New-ALFile -Folder $folder -Name 'Plain.al' -Content @'
codeunit 50100 "Plain Test"
{
    Subtype = Test;

    [Test]
    procedure DoSomething()
    begin
    end;
}
'@
                $meta = Get-ALTestCodeunitMetadata -TestAppIds @{ 'aaa' = $folder }
                $meta.Count | Should -Be 1
                $meta[0].appId | Should -Be 'aaa'
                $meta[0].codeunitId | Should -Be 50100
                $meta[0].codeunitName | Should -Be 'Plain Test'
                $meta[0].requiredIsolation | Should -Be 'None'
                $meta[0].testType | Should -Be 'UnitTest'
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'extracts RequiredTestIsolation and TestType with canonical casing' {
            $root = New-TempFolder
            try {
                $folder = New-AppFolder -Root $root -AppId 'bbb' -AppName 'App2'
                New-ALFile -Folder $folder -Name 'Iso.al' -Content @'
codeunit 50200 "Isolated"
{
    Subtype = Test;
    requiredtestisolation = FUNCTION;
    TESTTYPE = integrationtest;
}
'@
                $meta = Get-ALTestCodeunitMetadata -TestAppIds @{ 'bbb' = $folder }
                $meta.Count | Should -Be 1
                $meta[0].requiredIsolation | Should -Be 'Function'
                $meta[0].testType | Should -Be 'IntegrationTest'
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'excludes Subtype = TestRunner codeunits' {
            $root = New-TempFolder
            try {
                $folder = New-AppFolder -Root $root -AppId 'rrr' -AppName 'AppRunner'
                New-ALFile -Folder $folder -Name 'Runner.al' -Content @'
codeunit 130451 "Custom Runner"
{
    Subtype = TestRunner;
    TestIsolation = Codeunit;
}

codeunit 50500 "Real Test"
{
    Subtype = Test;
    RequiredTestIsolation = Codeunit;
}
'@
                $meta = Get-ALTestCodeunitMetadata -TestAppIds @{ 'rrr' = $folder }
                $meta.Count | Should -Be 1
                $meta[0].codeunitId | Should -Be 50500
                ($meta | Where-Object codeunitId -eq 130451) | Should -BeNullOrEmpty
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'skips non-test codeunits' {
            $root = New-TempFolder
            try {
                $folder = New-AppFolder -Root $root -AppId 'ccc' -AppName 'App3'
                New-ALFile -Folder $folder -Name 'NotTest.al' -Content @'
codeunit 50300 "Business Logic"
{
    procedure Do()
    begin
    end;
}
'@
                $meta = Get-ALTestCodeunitMetadata -TestAppIds @{ 'ccc' = $folder }
                $meta.Count | Should -Be 0
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'handles multiple codeunits in one file' {
            $root = New-TempFolder
            try {
                $folder = New-AppFolder -Root $root -AppId 'ddd' -AppName 'App4'
                New-ALFile -Folder $folder -Name 'Multi.al' -Content @'
codeunit 50400 "First Test"
{
    Subtype = Test;
    RequiredTestIsolation = Codeunit;
}

codeunit 50401 "Second Test"
{
    Subtype = Test;
    RequiredTestIsolation = Function;
    TestType = AITest;
}
'@
                $meta = Get-ALTestCodeunitMetadata -TestAppIds @{ 'ddd' = $folder }
                $meta.Count | Should -Be 2
                ($meta | Where-Object codeunitId -eq 50400).requiredIsolation | Should -Be 'Codeunit'
                ($meta | Where-Object codeunitId -eq 50401).requiredIsolation | Should -Be 'Function'
                ($meta | Where-Object codeunitId -eq 50401).testType | Should -Be 'AITest'
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'tags codeunits with the owning appId across multiple apps' {
            $root = New-TempFolder
            try {
                $a = New-AppFolder -Root $root -AppId 'app-a' -AppName 'AppA'
                $b = New-AppFolder -Root $root -AppId 'app-b' -AppName 'AppB'
                New-ALFile -Folder $a -Name 'A.al' -Content "codeunit 60000 T1 { Subtype = Test; }"
                New-ALFile -Folder $b -Name 'B.al' -Content "codeunit 60001 T2 { Subtype = Test; }"
                $meta = Get-ALTestCodeunitMetadata -TestAppIds ([ordered]@{ 'app-a' = $a; 'app-b' = $b })
                ($meta | Where-Object codeunitId -eq 60000).appId | Should -Be 'app-a'
                ($meta | Where-Object codeunitId -eq 60001).appId | Should -Be 'app-b'
            }
            finally { Remove-Item -Path $root -Recurse -Force -ErrorAction SilentlyContinue }
        }

        It 'returns empty array when TestAppIds is empty' {
            $meta = Get-ALTestCodeunitMetadata -TestAppIds @{}
            $meta.Count | Should -Be 0
        }
    }

    Context 'Group-ALTestsByIsolation' {

        BeforeAll {
            $script:defaultSettings = [ordered]@{
                enabled                              = $true
                defaultRunnerCodeunitId              = 0
                runners                              = [ordered]@{
                    Disabled = 130450
                    Codeunit = 130451
                    Function = 130452
                }
                testTypeFilter                       = @()
                failOnMissingRequiredIsolationRunner = $true
            }
        }

        It 'groups None-isolation tests into the default-runner partition' {
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
                @{ appId = 'x'; codeunitId = 2; codeunitName = 'B'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
            )
            $partitions = Group-ALTestsByIsolation -Metadata $meta -Settings $script:defaultSettings
            $partitions.Count | Should -Be 1
            $partitions[0].isolationLabel | Should -Be 'None'
            $partitions[0].runnerCodeunitId | Should -Be 0
            $partitions[0].codeunits.Count | Should -Be 2
        }

        It 'routes each RequiredTestIsolation value to its mapped runner' {
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Codeunit'; testType = 'UnitTest'; filePath = '' }
                @{ appId = 'x'; codeunitId = 2; codeunitName = 'B'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = '' }
            )
            $partitions = Group-ALTestsByIsolation -Metadata $meta -Settings $script:defaultSettings
            $partitions.Count | Should -Be 2
            ($partitions | Where-Object isolationLabel -eq 'Codeunit').runnerCodeunitId | Should -Be 130451
            ($partitions | Where-Object isolationLabel -eq 'Function').runnerCodeunitId | Should -Be 130452
        }

        It 'splits on testType when codeunits share the same isolation' {
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Codeunit'; testType = 'UnitTest';        filePath = '' }
                @{ appId = 'x'; codeunitId = 2; codeunitName = 'B'; requiredIsolation = 'Codeunit'; testType = 'IntegrationTest'; filePath = '' }
            )
            $partitions = Group-ALTestsByIsolation -Metadata $meta -Settings $script:defaultSettings
            $partitions.Count | Should -Be 2
        }

        It 'applies testTypeFilter and drops non-matching codeunits' {
            $settings = [ordered]@{ } + $script:defaultSettings
            $settings.testTypeFilter = @('IntegrationTest')
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'None'; testType = 'UnitTest';        filePath = '' }
                @{ appId = 'x'; codeunitId = 2; codeunitName = 'B'; requiredIsolation = 'None'; testType = 'IntegrationTest'; filePath = '' }
            )
            $partitions = Group-ALTestsByIsolation -Metadata $meta -Settings $settings
            $partitions.Count | Should -Be 1
            $partitions[0].codeunits.Count | Should -Be 1
            $partitions[0].codeunits[0].codeunitId | Should -Be 2
        }

        It 'throws when a required isolation has no runner mapping and failOnMissingRequiredIsolationRunner is true' {
            $settings = [ordered]@{ } + $script:defaultSettings
            $settings.runners = [ordered]@{ Disabled = 0; Codeunit = 0; Function = 0 }
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = 'f.al' }
            )
            { Group-ALTestsByIsolation -Metadata $meta -Settings $settings } | Should -Throw -ExpectedMessage '*No test runner mapped*Function*'
        }

        It 'falls back to defaultRunnerCodeunitId when mapping missing and failOnMissingRequiredIsolationRunner is false' {
            $settings = [ordered]@{ } + $script:defaultSettings
            $settings.runners = [ordered]@{ Disabled = 0; Codeunit = 0; Function = 0 }
            $settings.defaultRunnerCodeunitId = 99999
            $settings.failOnMissingRequiredIsolationRunner = $false
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = 'f.al' }
            )
            $partitions = Group-ALTestsByIsolation -Metadata $meta -Settings $settings -WarningAction SilentlyContinue
            $partitions.Count | Should -Be 1
            $partitions[0].runnerCodeunitId | Should -Be 99999
        }

        It 'emits a warning when falling back due to missing runner mapping' {
            $settings = [ordered]@{ } + $script:defaultSettings
            $settings.runners = [ordered]@{ Disabled = 0; Codeunit = 0; Function = 0 }
            $settings.defaultRunnerCodeunitId = 99999
            $settings.failOnMissingRequiredIsolationRunner = $false
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = 'f.al' }
            )
            Group-ALTestsByIsolation -Metadata $meta -Settings $settings -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            $warnings.Count | Should -BeGreaterOrEqual 1
            ($warnings -join "`n") | Should -Match 'RequiredTestIsolation = Function'
            ($warnings -join "`n") | Should -Match '99999'
        }

        It 'fallback warning names the BcContainerHelper default when defaultRunnerCodeunitId is 0' {
            $settings = [ordered]@{ } + $script:defaultSettings
            $settings.runners = [ordered]@{ Disabled = 0; Codeunit = 0; Function = 0 }
            $settings.defaultRunnerCodeunitId = 0
            $settings.failOnMissingRequiredIsolationRunner = $false
            $meta = @(
                @{ appId = 'x'; codeunitId = 1; codeunitName = 'A'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = 'f.al' }
            )
            Group-ALTestsByIsolation -Metadata $meta -Settings $settings -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
            ($warnings -join "`n") | Should -Match 'BcContainerHelper default runner'
        }

        It 'returns empty array for empty metadata' {
            $partitions = Group-ALTestsByIsolation -Metadata @() -Settings $script:defaultSettings
            $partitions.Count | Should -Be 0
        }
    }

    Context 'New-PartitionedTestRunnerScriptBlock' {

        BeforeAll {
            # The generated scriptblock is bound to the module's session state and
            # looks up Run-TestsInBcContainer via the global function table. Mock by
            # installing a global stub that records calls and consults a script-scope
            # response delegate so tests can control pass/fail outcomes.
            function global:Run-TestsInBcContainer {
                [CmdletBinding()]
                Param(
                    [string] $testCodeunit,
                    [string] $testCodeunitRange,
                    [string] $testRunnerCodeunitId,
                    [string] $extensionId,
                    [string] $containerName,
                    $disabledTests,
                    [string] $JUnitResultFileName,
                    [string] $XUnitResultFileName,
                    [switch] $AppendToJUnitResultFile,
                    [switch] $AppendToXUnitResultFile,
                    [switch] $returnTrueIfAllPassed,
                    [Parameter(ValueFromRemainingArguments = $true)]
                    $rest
                )
                $call = [pscustomobject]@{
                    testCodeunit            = $testCodeunit
                    testCodeunitRange       = $testCodeunitRange
                    testRunnerCodeunitId    = $testRunnerCodeunitId
                    extensionId             = $extensionId
                    containerName           = $containerName
                    AppendToJUnitResultFile = [bool] $AppendToJUnitResultFile
                    hasRunnerId             = $PSBoundParameters.ContainsKey('testRunnerCodeunitId')
                }
                $script:RunTestsInvocations += , $call
                if ($script:RunTestsResponse -is [scriptblock]) {
                    return (& $script:RunTestsResponse $call)
                }
                return [bool] $script:RunTestsResponse
            }
        }

        AfterAll {
            Remove-Item -Path function:global:Run-TestsInBcContainer -ErrorAction SilentlyContinue
        }

        BeforeEach {
            $script:RunTestsInvocations = @()
            $script:RunTestsResponse = $true
        }

        It 'returns a scriptblock' {
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions @()
            $sb | Should -BeOfType [scriptblock]
        }

        It 'invokes Run-TestsInBcContainer once per partition with codeunit-range filter and preserves append params' {
            $partitions = @(
                @{
                    runnerCodeunitId = 130451
                    isolationLabel   = 'Codeunit'
                    testType         = 'UnitTest'
                    codeunits        = @(
                        @{ appId = 'app-a'; codeunitId = 50100; codeunitName = 'T1'; requiredIsolation = 'Codeunit'; testType = 'UnitTest'; filePath = '' }
                        @{ appId = 'app-a'; codeunitId = 50101; codeunitName = 'T2'; requiredIsolation = 'Codeunit'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions

            $incoming = @{
                extensionId             = 'app-a'
                containerName           = 'dummy'
                tenant                  = 'default'
                disabledTests           = @()
                JUnitResultFileName     = 'results.xml'
                AppendToJUnitResultFile = $true
                returnTrueIfAllPassed   = $true
            }
            $result = & $sb $incoming

            $result | Should -Be $true
            $script:RunTestsInvocations.Count | Should -Be 1
            $script:RunTestsInvocations[0].testCodeunitRange | Should -Be '50100|50101'
            $script:RunTestsInvocations[0].testRunnerCodeunitId | Should -Be '130451'
            $script:RunTestsInvocations[0].AppendToJUnitResultFile | Should -Be $true
            $script:RunTestsInvocations[0].extensionId | Should -Be 'app-a'
        }

        It 'invokes once per partition when partitions differ in isolation' {
            $partitions = @(
                @{
                    runnerCodeunitId = 130451; isolationLabel = 'Codeunit'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 50100; codeunitName = 'X'; requiredIsolation = 'Codeunit'; testType = 'UnitTest'; filePath = '' }
                    )
                }
                @{
                    runnerCodeunitId = 130452; isolationLabel = 'Function'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 50200; codeunitName = 'Y'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions
            & $sb @{ extensionId = 'a'; containerName = 'dummy' } | Out-Null

            $script:RunTestsInvocations.Count | Should -Be 2
            ($script:RunTestsInvocations | Where-Object testRunnerCodeunitId -eq '130451').testCodeunitRange | Should -Be '50100'
            ($script:RunTestsInvocations | Where-Object testRunnerCodeunitId -eq '130452').testCodeunitRange | Should -Be '50200'
        }

        It 'returns $false if any partition fails' {
            $script:RunTestsResponse = { param($call) $call.testRunnerCodeunitId -ne '130452' }

            $partitions = @(
                @{
                    runnerCodeunitId = 130451; isolationLabel = 'Codeunit'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 50100; codeunitName = 'OK'; requiredIsolation = 'Codeunit'; testType = 'UnitTest'; filePath = '' }
                    )
                }
                @{
                    runnerCodeunitId = 130452; isolationLabel = 'Function'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 50200; codeunitName = 'FAIL'; requiredIsolation = 'Function'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions

            (& $sb @{ extensionId = 'a'; containerName = 'dummy' }) | Should -Be $false
            $script:RunTestsInvocations.Count | Should -Be 2
        }

        It 'omits testRunnerCodeunitId when runner is 0 (default runner)' {
            $partitions = @(
                @{
                    runnerCodeunitId = 0
                    isolationLabel   = 'None'
                    testType         = 'UnitTest'
                    codeunits        = @(
                        @{ appId = 'a'; codeunitId = 50100; codeunitName = 'X'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions
            & $sb @{ extensionId = 'a'; containerName = 'dummy' } | Out-Null

            $script:RunTestsInvocations.Count | Should -Be 1
            $script:RunTestsInvocations[0].hasRunnerId | Should -Be $false
            $script:RunTestsInvocations[0].testCodeunitRange | Should -Be '50100'
        }

        It 'skips codeunits from other apps in the range filter' {
            $partitions = @(
                @{
                    runnerCodeunitId = 0; isolationLabel = 'None'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 1; codeunitName = 'X'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
                        @{ appId = 'b'; codeunitId = 2; codeunitName = 'Y'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions
            & $sb @{ extensionId = 'a'; containerName = 'dummy' } | Out-Null

            $script:RunTestsInvocations.Count | Should -Be 1
            $script:RunTestsInvocations[0].testCodeunitRange | Should -Be '1'
        }

        It 'returns $true and invokes nothing when no codeunits match the app' {
            $partitions = @(
                @{
                    runnerCodeunitId = 0; isolationLabel = 'None'; testType = 'UnitTest'
                    codeunits = @(
                        @{ appId = 'a'; codeunitId = 1; codeunitName = 'X'; requiredIsolation = 'None'; testType = 'UnitTest'; filePath = '' }
                    )
                }
            )
            $sb = New-PartitionedTestRunnerScriptBlock -Partitions $partitions
            $result = & $sb @{ extensionId = 'other'; containerName = 'dummy' }

            $result | Should -Be $true
            $script:RunTestsInvocations.Count | Should -Be 0
        }
    }
}
