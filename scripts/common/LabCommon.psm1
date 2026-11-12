#Requires -Version 7.0
<#
.SYNOPSIS
    Shared helpers for the M365 Secure Tenant Lab scripts.
.DESCRIPTION
    Logging, connection checks, and small single-purpose "response actions" that are reused by
    the leaver script (Day 1) and the incident containment script (Day 8).
    Every action supports -WhatIf and writes a timestamped line to the active log.
#>
Set-StrictMode -Version Latest

$script:LabLogPath = $null

#region Connection and logging
function Connect-Lab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AdminUpn,
        [string[]]$GraphScopes = @(
            'User.ReadWrite.All', 'Group.ReadWrite.All', 'Directory.ReadWrite.All',
            'RoleManagement.ReadWrite.Directory', 'Policy.ReadWrite.ConditionalAccess',
            'Policy.Read.All', 'Application.Read.All', 'UserAuthenticationMethod.ReadWrite.All',
            'IdentityRiskyUser.ReadWrite.All', 'AuditLog.Read.All', 'DelegatedPermissionGrant.ReadWrite.All'
        ),
        [switch]$SkipGraph,
        [switch]$SkipExchange
    )
    if (-not $SkipGraph)    { Connect-MgGraph -Scopes $GraphScopes -NoWelcome | Out-Null }
    if (-not $SkipExchange) { Connect-ExchangeOnline -UserPrincipalName $AdminUpn -ShowBanner:$false }
}

function Assert-LabConnection {
    [CmdletBinding()]
    param([switch]$Graph, [switch]$Exchange)
    if ($Graph -and -not (Get-MgContext)) {
        throw 'Not connected to Microsoft Graph. Run Connect-Lab first.'
    }
    if ($Exchange) {
        $exo = Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' }
        if (-not $exo) { throw 'Not connected to Exchange Online. Run Connect-Lab first.' }
    }
}

function Initialize-LabLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null }
    $script:LabLogPath = $Path
}

function Write-LabLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR', 'WHATIF')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] [{2}] {3}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'), $Level, [Environment]::UserName, $Message
    switch ($Level) {
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'ACTION' { Write-Host $line -ForegroundColor Green }
        default  { Write-Host $line }
    }
    if ($script:LabLogPath) { Add-Content -Path $script:LabLogPath -Value $line -WhatIf:$false }
}

function New-LabRandomPassword {
    [CmdletBinding()]
    param([ValidateRange(16, 64)][int]$Length = 24)
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%^&*-_=+')
    $all  = -join $sets
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[$rng::GetInt32($s.Length)]) }          # one from each class
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {                                 # Fisher-Yates shuffle
        $j = $rng::GetInt32($i + 1)
        $chars[$i], $chars[$j] = $chars[$j], $chars[$i]
    }
    -join $chars
}
#endregion

#region Response actions (each supports -WhatIf)
function Disable-LabAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Block sign-in')) {
        Update-MgUser -UserId $UserPrincipalName -AccountEnabled:$false
        Write-LabLog "Blocked sign-in: $UserPrincipalName" ACTION
    } else { Write-LabLog "Would block sign-in: $UserPrincipalName" WHATIF }
}

function Enable-LabAccount {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Re-enable sign-in')) {
        Update-MgUser -UserId $UserPrincipalName -AccountEnabled:$true
        Write-LabLog "Re-enabled sign-in: $UserPrincipalName" ACTION
    } else { Write-LabLog "Would re-enable sign-in: $UserPrincipalName" WHATIF }
}

function Revoke-LabSessions {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Revoke refresh tokens / sign-in sessions')) {
        Revoke-MgUserSignInSession -UserId $UserPrincipalName | Out-Null
        Write-LabLog "Revoked sessions: $UserPrincipalName (already-issued access tokens can live up to ~1 hour unless CAE applies)" ACTION
    } else { Write-LabLog "Would revoke sessions: $UserPrincipalName" WHATIF }
}

function Reset-LabPassword {
    <# Returns the new password (plain text) so the caller can decide what to do with it. It is never logged. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName, [switch]$ForceChange)
    if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Reset password to random value')) {
        $pw = New-LabRandomPassword
        Update-MgUser -UserId $UserPrincipalName -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = $ForceChange.IsPresent }
        Write-LabLog "Reset password: $UserPrincipalName (ForceChange=$($ForceChange.IsPresent))" ACTION
        return $pw
    }
    Write-LabLog "Would reset password: $UserPrincipalName" WHATIF
}

