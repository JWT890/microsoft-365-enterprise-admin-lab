#Requires -Version 7.0
<#
.SYNOPSIS
    Day 2: builds the access model from data/access-model.json. Idempotent.

.DESCRIPTION
    1. Creates separate admin accounts (unlicensed, cloud-only, forced password change at first sign-in).
    2. Creates assigned security groups and nests the dynamic DG- department groups inside them.
    3. Creates administrative units and fills them from the Department attribute.
    4. Creates role-assignable groups, assigns Entra roles to the group, adds members.
    5. Assigns roles to admin accounts (tenant-wide, or scoped to an administrative unit).
       -AssignmentType Active    permanent assignment, so you can test the boundaries right away
       -AssignmentType Eligible  PIM-eligible (must activate; needs Entra ID P2). Activation rules (MFA,
                                 justification, duration) are set in the portal: see the Day 2 checklist.
    6. Optionally creates two break-glass Global Admins (-CreateBreakGlass). Their passwords are shown ONCE
       on screen and are never written to a file or the log. Store them offline immediately.
    7. Writes output/role-matrix.csv for your documentation.

    Prerequisites: New-LabUsers.ps1 -CreateDepartmentGroups has run (DG- groups and users exist).
    Run with -WhatIf first.

.EXAMPLE
    ./New-LabAccessModel.ps1 -Domain jon-maillab.org -WhatIf
.EXAMPLE
    ./New-LabAccessModel.ps1 -Domain jon-maillab.org -CreateBreakGlass -BreakGlassDomain patchlab26.onmicrosoft.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Domain,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'access-model.json'),
    [ValidateSet('Active', 'Eligible')][string]$AssignmentType = 'Active',
    [switch]$CreateBreakGlass,
    [string]$BreakGlassDomain,
    [string[]]$BreakGlassNames = @('bg-admin1', 'bg-admin2'),
    [ValidatePattern('^[A-Z]{2}$')][string]$UsageLocation = 'US',
    [string]$PasswordOutputPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'admin-initial-passwords.csv'),
    [string]$MatrixPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'role-matrix.csv'),
    [string]$LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'access-model.log')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Initialize-LabLog -Path $LogPath
Assert-LabConnection -Graph

if ($CreateBreakGlass -and -not $BreakGlassDomain) { throw '-CreateBreakGlass needs -BreakGlassDomain (use your .onmicrosoft.com domain).' }

