#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys the lab's baseline Conditional Access policy set, REPORT-ONLY by default.

.DESCRIPTION
    CA001  Require MFA, all users
    CA002  Require MFA, privileged admin roles
    CA003  Block legacy authentication
    CA004  Block sign-ins from outside allowed countries
    CA005  Sign-in risk medium+ requires MFA          (-IncludeRiskPolicies, Entra ID P2)
    CA006  User risk high requires password change    (-IncludeRiskPolicies, Entra ID P2)

    CA002 targets admin ROLES and the SG-Admin-Accounts group: role targeting alone did not cover an
    administrative-unit-scoped Helpdesk Administrator in testing.

    Safety:
      * Break-glass accounts are put in an exclusion group that every policy excludes.
      * Policies that already exist (by display name) are left alone.
      * Default state is report-only. Review results in Sign-in logs > Report-only and the
        What If tool for a few days, then enforce one policy at a time:
          Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId <id> -State enabled
      * Security Defaults must be disabled before Conditional Access policies can be enforced.

.EXAMPLE
    ./Deploy-ConditionalAccess.ps1 -BreakGlassUpn bg-admin1@contoso.onmicrosoft.com,bg-admin2@contoso.onmicrosoft.com -WhatIf
.EXAMPLE
    ./Deploy-ConditionalAccess.ps1 -BreakGlassUpn bg1@contoso.onmicrosoft.com,bg2@contoso.onmicrosoft.com -IncludeRiskPolicies
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string[]]$BreakGlassUpn,
    [string]$ExclusionGroupName = 'SG-CA-Exclusions',
    [string]$AdminGroupName = 'SG-Admin-Accounts',
    [string[]]$AdminAccountUpn = @(),   # all admin accounts EXCEPT break-glass; CA002 targets this group as well as roles
    [string[]]$AllowedCountries = @('US'),
    [ValidateSet('enabledForReportingButNotEnforced', 'disabled', 'enabled')]
    [string]$State = 'enabledForReportingButNotEnforced',
    [string[]]$AdminRoleNames = @(
        'Global Administrator', 'Privileged Role Administrator', 'Security Administrator', 'Exchange Administrator',
        'User Administrator', 'Helpdesk Administrator', 'SharePoint Administrator', 'Conditional Access Administrator',
        'Application Administrator', 'Authentication Administrator'
    ),
    [switch]$IncludeRiskPolicies,
    [string]$LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'ca-deploy.log')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Initialize-LabLog -Path $LogPath
Assert-LabConnection -Graph

if ($State -eq 'enabled' -and -not $WhatIfPreference) {
    if (-not $PSCmdlet.ShouldContinue('Policies will be ENFORCED immediately. Have you reviewed report-only results and tested the break-glass accounts?', 'Enforce Conditional Access')) { return }
}

# ---- 1. Exclusion group containing the break-glass accounts
$group = Get-MgGroup -Filter "displayName eq '$ExclusionGroupName'" -ErrorAction SilentlyContinue
if (-not $group) {
    if ($PSCmdlet.ShouldProcess($ExclusionGroupName, 'Create exclusion group')) {
        $group = New-MgGroup -DisplayName $ExclusionGroupName -MailEnabled:$false -MailNickname ($ExclusionGroupName -replace '[^A-Za-z0-9]', '').ToLower() -SecurityEnabled:$true -GroupTypes @()
        Write-LabLog "Created $ExclusionGroupName ($($group.Id))" ACTION
    }
}
if ($group) {
    $current = @(Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object { $_.Id })
    foreach ($bg in $BreakGlassUpn) {
        $bgUser = Get-MgUser -Filter "userPrincipalName eq '$bg'" -ErrorAction SilentlyContinue
        if (-not $bgUser) { throw "Break-glass account $bg not found. Create it before deploying policies." }
        if ($current -contains $bgUser.Id) { continue }
        if ($PSCmdlet.ShouldProcess($bg, "Add to $ExclusionGroupName")) {
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $bgUser.Id
            Write-LabLog "Added $bg to $ExclusionGroupName" ACTION
        }
    }
}
$excludeGroupId = if ($group) { $group.Id } else { '00000000-0000-0000-0000-000000000000' }  # placeholder in -WhatIf only

