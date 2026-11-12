#requires -Version 7.4
# Tiago Carvalho | https://www.tiagoscarvalho.com | MIT
Set-StrictMode -Version Latest
$script:Version = '1.0.0'

function Get-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Test-Field($Object, [string]$Name) {
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-SafeError($Record) {
    $pending = [System.Collections.Generic.Queue[Exception]]::new()
    $seen = [System.Collections.Generic.HashSet[Exception]]::new()
    $statuses = [System.Collections.Generic.List[int]]::new()
    if ($Record.Exception -is [Exception]) { $pending.Enqueue($Record.Exception) }
    while ($pending.Count -and $seen.Count -lt 32) {
        $exception = $pending.Dequeue()
        if (-not $seen.Add($exception)) { continue }
        foreach ($candidate in @((Get-Field $exception 'ResponseStatusCode'), (Get-Field $exception 'StatusCode'), (Get-Field (Get-Field $exception 'Response') 'StatusCode'))) {
            $code = 0
            if ($null -ne $candidate) { try { $code = [int]$candidate } catch { } }
            if ($code -ge 400 -and $code -le 599) { $statuses.Add($code); break }
        }
        foreach ($inner in @($exception.InnerException, (Get-Field (Get-Field $exception 'ErrorRecord') 'Exception'))) {
            if ($inner -is [Exception]) { $pending.Enqueue($inner) }
        }
        if ($exception -is [AggregateException]) {
            foreach ($inner in $exception.InnerExceptions) { $pending.Enqueue($inner) }
        }
    }
    $status = 0
    foreach ($code in $statuses) {
        if (-not $status) { $status = $code }
        if ($code -eq 429 -or $code -eq 401 -or $code -ge 500) { $status = $code; break }
    }
    $category = switch ($status) {
        401 { 'AuthenticationRequired' } 403 { 'AccessDenied' } 404 { 'NotFound' }
        429 { 'Throttled' } { $_ -ge 500 } { 'ServiceUnavailable' } default { 'QueryFailed' }
    }
    [pscustomobject]@{ HttpStatus = $status; Category = $category }
}

function Read-GraphCollection([string]$Uri, [hashtable]$RunState) {
    $items = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $initial = [uri]$Uri
    $complete = $true; $errorCategory = ''; $httpStatus = 0; $pageCount = 0
    while ($Uri) {
        if ($RunState.StopRequests) { $complete = $false; $errorCategory = 'NotAttemptedAfterServiceFailure'; break }
        $pageUri = [uri]$Uri
        if ($pageUri.Scheme -ne 'https' -or $pageUri.Host -ne 'graph.microsoft.com' -or $pageUri.Port -ne 443 -or $pageUri.UserInfo -or $pageUri.AbsolutePath -ne $initial.AbsolutePath -or -not $visited.Add($Uri)) {
            $complete = $false; $errorCategory = 'InvalidPagination'; break
        }
        try {
            $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
            if (-not (Test-Field $page 'value') -or $null -eq (Get-Field $page 'value')) { throw 'Unexpected collection shape.' }
            foreach ($item in (Get-Field $page 'value')) { $items.Add($item) }
            $pageCount++
            $Uri = [string](Get-Field $page '@odata.nextLink')
        } catch {
            $safe = Get-SafeError $_
            $complete = $false; $errorCategory = $safe.Category; $httpStatus = $safe.HttpStatus
            if ($httpStatus -eq 429 -or $httpStatus -eq 401 -or $httpStatus -ge 500) { $RunState.StopRequests = $true }
            break
        }
    }
    [pscustomobject]@{ Items = $items.ToArray(); Complete = $complete; ErrorCategory = $errorCategory; HttpStatus = $httpStatus; Pages = $pageCount }
}

function Get-CredentialState($Credential, [DateTimeOffset]$AsOf) {
    $start = [DateTimeOffset]::MinValue; $end = [DateTimeOffset]::MinValue
    $startOk = [DateTimeOffset]::TryParse([string](Get-Field $Credential 'startDateTime'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$start)
    $endOk = [DateTimeOffset]::TryParse([string](Get-Field $Credential 'endDateTime'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$end)
    $expiry = 'Unknown'; $validity = 'Unknown'; $days = $null
    if ($endOk) {
        $remaining = ($end - $AsOf).TotalDays
        $days = [math]::Ceiling($remaining)
        $expiry = if ($end -le $AsOf) { 'Expired' } elseif ($remaining -le 7) { 'Within7Days' } elseif ($remaining -le 30) { 'Within30Days' } elseif ($remaining -le 60) { 'Within60Days' } else { 'Beyond60Days' }
    }
    if ($startOk -and $endOk) {
        $validity = if ($end -le $start) { 'InvalidDateRange' } elseif ($end -le $AsOf) { 'Expired' } elseif ($start -gt $AsOf) { 'NotYetValid' } else { 'WithinValidityDates' }
    }
    [pscustomobject]@{
        StartUtc = $(if ($startOk) { $start.UtcDateTime.ToString('o') } else { '' })
        EndUtc = $(if ($endOk) { $end.UtcDateTime.ToString('o') } else { '' })
        DaysRemaining = $days; Expiry = $expiry; Validity = $validity
    }
}

function ConvertTo-AuditRows([object[]]$Applications, [hashtable]$OwnerResults, [DateTimeOffset]$AsOf) {
    $apps = [System.Collections.Generic.List[object]]::new()
    $credentials = [System.Collections.Generic.List[object]]::new()
    $owners = [System.Collections.Generic.List[object]]::new()
    foreach ($app in $Applications) {
        $id = [string](Get-Field $app 'id'); $appId = [string](Get-Field $app 'appId'); $name = [string](Get-Field $app 'displayName')
        $type = [string](Get-Field $app '@odata.type')
        if (-not $type) { $type = '#microsoft.graph.application' }
        $included = $type -eq '#microsoft.graph.application'
        if (-not $included) {
            $apps.Add([pscustomobject][ordered]@{ ApplicationObjectId=$id; ClientId=$appId; DisplayName=$name; ObjectType=$type; Scope='ExcludedObjectType'; OwnerRead='NotInScope'; OwnerCount=$null; OwnerStatus='NotInScope'; CredentialRead='NotInScope'; CredentialCount=$null; Expired=0; DueWithin60Days=0; UnknownDates=0; Review='Outside ordinary app-registration scope' })
            continue
        }
        $ownerRead = $OwnerResults[$id]
        $ownerItems = @(); $ownerCount = $null; $ownerStatus = 'Unknown'; $readStatus = 'Incomplete'
        if ($null -ne $ownerRead) {
            $ownerItems = @($ownerRead.Items | Sort-Object { Get-Field $_ 'id' } -Unique)
            if ($ownerRead.Complete) {
                $readStatus = 'Complete'; $ownerCount = $ownerItems.Count
                $ownerStatus = if ($ownerCount -eq 0) { 'NoOwner' } elseif ($ownerCount -eq 1) { 'SingleOwner' } else { 'MultipleOwners' }
            }
        }
        foreach ($owner in $ownerItems) {
            $ownerName = [string](Get-Field $owner 'displayName')
            $owners.Add([pscustomobject][ordered]@{ ApplicationObjectId=$id; ApplicationName=$name; OwnerObjectId=[string](Get-Field $owner 'id'); OwnerType=[string](Get-Field $owner '@odata.type'); DisplayName=$ownerName; Details=$(if ($ownerName) { 'NameReturned' } else { 'LimitedInformation' }); CollectionRead=$readStatus })
        }
        $completeCredentials = $true; $count = 0; $expired = 0; $due = 0; $unknown = 0; $notYet = 0
        foreach ($collection in @('passwordCredentials', 'keyCredentials')) {
            if (-not (Test-Field $app $collection) -or $null -eq (Get-Field $app $collection)) { $completeCredentials = $false; continue }
            foreach ($credential in (Get-Field $app $collection)) {
                $state = Get-CredentialState $credential $AsOf
                $count++
                if ($state.Expiry -eq 'Expired') { $expired++ }
                if ($state.Expiry -in @('Within7Days','Within30Days','Within60Days')) { $due++ }
                if ($state.Validity -in @('Unknown','InvalidDateRange')) { $unknown++ }
                if ($state.Validity -eq 'NotYetValid') { $notYet++ }
                $kind = if ($collection -eq 'passwordCredentials') { 'ClientSecret' } elseif ((Get-Field $credential 'type') -eq 'AsymmetricX509Cert') { 'Certificate' } else { 'OtherKeyCredential' }
                $credentials.Add([pscustomobject][ordered]@{ ApplicationObjectId=$id; ClientId=$appId; ApplicationName=$name; CredentialKind=$kind; KeyId=[string](Get-Field $credential 'keyId'); DisplayName=[string](Get-Field $credential 'displayName'); KeyType=[string](Get-Field $credential 'type'); Usage=[string](Get-Field $credential 'usage'); StartUtc=$state.StartUtc; EndUtc=$state.EndUtc; DaysRemaining=$state.DaysRemaining; Expiry=$state.Expiry; Validity=$state.Validity; OwnerStatus=$ownerStatus })
            }
        }
        $review = [System.Collections.Generic.List[string]]::new()
        if (-not $completeCredentials -or $readStatus -ne 'Complete') { $review.Add('Incomplete read') }
        if ($ownerStatus -eq 'NoOwner') { $review.Add('Assign accountable owners after review') }
        if ($ownerStatus -eq 'SingleOwner') { $review.Add('Review backup ownership') }
        if ($expired) { $review.Add('Review expired credentials; usage not measured') }
        if ($due) { $review.Add('Plan renewal and workload validation') }
        if ($unknown -or $notYet) { $review.Add('Review credential validity dates') }
        if ($completeCredentials -and $count -eq 0) { $review.Add('No stored password/key credentials; authentication method not assessed') }
        if (-not $review.Count) { $review.Add('No selected findings; not a security assurance') }
        $apps.Add([pscustomobject][ordered]@{ ApplicationObjectId=$id; ClientId=$appId; DisplayName=$name; ObjectType=$type; Scope='Included'; OwnerRead=$readStatus; OwnerCount=$ownerCount; OwnerStatus=$ownerStatus; CredentialRead=$(if ($completeCredentials) { 'Complete' } else { 'Incomplete' }); CredentialCount=$(if ($completeCredentials) { $count } else { $null }); Expired=$expired; DueWithin60Days=$due; UnknownDates=$unknown; Review=$review -join '; ' })
    }
    [pscustomobject]@{ Applications=$apps.ToArray(); Credentials=$credentials.ToArray(); Owners=$owners.ToArray() }
}

function ConvertTo-CsvCell($Value) {
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($Value -is [string] -and $text -match '^[\s\p{Cf}]*[=+@-]') { $text = "'" + $text }
    '"' + $text.Replace('"','""') + '"'
}

function Write-AuditCsv([string]$Path, [object[]]$Rows, [string[]]$Columns) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(($Columns | ForEach-Object { ConvertTo-CsvCell $_ }) -join ',')
    foreach ($row in $Rows) { $lines.Add(($Columns | ForEach-Object { ConvertTo-CsvCell (Get-Field $row $_) }) -join ',') }
    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($true))
}

function ConvertTo-HtmlTable([object[]]$Rows, [string[]]$Columns, [string]$Label) {
    $encode = { param($v) [Net.WebUtility]::HtmlEncode([string]$v) }
    if (-not $Rows.Count) { return '<p>No rows returned for this table. Check coverage before interpreting an empty result.</p>' }
    $head = ($Columns | ForEach-Object { '<th scope="col">' + (& $encode $_) + '</th>' }) -join ''
    $body = foreach ($row in $Rows) { '<tr>' + (($Columns | ForEach-Object { '<td>' + (& $encode (Get-Field $row $_)) + '</td>' }) -join '') + '</tr>' }
    '<div class="table" role="region" tabindex="0" aria-label="' + (& $encode $Label) + '"><table><thead><tr>' + $head + '</tr></thead><tbody>' + ($body -join '') + '</tbody></table></div>'
}

function Write-AuditReport($Rows, [object[]]$Coverage, [string]$OutputPath, [string]$TenantId, [DateTimeOffset]$AsOf, [string]$Scope) {
    $appColumns = @('ApplicationObjectId','ClientId','DisplayName','ObjectType','Scope','OwnerRead','OwnerCount','OwnerStatus','CredentialRead','CredentialCount','Expired','DueWithin60Days','UnknownDates','Review')
    $credentialColumns = @('ApplicationObjectId','ClientId','ApplicationName','CredentialKind','KeyId','DisplayName','KeyType','Usage','StartUtc','EndUtc','DaysRemaining','Expiry','Validity','OwnerStatus')
    $ownerColumns = @('ApplicationObjectId','ApplicationName','OwnerObjectId','OwnerType','DisplayName','Details','CollectionRead')
    $coverageColumns = @('Operation','ApplicationObjectId','Status','ReturnedItems','Pages','HttpStatus','ErrorCategory')
    Write-AuditCsv (Join-Path $OutputPath 'applications.csv') $Rows.Applications $appColumns
    Write-AuditCsv (Join-Path $OutputPath 'credentials.csv') $Rows.Credentials $credentialColumns
    Write-AuditCsv (Join-Path $OutputPath 'owners.csv') $Rows.Owners $ownerColumns
    Write-AuditCsv (Join-Path $OutputPath 'coverage.csv') $Coverage $coverageColumns
    $incomplete = @($Coverage | Where-Object Status -ne 'Complete').Count + @($Rows.Applications | Where-Object { $_.Scope -eq 'Included' -and $_.CredentialRead -ne 'Complete' }).Count
    $status = if ($incomplete) { 'PARTIAL — review coverage' } else { 'COMPLETE for the stated scope' }
    $included = @($Rows.Applications | Where-Object Scope -eq 'Included')
    $excluded = @($Rows.Applications | Where-Object Scope -ne 'Included').Count
    $ownerless = @($included | Where-Object OwnerStatus -eq 'NoOwner').Count
    $expired = @($Rows.Credentials | Where-Object Expiry -eq 'Expired').Count
    $due = @($Rows.Credentials | Where-Object Expiry -in @('Within7Days','Within30Days','Within60Days')).Count
    $appsTable = ConvertTo-HtmlTable $Rows.Applications @('DisplayName','OwnerStatus','OwnerCount','CredentialCount','Expired','DueWithin60Days','Review') 'Application review'
    $credsTable = ConvertTo-HtmlTable $Rows.Credentials @('ApplicationName','CredentialKind','KeyId','EndUtc','Expiry','Validity','OwnerStatus') 'Credential review'
    $ownersTable = ConvertTo-HtmlTable $Rows.Owners @('ApplicationName','OwnerObjectId','OwnerType','DisplayName','Details','CollectionRead') 'Owner evidence'
    $coverageTable = ConvertTo-HtmlTable $Coverage $coverageColumns 'Query coverage'
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><title>Entra application credentials audit</title><style>
:root{color-scheme:light}*{box-sizing:border-box}body{font:16px/1.6 system-ui,Segoe UI,sans-serif;color:#19334b;background:#f5f8fb;margin:0}main{max-width:1450px;margin:auto;padding:32px}h1{font-size:clamp(28px,4vw,42px);line-height:1.15}h2{margin-top:42px}a{color:#075d70}a:focus-visible,.table:focus-visible{outline:3px solid #af7200;outline-offset:4px}.status{background:#e3edf4;border-left:5px solid #075d70;padding:18px}.cards{display:flex;gap:14px;flex-wrap:wrap;margin:25px 0}.card{background:white;border:1px solid #cad9e3;padding:16px 22px;flex:1;min-width:170px}.card strong{display:block;font-size:32px}.table{overflow:auto;background:white;border:1px solid #cad9e3}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:10px 12px;border-bottom:1px solid #dce5eb;text-align:left;vertical-align:top;min-width:125px;max-width:460px;overflow-wrap:anywhere}th{background:#eaf1f5}nav{display:flex;gap:20px;flex-wrap:wrap}small{color:#4e6577}.note{padding:15px;background:#fff6dd}footer{border-top:1px solid #cad9e3;margin-top:35px;padding-top:20px}@media(max-width:600px){main{padding:18px}.card{min-width:135px}}@media print{.table{overflow:visible}main{padding:0}table{font-size:10px}}
</style></head><body><main><p>TIAGO CARVALHO · ADMIN TOOLS · $script:Version</p><h1>Entra application credentials audit</h1><p>Read-only inventory · $($AsOf.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC</p><div class="status"><strong>$status</strong><br>Tenant: $TenantId<br>Scope: $([Net.WebUtility]::HtmlEncode($Scope)) · $excluded nonstandard object(s) excluded.</div><div class="cards"><div class="card"><strong>$($included.Count)</strong>Applications returned</div><div class="card"><strong>$ownerless</strong>Confirmed without owners</div><div class="card"><strong>$expired</strong>Expired credentials</div><div class="card"><strong>$due</strong>Expire within 60 days</div></div><nav aria-label="Report sections"><a href="#applications">Applications</a><a href="#credentials">Credentials</a><a href="#owners">Owners</a><a href="#coverage">Coverage</a></nav><p class="note">Expiry is metadata, not proof that a credential is used or an application is broken. No stored credentials can be legitimate. A failed owner query is Unknown, never NoOwner. One owner is a continuity review, not a breach finding.</p><p>Files: <a href="applications.csv" download>Applications CSV</a> · <a href="credentials.csv" download>Credentials CSV</a> · <a href="owners.csv" download>Owners CSV</a> · <a href="coverage.csv" download>Coverage CSV</a></p><h2 id="applications">1. Application review</h2>$appsTable<h2 id="credentials">2. Credential metadata</h2><p>Disjoint windows: expired, within 7 days, more than 7 to 30, more than 30 to 60, beyond 60. Dates are UTC. CSV DaysRemaining is rounded up; status uses exact timestamps.</p>$credsTable<h2 id="owners">3. Owner evidence</h2><p>An owner ID with limited details still counts. Names do not prove that an owner is active or accountable. Incomplete collections can contain only some owners.</p>$ownersTable<h2 id="coverage">4. Query coverage</h2><p>Complete means these reads finished, not that the tenant is secure. The inventory is not an atomic snapshot. Compare a finding in Entra before acting.</p>$coverageTable<h2>Scope limits</h2><p>Ordinary app registrations in this tenant only. This report does not inspect enterprise-application-only credentials, SAML signing certificates, managed identities, credentials held in another tenant, federated identity credentials, permissions, sign-in activity or workload health. Agent identity blueprints and other explicit derived object types are excluded and listed. No secret values, secret hints, certificate bytes or raw error payloads are exported.</p><footer>Tiago Carvalho · <a href="https://www.tiagoscarvalho.com">tiagoscarvalho.com</a> · Keep reports inside your authorised administration boundary. This code has an author attribution; it is not digitally signed.</footer></main></body></html>
"@
    [IO.File]::WriteAllText((Join-Path $OutputPath 'report.html'), $html, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Version=$script:Version; ReportStatus=$status; Applications=$included.Count; ExcludedObjects=$excluded; Credentials=$Rows.Credentials.Count; OwnerlessApplications=$ownerless; ExpiredCredentials=$expired; DueWithin60Days=$due; IncompleteSections=$incomplete; ReportPath=(Join-Path $OutputPath 'report.html') }
}

function Invoke-EntraAppCredentialAudit {
    [CmdletBinding(DefaultParameterSetName = 'Selected')]
    param(
        [Parameter(Mandatory)][guid]$ExpectedTenantId,
        [Parameter(Mandatory,ParameterSetName='Selected')][guid[]]$ApplicationObjectId,
        [Parameter(Mandatory,ParameterSetName='All')][switch]$AllApplications,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $ErrorActionPreference = 'Stop'
    $context = Get-MgContext
    if ($null -eq $context -or $context.TenantId -ne $ExpectedTenantId.ToString() -or $context.AuthType -ne 'Delegated' -or $context.Environment -ne 'Global') { throw 'Connect to the expected tenant in the Global cloud with delegated authentication first. No tenant query was made.' }
    if (-not @($context.Scopes | Where-Object { $_ -in @('Application.Read.All','Directory.Read.All','Application.ReadWrite.All','Directory.ReadWrite.All') }).Count) { throw 'The connection lacks an application inventory scope. Application.Read.All is the documented minimum.' }
    if (-not $AllApplications -and -not $ApplicationObjectId.Count) { throw 'Select at least one application object ID.' }
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $target) { throw 'OutputPath must be a new folder; existing reports are never overwritten.' }
    $asOf = [DateTimeOffset]::UtcNow
    $runState = @{ StopRequests=$false }
    $apps = [System.Collections.Generic.List[object]]::new()
    $coverage = [System.Collections.Generic.List[object]]::new()
    $owners = @{}
    $select = 'id,appId,displayName,passwordCredentials,keyCredentials'
    $queries = if ($AllApplications) { @('https://graph.microsoft.com/v1.0/applications?$select=' + $select + '&$top=100') } else {
        @($ApplicationObjectId | Select-Object -Unique | ForEach-Object { 'https://graph.microsoft.com/v1.0/applications?$filter=id%20eq%20%27' + $_.ToString() + '%27&$select=' + $select })
    }
    foreach ($query in $queries) {
        $result = Read-GraphCollection $query $runState
        foreach ($app in $result.Items) { $apps.Add($app) }
        $queryComplete = $result.Complete
        $category = $result.ErrorCategory
        if (-not $AllApplications -and $result.Complete -and $result.Items.Count -ne 1) { $queryComplete=$false; $category='SelectedApplicationNotReturned' }
        $coverage.Add([pscustomobject][ordered]@{ Operation='Applications'; ApplicationObjectId=''; Status=$(if ($queryComplete) {'Complete'} else {'Incomplete'}); ReturnedItems=$result.Items.Count; Pages=$result.Pages; HttpStatus=$result.HttpStatus; ErrorCategory=$category })
    }
    $uniqueApps = @($apps.ToArray() | Sort-Object { Get-Field $_ 'id' } -Unique)
    foreach ($app in $uniqueApps) {
        $type = [string](Get-Field $app '@odata.type')
        if ($type -and $type -ne '#microsoft.graph.application') { continue }
        $id = [string](Get-Field $app 'id'); $parsed = [guid]::Empty
        if (-not [guid]::TryParse($id,[ref]$parsed)) { throw 'Graph returned an application without a valid object ID. No report was written.' }
        $result = Read-GraphCollection ('https://graph.microsoft.com/v1.0/applications/' + $id + '/owners') $runState
        $owners[$id] = $result
        $coverage.Add([pscustomobject][ordered]@{ Operation='Owners'; ApplicationObjectId=$id; Status=$(if ($result.Complete) {'Complete'} else {'Incomplete'}); ReturnedItems=$result.Items.Count; Pages=$result.Pages; HttpStatus=$result.HttpStatus; ErrorCategory=$result.ErrorCategory })
    }
    $rows = ConvertTo-AuditRows $uniqueApps $owners $asOf
    New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
    $scope = if ($AllApplications) { 'All ordinary app registrations returned by Microsoft Graph' } else { 'Selected application object IDs: ' + ($ApplicationObjectId -join ', ') }
    Write-AuditReport $rows $coverage.ToArray() $target $ExpectedTenantId.ToString() $asOf $scope
}
Export-ModuleMember -Function Invoke-EntraAppCredentialAudit
