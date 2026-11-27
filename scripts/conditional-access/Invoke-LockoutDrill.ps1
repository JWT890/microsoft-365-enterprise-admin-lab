#Requires -Version 7.0
<#
.SYNOPSIS
    Safe lockout recovery drill: lock out ONE disposable test user with a block policy, then recover.

.DESCRIPTION
    Phases (run one at a time):
      Start    Creates drill-user, group SG-LockoutDrill (containing ONLY that user) and a block-everything
               Conditional Access policy that targets ONLY that group and excludes SG-CA-Exclusions.
               The policy is created DISABLED, read back and verified, and only then enabled. If the
               read-back doesn't match, the policy is deleted and nothing is enforced.
      Verify   Shows the drill user's recent sign-ins and what the drill policy decided (expect failure, error 53003).
      Recover  Disables the drill policy. Do this from a break-glass session to practice the real recovery path.
      Cleanup  Removes the policy, the group and the user.

    SAFETY: the policy can only ever match members of SG-LockoutDrill. The script refuses to continue if that
    group contains anyone except the drill user, so it cannot lock out your admin or break-glass accounts.

    Drill steps:
      1. -Phase Start. Write down the printed password (shown once, not logged).
      2. In a private window, sign in as the drill user at https://myaccount.microsoft.com. Expect to be BLOCKED.
      3. -Phase Verify, and screenshot the output and the sign-in log's Conditional access tab.
      4. Recover as if you were locked out: sign in as a break-glass account in a private window and disable
         CA-DRILL-Block-DrillGroup in the portal (or run -Phase Recover). Sign in as the drill user again: it should work.
      5. -Phase Cleanup. Write up the incident (timeline, cause, recovery, prevention).

.EXAMPLE
    ./Invoke-LockoutDrill.ps1 -Phase Start -Domain jon-maillab.org -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Verify', 'Recover', 'Cleanup')][string]$Phase,
    [Parameter(Mandatory)][string]$Domain,
    [string]$DrillUserAlias = 'drill-user',
    [string]$DrillGroupName = 'SG-LockoutDrill',
    [string]$DrillPolicyName = 'CA-DRILL-Block-DrillGroup',
    [string]$ExclusionGroupName = 'SG-CA-Exclusions',
    [ValidatePattern('^[A-Z]{2}$')][string]$UsageLocation = 'US',
    [string]$LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'lockout-drill.log')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Initialize-LabLog -Path $LogPath
Assert-LabConnection -Graph

$upn = "$DrillUserAlias@$Domain"

function Get-SingleGroup {
    param([string]$Name)
    $m = @(Get-MgGroup -Filter "displayName eq '$Name'")
    if ($m.Count -gt 1) { throw "Found $($m.Count) groups named '$Name' (IDs: $($m.Id -join ', ')). Delete duplicates first." }
    $m | Select-Object -First 1
}
function Get-DrillPolicy {
    @(Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq $DrillPolicyName) | Select-Object -First 1
}