# ---- 1b. Admin accounts group (role targeting alone misses administrative-unit-scoped admins)
$adminGroup = Get-MgGroup -Filter "displayName eq '$AdminGroupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $adminGroup -and $PSCmdlet.ShouldProcess($AdminGroupName, 'Create admin accounts group')) {
    $adminGroup = New-MgGroup -DisplayName $AdminGroupName -Description 'All admin accounts (CA002 targets this group in addition to roles). Never add break-glass accounts.' `\
        -MailEnabled:$false -MailNickname (($AdminGroupName -replace '[^A-Za-z0-9]', '').ToLower()) -SecurityEnabled:$true -GroupTypes @()
    Write-LabLog "Created $AdminGroupName ($($adminGroup.Id))" ACTION
}
if ($adminGroup) {
    $adminCurrent = @(Get-MgGroupMember -GroupId $adminGroup.Id -All | ForEach-Object Id)
    foreach ($upn in $AdminAccountUpn) {
        if ($upn -in $BreakGlassUpn) { Write-LabLog "Refusing to add break-glass account $upn to $AdminGroupName" WARN; continue }
        $au = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if (-not $au) { Write-LabLog "Admin account $upn not found" WARN; continue }
        if ($adminCurrent -contains $au.Id) { continue }
        if ($PSCmdlet.ShouldProcess($upn, "Add to $AdminGroupName")) {
            New-MgGroupMember -GroupId $adminGroup.Id -DirectoryObjectId $au.Id
            Write-LabLog "Added $upn to $AdminGroupName" ACTION
        }
    }
}
$adminGroupId = if ($adminGroup) { $adminGroup.Id } else { '00000000-0000-0000-0000-000000000000' }  # placeholder in -WhatIf only

# ---- 2. Named location for allowed countries
$nlName = 'NL-Allowed-Countries'
$nl = Get-MgIdentityConditionalAccessNamedLocation -All | Where-Object { $_.DisplayName -eq $nlName }
if (-not $nl -and $PSCmdlet.ShouldProcess($nlName, "Create country named location ($($AllowedCountries -join ','))")) {
    $nl = New-MgIdentityConditionalAccessNamedLocation -BodyParameter @{
        '@odata.type'                    = '#microsoft.graph.countryNamedLocation'
        displayName                      = $nlName
        countriesAndRegions              = $AllowedCountries
        includeUnknownCountriesAndRegions = $false
    }
    Write-LabLog "Created named location $nlName" ACTION
}
$locationId = if ($nl) { $nl.Id } else { '00000000-0000-0000-0000-000000000000' }

# ---- 3. Resolve admin role template IDs by name (avoids hard-coded GUIDs)
$templates = Get-MgDirectoryRoleTemplate -All
$adminRoleIds = foreach ($n in $AdminRoleNames) {
    $t = $templates | Where-Object { $_.DisplayName -eq $n }
    if ($t) { $t.Id } else { Write-LabLog "Role template not found: $n" WARN }
}

# ---- 4. Policy definitions
$allUsersExcl = @{ includeUsers = @('All'); excludeGroups = @($excludeGroupId) }
$allApps      = @{ includeApplications = @('All') }

$policies = [ordered]@{
    'CA001-Require-MFA-AllUsers' = @{
        conditions    = @{ users = $allUsersExcl; applications = $allApps; clientAppTypes = @('all') }
        grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
    }
    'CA002-Require-MFA-Admins' = @{
        conditions    = @{ users = @{ includeRoles = @($adminRoleIds); includeGroups = @($adminGroupId); excludeGroups = @($excludeGroupId) }; applications = $allApps; clientAppTypes = @('all') }
        grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
    }
    'CA003-Block-Legacy-Auth' = @{
        conditions    = @{ users = $allUsersExcl; applications = $allApps; clientAppTypes = @('exchangeActiveSync', 'other') }
        grantControls = @{ operator = 'OR'; builtInControls = @('block') }
    }
    'CA004-Block-Untrusted-Countries' = @{
        conditions    = @{ users = $allUsersExcl; applications = $allApps; clientAppTypes = @('all')
                           locations = @{ includeLocations = @('All'); excludeLocations = @($locationId) } }
        grantControls = @{ operator = 'OR'; builtInControls = @('block') }
    }
}
if ($IncludeRiskPolicies) {
    $policies['CA005-SignInRisk-Medium-Require-MFA'] = @{
        conditions    = @{ users = $allUsersExcl; applications = $allApps; clientAppTypes = @('all'); signInRiskLevels = @('medium', 'high') }
        grantControls = @{ operator = 'OR'; builtInControls = @('mfa') }
    }
    $policies['CA006-UserRisk-High-Password-Change'] = @{
        conditions    = @{ users = $allUsersExcl; applications = $allApps; clientAppTypes = @('all'); userRiskLevels = @('high') }
        grantControls = @{ operator = 'AND'; builtInControls = @('mfa', 'passwordChange') }
    }
}

# ---- 5. Create (or re-check) and READ BACK what the tenant actually stored
function Test-PolicyShape {
    param([string]$PolicyId, [string]$Name, [hashtable]$ExpectedUsers)
    $actual = Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $PolicyId
    $ok = $true
    foreach ($k in 'IncludeUsers', 'IncludeGroups', 'IncludeRoles', 'ExcludeGroups') {
        $key = $k.Substring(0, 1).ToLower() + $k.Substring(1)
        $exp = @(@($ExpectedUsers[$key]) | Where-Object { $_ } | Sort-Object)
        $act = @(@($actual.Conditions.Users.$k) | Where-Object { $_ } | Sort-Object)
        if (($exp -join ',') -ne ($act -join ',')) {
            Write-LabLog "DRIFT in ${Name}: $k expected [$($exp -join ',')] but tenant has [$($act -join ',')]" ERROR
            $ok = $false
        }
    }
    if ($ok) { Write-LabLog "Verified $Name (users conditions match the intended definition)" }
    return $ok
}

$existing = @(Get-MgIdentityConditionalAccessPolicy -All)
$failures = 0
foreach ($name in $policies.Keys) {
    $found = $existing | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1
    $expectedUsers = $policies[$name].conditions.users
    if ($found) {
        Write-LabLog "Exists, leaving unchanged: $name"
        if (-not $WhatIfPreference -and -not (Test-PolicyShape -PolicyId $found.Id -Name $name -ExpectedUsers $expectedUsers)) { $failures++ }
        continue
    }
    $body = $policies[$name] + @{ displayName = $name; state = $State }
    if ($PSCmdlet.ShouldProcess($name, "Create policy (state: $State)")) {
        try {
            $p = New-MgIdentityConditionalAccessPolicy -BodyParameter $body
            Write-LabLog "Created $name ($($p.Id)) state=$State" ACTION
            if (-not (Test-PolicyShape -PolicyId $p.Id -Name $name -ExpectedUsers $expectedUsers)) { $failures++ }
        } catch { Write-LabLog "Failed to create ${name}: $($_.Exception.Message)" ERROR; $failures++ }
    } else { Write-LabLog "Would create $name (state: $State)" WHATIF }
}

if ($failures -gt 0) {
    Write-LabLog "$failures policy/policies do NOT match the intended definition. Do not enforce anything until fixed." ERROR
} elseif (-not $WhatIfPreference) {
    Write-LabLog 'All policy user conditions verified against the intended definitions.' ACTION
}
Write-LabLog 'Next: review Sign-in logs > Report-only tab and the What If tool, record expected vs actual, then enforce CA003, CA002, CA001 in that order.'