function Reset-LabMfaMethods {
    <# Removes registered strong-auth methods so the user must re-register. The password method is left in place. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    $upn = $UserPrincipalName
    foreach ($m in @(Get-MgUserAuthenticationMethod -UserId $upn)) {
        $type = $m.AdditionalProperties['@odata.type']
        $id   = $m.Id
        if ($type -eq '#microsoft.graph.passwordAuthenticationMethod') { continue }
        if (-not $PSCmdlet.ShouldProcess($upn, "Remove auth method $type")) {
            Write-LabLog "Would remove auth method $type from $upn" WHATIF; continue
        }
        try {
            switch ($type) {
                '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'  { Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $upn -MicrosoftAuthenticatorAuthenticationMethodId $id }
                '#microsoft.graph.phoneAuthenticationMethod'                   { Remove-MgUserAuthenticationPhoneMethod -UserId $upn -PhoneAuthenticationMethodId $id }
                '#microsoft.graph.fido2AuthenticationMethod'                   { Remove-MgUserAuthenticationFido2Method -UserId $upn -Fido2AuthenticationMethodId $id }
                '#microsoft.graph.softwareOathAuthenticationMethod'            { Remove-MgUserAuthenticationSoftwareOathMethod -UserId $upn -SoftwareOathAuthenticationMethodId $id }
                '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' { Remove-MgUserAuthenticationWindowsHelloForBusinessMethod -UserId $upn -WindowsHelloForBusinessAuthenticationMethodId $id }
                '#microsoft.graph.emailAuthenticationMethod'                   { Remove-MgUserAuthenticationEmailMethod -UserId $upn -EmailAuthenticationMethodId $id }
                '#microsoft.graph.temporaryAccessPassAuthenticationMethod'     { Remove-MgUserAuthenticationTemporaryAccessPassMethod -UserId $upn -TemporaryAccessPassAuthenticationMethodId $id }
                default { Write-LabLog "No removal handler for auth method type $type on $upn" WARN; continue }
            }
            Write-LabLog "Removed auth method $type from $upn" ACTION
        } catch {
            Write-LabLog "Could not remove $type from ${upn}: $($_.Exception.Message)" WARN
        }
    }
}
#endregion

#region Persistence hunting and removal
function Get-LabPersistence {
    <# Read-only snapshot of the places an attacker typically leaves a foothold after compromising a mailbox. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    $upn = $UserPrincipalName

    $rules = @()
    try { $rules = @(Get-InboxRule -Mailbox $upn -IncludeHidden -ErrorAction Stop) }
    catch { Write-LabLog "Inbox rule query failed for ${upn}: $($_.Exception.Message)" WARN }

    $ruleView = foreach ($r in $rules) {
        [pscustomobject]@{
            Name                  = $r.Name
            Identity              = "$($r.Identity)"
            Enabled               = $r.Enabled
            From                  = "$($r.From -join '; ')"
            SubjectContainsWords  = "$($r.SubjectContainsWords -join '; ')"
            ForwardTo             = "$($r.ForwardTo -join '; ')"
            ForwardAsAttachmentTo = "$($r.ForwardAsAttachmentTo -join '; ')"
            RedirectTo            = "$($r.RedirectTo -join '; ')"
            DeleteMessage         = $r.DeleteMessage
            MoveToFolder          = "$($r.MoveToFolder)"
            Suspicious            = [bool]($r.ForwardTo -or $r.ForwardAsAttachmentTo -or $r.RedirectTo -or $r.DeleteMessage)
        }
    }

    $mbx = $null
    try { $mbx = Get-Mailbox -Identity $upn -ErrorAction Stop }
    catch { Write-LabLog "Mailbox query failed for ${upn}: $($_.Exception.Message)" WARN }

    $forwarding = $null; $sendOnBehalf = @(); $fullAccess = @(); $sendAs = @()
    if ($mbx) {
        $forwarding = [pscustomobject]@{
            ForwardingAddress          = "$($mbx.ForwardingAddress)"
            ForwardingSmtpAddress      = "$($mbx.ForwardingSmtpAddress)"
            DeliverToMailboxAndForward = $mbx.DeliverToMailboxAndForward
        }
        $sendOnBehalf = @($mbx.GrantSendOnBehalfTo | ForEach-Object { "$_" })
        $fullAccess = @(Get-MailboxPermission -Identity $upn |
            Where-Object { "$($_.User)" -ne 'NT AUTHORITY\SELF' -and -not $_.IsInherited -and -not $_.Deny } |
            ForEach-Object { [pscustomobject]@{ User = "$($_.User)"; AccessRights = "$($_.AccessRights -join ', ')" } })
        $sendAs = @(Get-RecipientPermission -Identity $upn |
            Where-Object { "$($_.Trustee)" -ne 'NT AUTHORITY\SELF' } |
            ForEach-Object { [pscustomobject]@{ Trustee = "$($_.Trustee)"; AccessRights = "$($_.AccessRights -join ', ')" } })
    }

    $oauth = @(); $devices = @(); $methods = @()
    try { $oauth = @(Get-MgUserOauth2PermissionGrant -UserId $upn -All | Select-Object Id, ClientId, ResourceId, Scope, ConsentType) }
    catch { Write-LabLog "OAuth grant query failed for ${upn}: $($_.Exception.Message)" WARN }
    try { $devices = @(Get-MgUserRegisteredDevice -UserId $upn -All | ForEach-Object { [pscustomobject]@{ Id = $_.Id; DisplayName = $_.AdditionalProperties['displayName']; OS = $_.AdditionalProperties['operatingSystem'] } }) }
    catch { Write-LabLog "Registered device query failed for ${upn}: $($_.Exception.Message)" WARN }
    try { $methods = @(Get-MgUserAuthenticationMethod -UserId $upn | ForEach-Object { $_.AdditionalProperties['@odata.type'] }) }
    catch { Write-LabLog "Auth method query failed for ${upn}: $($_.Exception.Message)" WARN }

    [pscustomobject]@{
        UserPrincipalName  = $upn
        CapturedUtc        = (Get-Date).ToUniversalTime().ToString('o')
        InboxRules         = @($ruleView)
        Forwarding         = $forwarding
        FullAccessGrantees = $fullAccess
        SendAsGrantees     = $sendAs
        SendOnBehalf       = $sendOnBehalf
        OAuthGrants        = $oauth
        RegisteredDevices  = $devices
        AuthMethods        = $methods
    }
}