switch ($Phase) {

    'Start' {
        $excl = Get-SingleGroup -Name $ExclusionGroupName
        if (-not $excl) { throw "$ExclusionGroupName not found. Run Deploy-ConditionalAccess.ps1 first." }

        # 1. Drill user
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        $pw = $null
        if (-not $user) {
            if (-not $PSCmdlet.ShouldProcess($upn, 'Create drill user')) { Write-LabLog "Would create $upn" WHATIF }
            else {
                $pw = New-LabRandomPassword
                $user = New-MgUser -DisplayName 'Lockout Drill User' -UserPrincipalName $upn -MailNickname $DrillUserAlias -UsageLocation $UsageLocation `
                    -AccountEnabled -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = $false }
                Write-LabLog "Created drill user $upn" ACTION
            }
        } else { Write-LabLog "Drill user exists: $upn" }

        # 2. Drill group, containing ONLY the drill user
        $group = Get-SingleGroup -Name $DrillGroupName
        if (-not $group -and $PSCmdlet.ShouldProcess($DrillGroupName, 'Create drill group')) {
            $group = New-MgGroup -DisplayName $DrillGroupName -Description 'Lockout drill: contains ONLY the drill user' -MailEnabled:$false `
                -MailNickname (($DrillGroupName -replace '[^A-Za-z0-9]', '').ToLower()) -SecurityEnabled:$true -GroupTypes @()
            Write-LabLog "Created $DrillGroupName ($($group.Id))" ACTION
        }
        if ($user -and $group) {
            $members = @(Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object Id)
            if ($members -notcontains $user.Id -and $PSCmdlet.ShouldProcess($upn, "Add to $DrillGroupName")) {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id
                $members = @(Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object Id)
            }
            if ($members.Count -ne 1 -or $members[0] -ne $user.Id) {
                throw "SAFETY STOP: $DrillGroupName must contain exactly the drill user but has $($members.Count) member(s). Fix it before continuing."
            }
            Write-LabLog "Safety check passed: $DrillGroupName contains only $upn"
        }

        # 3. Policy: create DISABLED, verify by reading back, then enable
        if (Get-DrillPolicy) { Write-LabLog "Policy $DrillPolicyName already exists. Use -Phase Recover or Cleanup." WARN; return }
        if (-not $group) { Write-LabLog "Would create policy $DrillPolicyName (disabled, verify, then enable)" WHATIF; return }
        if ($PSCmdlet.ShouldProcess($DrillPolicyName, 'Create block policy (disabled), verify, then enable')) {
            $body = @{
                displayName   = $DrillPolicyName
                state         = 'disabled'
                conditions    = @{
                    users          = @{ includeGroups = @($group.Id); excludeGroups = @($excl.Id) }
                    applications   = @{ includeApplications = @('All') }
                    clientAppTypes = @('all')
                }
                grantControls = @{ operator = 'OR'; builtInControls = @('block') }
            }
            $p = New-MgIdentityConditionalAccessPolicy -BodyParameter $body
            $u = $p.Conditions.Users
            $bad = @()
            if (@($u.IncludeUsers).Count -ne 0)                                 { $bad += 'IncludeUsers is not empty' }
            if (@($u.IncludeRoles).Count -ne 0)                                 { $bad += 'IncludeRoles is not empty' }
            if (@($u.IncludeGroups).Count -ne 1 -or $u.IncludeGroups[0] -ne $group.Id) { $bad += 'IncludeGroups is not exactly the drill group' }
            if ($u.ExcludeGroups -notcontains $excl.Id)                         { $bad += "$ExclusionGroupName is not excluded" }
            if ($bad) {
                Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id
                throw "SAFETY STOP: policy read-back did not match ($($bad -join '; ')). Policy deleted, nothing enforced."
            }
            Write-LabLog "Policy verified (targets only $DrillGroupName, excludes $ExclusionGroupName)" ACTION
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State enabled
            Write-LabLog "ENFORCED $DrillPolicyName at $((Get-Date).ToUniversalTime().ToString('o')). Drill user is now locked out." ACTION
        }
        if ($pw) {
            Write-Host "`nDrill user: $upn`nPassword:   $pw" -ForegroundColor Cyan
            Write-Host 'Shown once, not logged. Sign in at https://myaccount.microsoft.com in a private window and expect to be BLOCKED.' -ForegroundColor Yellow
        }
    }

    'Verify' {
        $since = (Get-Date).AddMinutes(-90).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $rows = foreach ($s in @(Get-MgAuditLogSignIn -Filter "userPrincipalName eq '$upn' and createdDateTime ge $since" -Top 10)) {
            foreach ($c in @($s.AppliedConditionalAccessPolicies | Where-Object DisplayName -eq $DrillPolicyName)) {
                [pscustomobject]@{ Time = $s.CreatedDateTime; App = $s.AppDisplayName; DrillPolicy = $c.Result; ErrorCode = $s.Status.ErrorCode; Reason = $s.Status.FailureReason }
            }
        }
        if ($rows) { $rows | Sort-Object Time | Format-Table -AutoSize; Write-LabLog "Found $(@($rows).Count) drill sign-in(s). Expect DrillPolicy=failure and ErrorCode 53003." }
        else { Write-LabLog 'No drill sign-ins found yet. Sign in as the drill user, wait a few minutes, and retry.' WARN }
    }

    'Recover' {
        $p = Get-DrillPolicy
        if (-not $p) { Write-LabLog "Policy $DrillPolicyName not found. Nothing to recover." WARN; return }
        if ($PSCmdlet.ShouldProcess($DrillPolicyName, 'Disable drill policy')) {
            Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State disabled
            $state = (Get-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id).State
            Write-LabLog "Recovered at $((Get-Date).ToUniversalTime().ToString('o')): $DrillPolicyName state is now $state" ACTION
        }
    }

    'Cleanup' {
        $p = Get-DrillPolicy
        if ($p -and $PSCmdlet.ShouldProcess($DrillPolicyName, 'Delete policy')) { Remove-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id; Write-LabLog "Deleted policy $DrillPolicyName" ACTION }
        $g = Get-SingleGroup -Name $DrillGroupName
        if ($g -and $PSCmdlet.ShouldProcess($DrillGroupName, 'Delete group')) { Remove-MgGroup -GroupId $g.Id; Write-LabLog "Deleted group $DrillGroupName" ACTION }
        $u = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if ($u -and $PSCmdlet.ShouldProcess($upn, 'Delete drill user')) { Remove-MgUser -UserId $u.Id; Write-LabLog "Deleted $upn (kept 30 days in Deleted users)" ACTION }
    }
}
