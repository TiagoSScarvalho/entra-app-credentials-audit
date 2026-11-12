#requires -Version 7.4
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../EntraAppCredentialAudit.psm1') -Force
$module = Get-Module EntraAppCredentialAudit
& $module {
    $ErrorActionPreference = 'Stop'
    $script:Passed = 0
    function Assert($Condition, [string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:Passed++; Write-Host "PASS: $Name" }
    $now = [DateTimeOffset]'2026-11-12T12:00:00Z'
    function New-Credential([double]$Days, [string]$Start='2026-01-01T00:00:00Z') { @{ keyId='11111111-1111-1111-1111-111111111111'; displayName='Test credential'; startDateTime=$Start; endDateTime=$now.AddDays($Days).ToString('o') } }
    foreach ($case in @(@(-1,'Expired'),@(0,'Expired'),@(7,'Within7Days'),@(7.001,'Within30Days'),@(30,'Within30Days'),@(30.001,'Within60Days'),@(60,'Within60Days'),@(60.001,'Beyond60Days'))) {
        Assert ((Get-CredentialState (New-Credential $case[0]) $now).Expiry -eq $case[1]) "UTC boundary $($case[0])"
    }
    Assert ((Get-CredentialState (New-Credential 10 '2026-11-13T00:00:00Z') $now).Validity -eq 'NotYetValid') 'Future start remains distinct'
    Assert ((Get-CredentialState (New-Credential 10 '2027-01-01T00:00:00Z') $now).Validity -eq 'InvalidDateRange') 'Reversed date range'
    Assert ((Get-CredentialState @{} $now).Expiry -eq 'Unknown') 'Missing expiry is unknown'
    Assert ((Get-CredentialState @{startDateTime='bad';endDateTime='bad'} $now).Validity -eq 'Unknown') 'Invalid dates do not crash'
    $id='22222222-2222-2222-2222-222222222222'
    $app=@{id=$id;appId='33333333-3333-3333-3333-333333333333';displayName='<script>alert(1)</script>';passwordCredentials=@();keyCredentials=@()}
    $complete=@{Items=@();Complete=$true}
    $rows=ConvertTo-AuditRows @($app) @{$id=$complete} $now
    Assert ($rows.Applications[0].OwnerStatus -eq 'NoOwner') 'Empty complete owner collection is ownerless'
    Assert ($rows.Applications[0].CredentialRead -eq 'Complete' -and $rows.Applications[0].CredentialCount -eq 0) 'Empty credentials are complete'
    $rows=ConvertTo-AuditRows @($app) @{$id=@{Items=@();Complete=$false}} $now
    Assert ($rows.Applications[0].OwnerStatus -eq 'Unknown' -and $null -eq $rows.Applications[0].OwnerCount) 'Failed owners are not ownerless'
    $owner=@{id='44444444-4444-4444-4444-444444444444';'@odata.type'='#microsoft.graph.servicePrincipal';displayName=$null}
    $rows=ConvertTo-AuditRows @($app) @{$id=@{Items=@($owner);Complete=$true}} $now
    Assert ($rows.Applications[0].OwnerCount -eq 1 -and $rows.Owners[0].Details -eq 'LimitedInformation') 'Limited service-principal owner counts'
    $rows=ConvertTo-AuditRows @($app) @{$id=@{Items=@($owner);Complete=$false}} $now
    Assert ($rows.Applications[0].OwnerStatus -eq 'Unknown' -and $rows.Owners.Count -eq 1) 'Partial owner rows kept without false count'
    $missing=$app.Clone();$missing.Remove('keyCredentials')
    $rows=ConvertTo-AuditRows @($missing) @{$id=$complete} $now
    Assert ($rows.Applications[0].CredentialRead -eq 'Incomplete') 'Missing metadata is not empty metadata'
    $derived=$app.Clone();$derived['@odata.type']='#microsoft.graph.agentIdentityBlueprint'
    $rows=ConvertTo-AuditRows @($derived) @{} $now
    Assert ($rows.Applications[0].Scope -eq 'ExcludedObjectType') 'Agent blueprints excluded explicitly'
    $secret=New-Credential 5;$secret.secretText='NEVER_EXPORT_SECRET';$secret.hint='NEVER_EXPORT_HINT'
    $key=New-Credential 90;$key.type='Symmetric';$key.key='NEVER_EXPORT_KEY';$key.customKeyIdentifier='NEVER_EXPORT_IDENTIFIER'
    $app.passwordCredentials=@($secret);$app.keyCredentials=@($key)
    $rows=ConvertTo-AuditRows @($app) @{$id=$complete} $now
    Assert ($rows.Credentials[1].CredentialKind -eq 'OtherKeyCredential') 'Not every key credential is a certificate'
    Assert (($rows | ConvertTo-Json -Depth 8) -notmatch 'NEVER_EXPORT') 'Credential output is an allowlist'
    Assert ((ConvertTo-CsvCell ' =cmd') -eq '"'' =cmd"') 'Formula prefix with whitespace escaped'
    Assert ((ConvertTo-CsvCell '@SUM(A1)') -eq '"''@SUM(A1)"') 'Formula at-sign escaped'
    Assert ((ConvertTo-CsvCell (-2)) -eq '"-2"') 'Negative numeric days remain numeric'
    Assert ((ConvertTo-HtmlTable @($app) @('displayName') 'Test') -match '&lt;script&gt;') 'HTML encoding'
    $script:Calls=[System.Collections.Generic.List[string]]::new()
    function Invoke-MgGraphRequest {
        param($Method,$Uri,$OutputType,$ErrorAction)
        if($Method -ne 'GET'){throw 'Write attempted'}
        $script:Calls.Add($Uri)
        if($Uri -match 'skiptoken=two'){ return @{value=@(@{id='second'})} }
        return @{value=@(@{id='first'});'@odata.nextLink'='https://graph.microsoft.com/v1.0/applications?$skiptoken=two'}
    }
    $paged=Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications?$top=1' @{StopRequests=$false}
    Assert ($paged.Complete -and $paged.Items.Count -eq 2 -and $paged.Pages -eq 2) 'Pagination collects all pages'
    function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) @{value=@();'@odata.nextLink'='https://evil.invalid/steal'} }
    $paged=Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' @{StopRequests=$false}
    Assert (-not $paged.Complete -and $paged.ErrorCategory -eq 'InvalidPagination') 'Foreign nextLink refused'
    function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) @{value=@();'@odata.nextLink'=$Uri} }
    $paged=Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' @{StopRequests=$false}
    Assert (-not $paged.Complete -and $paged.ErrorCategory -eq 'InvalidPagination') 'Repeated nextLink refused'
    function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) throw [System.Net.Http.HttpRequestException]::new('Not exported', $null, [System.Net.HttpStatusCode]::TooManyRequests) }
    $state=@{StopRequests=$false};$paged=Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state
    Assert ($paged.HttpStatus -eq 429 -and $state.StopRequests) 'Terminal throttling stops remaining requests'
    Assert ((Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state).ErrorCategory -eq 'NotAttemptedAfterServiceFailure') 'Skipped work recorded'
    foreach ($wrapper in @('InnerException','AggregateException')) {
        foreach ($status in @(401,429,503)) {
            $inner = [System.Net.Http.HttpRequestException]::new('NEVER_EXPORT_NESTED_ERROR', $null, [System.Net.HttpStatusCode]$status)
            $script:NestedFailure = if ($wrapper -eq 'AggregateException') { [AggregateException]::new('Synthetic wrapper', [Exception[]]@($inner)) } else { [Exception]::new('Synthetic wrapper', $inner) }
            $script:NestedCalls = 0
            function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) $script:NestedCalls++; throw $script:NestedFailure }
            $state = @{StopRequests=$false}
            $failed = Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state
            $skipped = Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state
            $expected = switch ($status) { 401 {'AuthenticationRequired'} 429 {'Throttled'} 503 {'ServiceUnavailable'} }
            Assert ($failed.HttpStatus -eq $status -and $failed.ErrorCategory -eq $expected -and $state.StopRequests -and $script:NestedCalls -eq 1 -and $skipped.ErrorCategory -eq 'NotAttemptedAfterServiceFailure') "$wrapper HTTP $status stops later requests"
            Assert (($failed | ConvertTo-Json -Depth 5) -notmatch 'NEVER_EXPORT_NESTED_ERROR|Synthetic wrapper') "$wrapper HTTP $status omits raw error details"
        }
    }
    $denied = [System.Net.Http.HttpRequestException]::new('Synthetic denied read', $null, [System.Net.HttpStatusCode]::Forbidden)
    $limited = [System.Net.Http.HttpRequestException]::new('Synthetic throttling', $null, [System.Net.HttpStatusCode]::TooManyRequests)
    $script:NestedFailure = [AggregateException]::new('Multiple failures', [Exception[]]@($denied,$limited))
    $state = @{StopRequests=$false}
    $failed = Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state
    Assert ($failed.HttpStatus -eq 429 -and $state.StopRequests) 'Terminal status takes precedence across aggregate failures'
    $script:NestedFailure = [Exception]::new('Wrapper', $denied)
    $state = @{StopRequests=$false}
    $failed = Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' $state
    Assert ($failed.HttpStatus -eq 403 -and $failed.ErrorCategory -eq 'AccessDenied' -and -not $state.StopRequests) 'Wrapped denied read remains incomplete without stopping unrelated reads'
    $script:NestedFailure = [Exception]::new('No HTTP metadata', [Exception]::new('Private error text'))
    $failed = Read-GraphCollection 'https://graph.microsoft.com/v1.0/applications' @{StopRequests=$false}
    Assert ($failed.HttpStatus -eq 0 -and $failed.ErrorCategory -eq 'QueryFailed') 'Unknown nested errors retain safe generic category'
    function Get-MgContext { [pscustomobject]@{TenantId='55555555-5555-5555-5555-555555555555';AuthType='Delegated';Environment='Global';Scopes=@('Application.Read.All')} }
    $guard=$false
    try { Invoke-EntraAppCredentialAudit -ExpectedTenantId '66666666-6666-6666-6666-666666666666' -AllApplications -OutputPath './not-created' } catch { $guard=$_.Exception.Message -like 'Connect to the expected tenant*' }
    Assert $guard 'Wrong-tenant guard before reads'
    $temp=Join-Path ([IO.Path]::GetTempPath()) ('entra-audit-tests-'+[guid]::NewGuid())
    New-Item -ItemType Directory -Path $temp | Out-Null
    $result=Write-AuditReport $rows @([pscustomobject]@{Operation='Applications';ApplicationObjectId='';Status='Complete';ReturnedItems=1;Pages=1;HttpStatus=0;ErrorCategory=''}) $temp '55555555-5555-5555-5555-555555555555' $now 'Synthetic offline test'
    $contents=Get-ChildItem -LiteralPath $temp -File | Get-Content -Raw
    Assert (($contents -join '') -notmatch 'NEVER_EXPORT') 'Files omit sensitive credential fields'
    Assert (@(Import-Csv (Join-Path $temp 'credentials.csv')).Count -eq 2) 'CSV round-trip'
    Assert (@(Get-Content (Join-Path $temp 'owners.csv')).Count -eq 1) 'Empty CSV still has headers'
    Assert ((Get-Content (Join-Path $temp 'report.html') -Raw) -match '&lt;script&gt;') 'Report encodes hostile application names'
    $reportHash=(Get-FileHash (Join-Path $temp 'report.html')).Hash
    $guard=$false
    try { Invoke-EntraAppCredentialAudit -ExpectedTenantId '55555555-5555-5555-5555-555555555555' -AllApplications -OutputPath $temp } catch { $guard=$_.Exception.Message -like 'OutputPath must be a new folder*' }
    Assert ($guard -and (Get-FileHash (Join-Path $temp 'report.html')).Hash -eq $reportHash) 'Existing report cannot be overwritten'
    $script:AppFixture = $app
    $script:Requests = [System.Collections.Generic.List[object]]::new()
    function Invoke-MgGraphRequest {
        param($Method,$Uri,$OutputType,$ErrorAction)
        $script:Requests.Add([pscustomobject]@{Method=$Method;Uri=$Uri})
        if ($Uri -match '/owners$') { return @{value=@()} }
        return @{value=@($script:AppFixture)}
    }
    $liveMock = Invoke-EntraAppCredentialAudit -ExpectedTenantId '55555555-5555-5555-5555-555555555555' -ApplicationObjectId $id -OutputPath (Join-Path $temp 'selected')
    Assert ($liveMock.Applications -eq 1 -and $liveMock.Credentials -eq 2 -and $liveMock.OwnerlessApplications -eq 1 -and $liveMock.IncompleteSections -eq 0) 'Selected-app collector end to end'
    Assert (@($script:Requests | Where-Object Method -ne 'GET').Count -eq 0 -and $script:Requests.Count -eq 2) 'Collector issues only expected GET requests'
    Assert ($script:Requests[0].Uri -match '\$filter=id%20eq%20%27') 'Pilot filters by app-registration object ID'
    function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) @{value=@()} }
    $missingResult = Invoke-EntraAppCredentialAudit -ExpectedTenantId '55555555-5555-5555-5555-555555555555' -ApplicationObjectId $id -OutputPath (Join-Path $temp 'missing')
    Assert ($missingResult.IncompleteSections -eq 1 -and $missingResult.Applications -eq 0) 'Missing selected application is partial'
    $emptyResult = Invoke-EntraAppCredentialAudit -ExpectedTenantId '55555555-5555-5555-5555-555555555555' -AllApplications -OutputPath (Join-Path $temp 'empty')
    Assert ($emptyResult.IncompleteSections -eq 0 -and $emptyResult.Applications -eq 0) 'Successful empty tenant retains explicit scope'
    function Invoke-MgGraphRequest { param($Method,$Uri,$OutputType,$ErrorAction) throw [System.Net.Http.HttpRequestException]::new('Not exported', $null, [System.Net.HttpStatusCode]::Forbidden) }
    $failedResult = Invoke-EntraAppCredentialAudit -ExpectedTenantId '55555555-5555-5555-5555-555555555555' -AllApplications -OutputPath (Join-Path $temp 'denied')
    Assert ($failedResult.IncompleteSections -eq 1 -and $failedResult.OwnerlessApplications -eq 0) 'Denied inventory never becomes a clean report'
    Write-Host "Passed: $script:Passed. Synthetic output: $temp"
}