function Remove-LabPersistence {
    <# Removes forwarding/deleting inbox rules, mailbox-level forwarding, and (optionally) OAuth grants.
       Delegate permissions are reported, not removed, because they may be legitimate. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$UserPrincipalName, [switch]$RemoveOAuthGrants)
    $upn  = $UserPrincipalName
    $snap = Get-LabPersistence -UserPrincipalName $upn

    foreach ($r in @($snap.InboxRules | Where-Object { $_.Suspicious })) {
        if ($PSCmdlet.ShouldProcess($upn, "Remove inbox rule '$($r.Name)'")) {
            Remove-InboxRule -Mailbox $upn -Identity $r.Identity -Confirm:$false
            Write-LabLog "Removed suspicious inbox rule '$($r.Name)' from $upn" ACTION
        } else { Write-LabLog "Would remove inbox rule '$($r.Name)' from $upn" WHATIF }
    }

    if ($snap.Forwarding -and ($snap.Forwarding.ForwardingAddress -or $snap.Forwarding.ForwardingSmtpAddress)) {
        if ($PSCmdlet.ShouldProcess($upn, 'Clear mailbox forwarding')) {
            Set-Mailbox -Identity $upn -ForwardingAddress $null -ForwardingSmtpAddress $null -DeliverToMailboxAndForward $false
            Write-LabLog "Cleared mailbox forwarding on $upn" ACTION
        } else { Write-LabLog "Would clear mailbox forwarding on $upn" WHATIF }
    }

    if ($RemoveOAuthGrants) {
        foreach ($g in $snap.OAuthGrants) {
            if ($PSCmdlet.ShouldProcess($upn, "Remove OAuth grant $($g.Id) (scope: $($g.Scope))")) {
                Remove-MgOauth2PermissionGrant -OAuth2PermissionGrantId $g.Id
                Write-LabLog "Removed OAuth grant $($g.Id) for $upn" ACTION
            } else { Write-LabLog "Would remove OAuth grant $($g.Id) for $upn" WHATIF }
        }
    } elseif ($snap.OAuthGrants.Count -gt 0) {
        Write-LabLog "$($snap.OAuthGrants.Count) OAuth grant(s) found for $upn. Review them, then re-run with -RemoveOAuthGrants if needed." WARN
    }

    foreach ($d in $snap.FullAccessGrantees) { Write-LabLog "REVIEW: $($d.User) has $($d.AccessRights) on $upn" WARN }
    foreach ($d in $snap.SendAsGrantees)     { Write-LabLog "REVIEW: $($d.Trustee) has $($d.AccessRights) on $upn" WARN }
    foreach ($d in $snap.SendOnBehalf)       { Write-LabLog "REVIEW: $d has SendOnBehalf on $upn" WARN }
}
#endregion

Export-ModuleMember -Function Connect-Lab, Assert-LabConnection, Initialize-LabLog, Write-LabLog, New-LabRandomPassword,
    Disable-LabAccount, Enable-LabAccount, Revoke-LabSessions, Reset-LabPassword, Reset-LabMfaMethods,
    Get-LabPersistence, Remove-LabPersistence
