#requires -Version 7.4
# Tiago Carvalho | https://www.tiagoscarvalho.com | MIT

<#
.SYNOPSIS
Audits locally registered application credentials and owners without changing Entra.
.EXAMPLE
./Get-EntraAppCredentialAudit.ps1 -ExpectedTenantId '<tenant-id>' -AllApplications -OutputPath ./Audit
.EXAMPLE
./Get-EntraAppCredentialAudit.ps1 -ExpectedTenantId '<tenant-id>' -ApplicationObjectId '<object-id>' -OutputPath ./Pilot
#>
[CmdletBinding(DefaultParameterSetName = 'Selected')]
param(
    [Parameter(Mandatory)][guid]$ExpectedTenantId,
    [Parameter(Mandatory, ParameterSetName = 'Selected')][guid[]]$ApplicationObjectId,
    [Parameter(Mandatory, ParameterSetName = 'All')][switch]$AllApplications,
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Authentication -MinimumVersion 2.37.0 -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'EntraAppCredentialAudit.psm1') -Force
Invoke-EntraAppCredentialAudit @PSBoundParameters
