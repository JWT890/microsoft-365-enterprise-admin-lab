#Requires -Version 7.0
<#
.SYNOPSIS
    Offboard a user: cut off access, preserve the mailbox as a shared mailbox, remove licenses and group memberships.

.DESCRIPTION
    Order matters:
      1. Block sign-in            4. Convert mailbox to shared, give manager Full Access, hide from GAL
      2. Revoke sessions          5. Remove direct group memberships (assigned groups and DLs)
      3. Reset password           6. Remove licenses, ONLY after the mailbox is confirmed Shared
    Removing a license from a regular mailbox schedules the mailbox for deletion, so step 6 is skipped
    if the conversion cannot be confirmed. Shared mailboxes need a license only above 50 GB or with
    an archive / litigation hold.
    Not handled here: OneDrive hand-off (use the SharePoint admin center or SPO module), devices, app-specific access.

.EXAMPLE
    ./Invoke-Leaver.ps1 -UserPrincipalName lchen@contoso.com -WhatIf
.EXAMPLE
    ./Invoke-Leaver.ps1 -UserPrincipalName lchen@contoso.com -ManagerUpn anguyen@contoso.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$UserPrincipalName,
    [string]$ManagerUpn,
    [switch]$KeepLicense,
    [int]$ConversionWaitSeconds = 30,
    [string[]]$ProtectedAccounts = @(),
    [string]$LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'leaver.log')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Initialize-LabLog -Path $LogPath
Assert-LabConnection -Graph -Exchange

$upn = $UserPrincipalName
if ($upn -in $ProtectedAccounts) { throw "$upn is protected. Refusing to run." }
$dryRun = [bool]$WhatIfPreference

$user = Get-MgUser -UserId $upn -Property Id, DisplayName, UserPrincipalName, AssignedLicenses
if (-not $ManagerUpn) {
    $mgr = Get-MgUserManager -UserId $user.Id -ErrorAction SilentlyContinue
    if ($mgr) { $ManagerUpn = $mgr.AdditionalProperties['userPrincipalName'] }
}
Write-LabLog "Leaver: $upn manager=$(if ($ManagerUpn) { $ManagerUpn } else { '(none)' }) dryRun=$dryRun"

if (-not $dryRun -and -not $PSCmdlet.ShouldProcess($upn, 'Offboard user')) { Write-LabLog 'Declined.' WARN; return }

# 1-3 cut off access
Disable-LabAccount -UserPrincipalName $upn -WhatIf:$dryRun
Revoke-LabSessions -UserPrincipalName $upn -WhatIf:$dryRun
$null = Reset-LabPassword -UserPrincipalName $upn -WhatIf:$dryRun

# 4 mailbox
$mailboxIsShared = $false
$mbx = Get-Mailbox -Identity $upn -ErrorAction SilentlyContinue
if (-not $mbx) {
    Write-LabLog "No mailbox found for $upn (skipping mailbox steps)." WARN
} else {
    if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') {
        $mailboxIsShared = $true
    } elseif ($PSCmdlet.ShouldProcess($upn, 'Convert mailbox to shared')) {
        Set-Mailbox -Identity $upn -Type Shared
        Write-LabLog "Converted $upn mailbox to shared" ACTION
        Start-Sleep -Seconds $ConversionWaitSeconds
        $mailboxIsShared = ((Get-Mailbox -Identity $upn).RecipientTypeDetails -eq 'SharedMailbox')
        if (-not $mailboxIsShared) { Write-LabLog 'Mailbox does not report SharedMailbox yet. License removal will be skipped.' WARN }
    } else { Write-LabLog "Would convert $upn mailbox to shared" WHATIF }

    if ($ManagerUpn) {
        if ($PSCmdlet.ShouldProcess($upn, "Grant $ManagerUpn Full Access")) {
            Add-MailboxPermission -Identity $upn -User $ManagerUpn -AccessRights FullAccess -AutoMapping $true | Out-Null
            Write-LabLog "Granted $ManagerUpn Full Access to $upn" ACTION
        } else { Write-LabLog "Would grant $ManagerUpn Full Access to $upn" WHATIF }
    } else { Write-LabLog 'No manager found. Nobody was granted mailbox access.' WARN }

    if ($PSCmdlet.ShouldProcess($upn, 'Hide from address lists')) {
        Set-Mailbox -Identity $upn -HiddenFromAddressListsEnabled $true
        Write-LabLog "Hidden $upn from address lists" ACTION
    }
}

# 5 group memberships (skip dynamic groups: membership is attribute-driven)
foreach ($m in @(Get-MgUserMemberOf -UserId $user.Id -All)) {
    if ($m.AdditionalProperties['@odata.type'] -ne '#microsoft.graph.group') { continue }
    $gName  = $m.AdditionalProperties['displayName']
    $gTypes = @($m.AdditionalProperties['groupTypes'])
    if ($gTypes -contains 'DynamicMembership') { Write-LabLog "Skipping dynamic group $gName (membership follows attributes)"; continue }
    if (-not $PSCmdlet.ShouldProcess($upn, "Remove from group $gName")) { Write-LabLog "Would remove $upn from $gName" WHATIF; continue }
    try {
        $mailEnabled = [bool]$m.AdditionalProperties['mailEnabled']
        if ($mailEnabled -and $gTypes -notcontains 'Unified') {
            # Distribution list or mail-enabled security group: Exchange owns membership
            Remove-DistributionGroupMember -Identity $m.Id -Member $upn -Confirm:$false
        } else {
            Remove-MgGroupMemberByRef -GroupId $m.Id -DirectoryObjectId $user.Id
        }
        Write-LabLog "Removed $upn from $gName" ACTION
    } catch { Write-LabLog "Could not remove $upn from ${gName}: $($_.Exception.Message)" WARN }
}

# 6 licenses (only once the mailbox is confirmed shared)
if ($KeepLicense) {
    Write-LabLog 'Licenses kept (-KeepLicense).'
} elseif ($mbx -and -not $mailboxIsShared -and -not $dryRun) {
    Write-LabLog 'Skipping license removal: mailbox is not confirmed shared. Re-run once it is.' WARN
} else {
    $skus = @($user.AssignedLicenses | ForEach-Object { $_.SkuId })
    if ($skus.Count -gt 0 -and $PSCmdlet.ShouldProcess($upn, "Remove $($skus.Count) license(s)")) {
        Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $skus | Out-Null
        Write-LabLog "Removed $($skus.Count) license(s) from $upn" ACTION
    } elseif ($skus.Count -gt 0) { Write-LabLog "Would remove $($skus.Count) license(s) from $upn" WHATIF }
}

Write-LabLog "Leaver complete for $upn. Remaining manual steps: OneDrive hand-off, devices, shared resources."