$need = @('User.ReadWrite.All', 'Group.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'AdministrativeUnit.ReadWrite.All')
if ($AssignmentType -eq 'Eligible') { $need += 'RoleEligibilitySchedule.ReadWrite.Directory' }
$missing = @($need | Where-Object { $_ -notin (Get-MgContext).Scopes })
if ($missing) { throw "Missing Graph scopes: $($missing -join ', '). Reconnect with: Connect-MgGraph -Scopes $($need -join ',')" }

$config  = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$secrets = [System.Collections.Generic.List[object]]::new()
$matrix  = [System.Collections.Generic.List[object]]::new()
$roleDefCache = @{}

#region helpers
function Get-RoleDefinitionId {
    param([string]$RoleName)
    if (-not $roleDefCache.ContainsKey($RoleName)) {
        $rd = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$RoleName'" | Select-Object -First 1
        if (-not $rd) { throw "Role '$RoleName' not found." }
        $roleDefCache[$RoleName] = $rd.Id
    }
    $roleDefCache[$RoleName]
}

function Grant-LabRole {
    param([string]$PrincipalId, [string]$PrincipalName, [string]$RoleName, [string]$ScopeId = '/', [string]$ScopeName = 'Tenant',
          [ValidateSet('Active', 'Eligible')][string]$Type = 'Active', [string]$Via = 'Direct')
    $rd = Get-RoleDefinitionId -RoleName $RoleName
    $matrix.Add([pscustomobject]@{ Principal = $PrincipalName; Role = $RoleName; Scope = $ScopeName; Assignment = $Type; Via = $Via })
    if (-not $PSCmdlet.ShouldProcess($PrincipalName, "Assign $RoleName ($Type, scope $ScopeName)")) { Write-LabLog "Would assign $RoleName to $PrincipalName ($Type, $ScopeName)" WHATIF; return }
    if ($Type -eq 'Active') {
        $existing = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$PrincipalId' and roleDefinitionId eq '$rd' and directoryScopeId eq '$ScopeId'"
        if ($existing) { Write-LabLog "Role already assigned: $RoleName -> $PrincipalName ($ScopeName)"; return }
        New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $PrincipalId -RoleDefinitionId $rd -DirectoryScopeId $ScopeId | Out-Null
    } else {
        $existing = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "principalId eq '$PrincipalId' and roleDefinitionId eq '$rd' and directoryScopeId eq '$ScopeId'"
        if ($existing) { Write-LabLog "Eligible assignment already exists: $RoleName -> $PrincipalName ($ScopeName)"; return }
        New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter @{
            action = 'adminAssign'; justification = 'Lab: Day 2 access model'
            roleDefinitionId = $rd; directoryScopeId = $ScopeId; principalId = $PrincipalId
            scheduleInfo = @{ startDateTime = (Get-Date).ToUniversalTime().ToString('o'); expiration = @{ type = 'noExpiration' } }
        } | Out-Null
    }
    Write-LabLog "Assigned $RoleName to $PrincipalName ($Type, $ScopeName)" ACTION
}

function New-AdminUser {
    param([string]$Upn, [string]$DisplayName, [int]$PasswordLength = 24, [bool]$ForceChange = $true, [string]$Kind = 'Admin')
    $existing = Get-MgUser -Filter "userPrincipalName eq '$Upn'" -ErrorAction SilentlyContinue
    if ($existing) { Write-LabLog "Exists: $Upn"; return $existing }
    if (-not $PSCmdlet.ShouldProcess($Upn, "Create $Kind account")) { Write-LabLog "Would create $Upn" WHATIF; return $null }
    $pw = New-LabRandomPassword -Length $PasswordLength
    $u = New-MgUser -DisplayName $DisplayName -UserPrincipalName $Upn -MailNickname ($Upn.Split('@')[0]) -UsageLocation $UsageLocation `
        -AccountEnabled -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = $ForceChange }
    $secrets.Add([pscustomobject]@{ Kind = $Kind; UserPrincipalName = $Upn; InitialPassword = $pw })
    Write-LabLog "Created $Kind account $Upn (unlicensed, cloud-only)" ACTION
    $u
}

function Get-OrNewGroup {
    param([string]$Name, [string]$Description, [switch]$RoleAssignable)
    $g = Get-MgGroup -Filter "displayName eq '$Name'" | Select-Object -First 1
    if ($g) { Write-LabLog "Group exists: $Name"; return $g }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Create group')) { Write-LabLog "Would create group $Name" WHATIF; return $null }
    $p = @{ DisplayName = $Name; Description = $Description; MailEnabled = $false; MailNickname = (($Name -replace '[^A-Za-z0-9]', '').ToLower()); SecurityEnabled = $true; GroupTypes = @() }
    if ($RoleAssignable) { $p.IsAssignableToRole = $true; $p.Visibility = 'Private' }
    $g = New-MgGroup @p
    Write-LabLog "Created group $Name$(if ($RoleAssignable) { ' (role-assignable)' })" ACTION
    $g
}

function Add-LabGroupMember {
    param([string]$GroupId, [string]$GroupName, [string]$MemberId, [string]$MemberName)
    $current = @(Get-MgGroupMember -GroupId $GroupId -All | ForEach-Object { $_.Id })
    if ($current -contains $MemberId) { return }
    if ($PSCmdlet.ShouldProcess($MemberName, "Add to $GroupName")) {
        New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $MemberId
        Write-LabLog "Added $MemberName to $GroupName" ACTION
    } else { Write-LabLog "Would add $MemberName to $GroupName" WHATIF }
}
#endregion

# ---- 1. Admin accounts
$adminUsers = @{}
foreach ($a in $config.adminAccounts) {
    $u = New-AdminUser -Upn "$($a.alias)@$Domain" -DisplayName $a.displayName
    if ($u) { $adminUsers[$a.alias] = $u }
}

# ---- 2. Security groups with nested dynamic groups
foreach ($g in $config.groups) {
    $sg = Get-OrNewGroup -Name $g.name -Description $g.description
    if (-not $sg) { continue }
    foreach ($n in $g.nested) {
        $child = Get-MgGroup -Filter "displayName eq '$n'" | Select-Object -First 1
        if (-not $child) { Write-LabLog "Nested group $n not found for $($g.name). Run New-LabUsers.ps1 -CreateDepartmentGroups first." WARN; continue }
        Add-LabGroupMember -GroupId $sg.Id -GroupName $g.name -MemberId $child.Id -MemberName $n
    }
}

# ---- 3. Administrative units
$auIds = @{}
foreach ($au in $config.administrativeUnits) {
    $existing = Get-MgDirectoryAdministrativeUnit -Filter "displayName eq '$($au.name)'" | Select-Object -First 1
    if (-not $existing -and $PSCmdlet.ShouldProcess($au.name, 'Create administrative unit')) {
        $existing = New-MgDirectoryAdministrativeUnit -DisplayName $au.name -Description $au.description
        Write-LabLog "Created administrative unit $($au.name)" ACTION
    }
    if (-not $existing) { Write-LabLog "Would create administrative unit $($au.name)" WHATIF; continue }
    $auIds[$au.name] = $existing.Id
    $have = @(Get-MgDirectoryAdministrativeUnitMember -AdministrativeUnitId $existing.Id -All | ForEach-Object { $_.Id })
    foreach ($u in @(Get-MgUser -Filter "department eq '$($au.department)'" -All -ConsistencyLevel eventual)) {
        if ($have -contains $u.Id) { continue }
        if ($PSCmdlet.ShouldProcess($u.UserPrincipalName, "Add to $($au.name)")) {
            New-MgDirectoryAdministrativeUnitMemberByRef -AdministrativeUnitId $existing.Id -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($u.Id)" }
            Write-LabLog "Added $($u.UserPrincipalName) to $($au.name)" ACTION
        }
    }
}

# ---- 4. Role-assignable groups (roles go to the group; members inherit them)
foreach ($rg in $config.roleAssignableGroups) {
    $g = Get-OrNewGroup -Name $rg.name -Description $rg.description -RoleAssignable
    if (-not $g) { continue }
    foreach ($r in $rg.roles) { Grant-LabRole -PrincipalId $g.Id -PrincipalName $rg.name -RoleName $r -Type $AssignmentType -Via 'Role-assignable group' }
    foreach ($m in $rg.members) {
        if ($adminUsers.ContainsKey($m)) { Add-LabGroupMember -GroupId $g.Id -GroupName $rg.name -MemberId $adminUsers[$m].Id -MemberName "$m@$Domain" }
        else { Write-LabLog "Member $m not available (account missing or WhatIf)" WARN }
    }
}

# ---- 5. Roles for admin accounts
foreach ($a in $config.adminAccounts) {
    if (-not $a.role) { continue }
    if (-not $adminUsers.ContainsKey($a.alias)) { continue }
    $scopeId = '/'; $scopeName = 'Tenant'
    if ($a.scopeAU) {
        if (-not $auIds.ContainsKey($a.scopeAU)) { Write-LabLog "AU $($a.scopeAU) not available. Skipping role for $($a.alias)." WARN; continue }
        $scopeId = "/administrativeUnits/$($auIds[$a.scopeAU])"; $scopeName = $a.scopeAU
    }
    Grant-LabRole -PrincipalId $adminUsers[$a.alias].Id -PrincipalName "$($a.alias)@$Domain" -RoleName $a.role -ScopeId $scopeId -ScopeName $scopeName -Type $AssignmentType
}
foreach ($a in $config.adminAccounts | Where-Object { $_.viaGroup }) {
    $matrix.Add([pscustomobject]@{ Principal = "$($a.alias)@$Domain"; Role = '(inherited)'; Scope = 'Tenant'; Assignment = 'Group membership'; Via = $a.viaGroup })
}

# ---- 6. Break-glass accounts (always permanent Global Administrator)
if ($CreateBreakGlass) {
    foreach ($n in $BreakGlassNames) {
        $upn = "$n@$BreakGlassDomain"
        $u = New-AdminUser -Upn $upn -DisplayName "Break Glass $n" -PasswordLength 32 -ForceChange $false -Kind 'BreakGlass'
        if ($u) { Grant-LabRole -PrincipalId $u.Id -PrincipalName $upn -RoleName 'Global Administrator' -Type Active -Via 'Break-glass' }
    }
}

# ---- 7. Outputs
$outDir = Split-Path $PasswordOutputPath -Parent
New-Item -ItemType Directory -Path $outDir -Force -WhatIf:$false | Out-Null
$adminSecrets = @($secrets | Where-Object { $_.Kind -eq 'Admin' })
if ($adminSecrets.Count -gt 0) {
    $adminSecrets | Select-Object UserPrincipalName, InitialPassword | Export-Csv -Path $PasswordOutputPath -NoTypeInformation -WhatIf:$false
    Write-LabLog "Admin initial passwords written to $PasswordOutputPath (gitignored). Delete after first sign-in." WARN
}
if ($matrix.Count -gt 0) {
    $matrix | Export-Csv -Path $MatrixPath -NoTypeInformation -WhatIf:$false
    Write-LabLog "Role matrix written to $MatrixPath"
    $matrix | Format-Table -AutoSize
}
foreach ($s in $secrets | Where-Object { $_.Kind -eq 'BreakGlass' }) {
    Write-Host "`nBREAK-GLASS  $($s.UserPrincipalName)`nPassword: $($s.InitialPassword)" -ForegroundColor Cyan
}
if ($secrets | Where-Object { $_.Kind -eq 'BreakGlass' }) {
    Write-Host "Shown once. Not saved to any file or log. Record these offline now, then clear your screen." -ForegroundColor Yellow
}
Write-LabLog 'Access model complete. Next: PIM policies, boundary tests, then Day 3 (Conditional Access).'
