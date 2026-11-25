#Requires -Version 7.0
<#
.SYNOPSIS
    Deploys baseline custom email protection policies in Exchange Online / Defender for Office 365.

.DESCRIPTION
    Creates or updates (idempotent):
      Anti-phishing   LAB-AntiPhish          (impersonation features need Defender for Office 365)
      Anti-spam       LAB-AntiSpam-Inbound
      Outbound spam   LAB-AntiSpam-Outbound  (auto-forwarding to external recipients OFF)
      Anti-malware    LAB-AntiMalware        (common attachment types filter + ZAP)
      Safe Links      LAB-SafeLinks          (Defender for Office 365)
      Safe Attachments LAB-SafeAttachments   (Defender for Office 365)
      Global Safe Attachments for SharePoint / OneDrive / Teams

    Each policy gets a rule scoped to your whole domain. Existing rules are left as they are.

    PRECEDENCE: Strict preset > Standard preset > custom policies > built-in default... but only for the
    users each preset is applied to. Check the order for your tenant in Defender > Threat policies, and
    don't expect custom settings to apply to users already covered by a preset. Put protected-user and
    protected-domain lists in the preset as well if you use presets for executives.

    Safe to run with -WhatIf. A step that fails (for example a feature your license lacks) logs a warning
    and the script continues.

.EXAMPLE
    ./Deploy-MailProtection.ps1 -Domain contoso.com -SecurityAdminEmail adm-secops@contoso.com `
        -ProtectedUsers 'Casey Morgan;cmorgan@contoso.com','Jordan Hartley;jhartley@contoso.com' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Domain,
    [Parameter(Mandatory)][string]$SecurityAdminEmail,
    [string[]]$ProtectedUsers = @(),          # "Display Name;address" pairs
    [string[]]$ProtectedDomains = @(),
    [ValidateRange(1, 4)][int]$PhishThreshold = 3,
    [ValidateRange(10, 1000)][int]$OutboundHourlyExternalLimit = 100,
    [string]$Prefix = 'LAB'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Assert-LabConnection -Exchange

function Invoke-Step {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [scriptblock]$Action)
    if ($PSCmdlet.ShouldProcess($Name, 'Apply')) {
        try { & $Action; Write-Host "[ OK ]  $Name" -ForegroundColor Green }
        catch { Write-Host "[WARN]  $Name : $($_.Exception.Message)" -ForegroundColor Yellow }
    } else { Write-Host "[WHATIF] $Name" }
}

function Initialize-Policy {      # create, or update when it already exists
    param([string]$GetCmd, [string]$NewCmd, [string]$SetCmd, [string]$Name, [hashtable]$Params)
    if (& $GetCmd -Identity $Name -ErrorAction SilentlyContinue) { & $SetCmd -Identity $Name @Params | Out-Null }
    else { & $NewCmd -Name $Name @Params | Out-Null }
}

function Initialize-Rule {        # create only; leave an existing rule untouched
    param([string]$GetCmd, [string]$NewCmd, [string]$Name, [hashtable]$Params)
    if (& $GetCmd -Identity $Name -ErrorAction SilentlyContinue) { Write-Host "        rule exists, unchanged: $Name"; return }
    & $NewCmd -Name $Name @Params | Out-Null
}

# ---------------------------------------------------------------- Anti-phishing
$ap = @{
    Enabled                             = $true
    PhishThresholdLevel                 = $PhishThreshold
    EnableSpoofIntelligence             = $true
    EnableUnauthenticatedSender         = $true
    EnableViaTag                        = $true
    AuthenticationFailAction            = 'Quarantine'
    HonorDmarcPolicy                    = $true
    EnableMailboxIntelligence           = $true
    EnableMailboxIntelligenceProtection = $true
    MailboxIntelligenceProtectionAction = 'Quarantine'
    EnableOrganizationDomainsProtection = $true
    EnableFirstContactSafetyTips        = $true
    EnableSimilarUsersSafetyTips        = $true
    EnableSimilarDomainsSafetyTips      = $true
    EnableUnusualCharactersSafetyTips   = $true
}
if ($ProtectedUsers.Count -gt 0) {
    $ap.EnableTargetedUserProtection = $true
    $ap.TargetedUsersToProtect       = $ProtectedUsers
    $ap.TargetedUserProtectionAction = 'Quarantine'
}
if ($ProtectedDomains.Count -gt 0) {
    $ap.EnableTargetedDomainsProtection = $true
    $ap.TargetedDomainsToProtect        = $ProtectedDomains
    $ap.TargetedDomainProtectionAction  = 'Quarantine'
}
Invoke-Step "Anti-phishing policy $Prefix-AntiPhish" {
    Initialize-Policy 'Get-AntiPhishPolicy' 'New-AntiPhishPolicy' 'Set-AntiPhishPolicy' "$Prefix-AntiPhish" $ap
    Initialize-Rule 'Get-AntiPhishRule' 'New-AntiPhishRule' "$Prefix-AntiPhish-Rule" @{ AntiPhishPolicy = "$Prefix-AntiPhish"; RecipientDomainIs = $Domain }
}

# ---------------------------------------------------------------- Anti-spam (inbound)
$spam = @{
    SpamAction                       = 'MoveToJmf'
    HighConfidenceSpamAction         = 'Quarantine'
    PhishSpamAction                  = 'Quarantine'
    HighConfidencePhishAction        = 'Quarantine'
    BulkSpamAction                   = 'MoveToJmf'
    BulkThreshold                    = 6
    QuarantineRetentionPeriod        = 30
    InlineSafetyTipsEnabled          = $true
    SpamZapEnabled                   = $true
    PhishZapEnabled                  = $true
    EnableEndUserSpamNotifications   = $true
    EndUserSpamNotificationFrequency = 3
}
Invoke-Step "Anti-spam inbound policy $Prefix-AntiSpam-Inbound" {
    Initialize-Policy 'Get-HostedContentFilterPolicy' 'New-HostedContentFilterPolicy' 'Set-HostedContentFilterPolicy' "$Prefix-AntiSpam-Inbound" $spam
    Initialize-Rule 'Get-HostedContentFilterRule' 'New-HostedContentFilterRule' "$Prefix-AntiSpam-Inbound-Rule" @{ HostedContentFilterPolicy = "$Prefix-AntiSpam-Inbound"; RecipientDomainIs = $Domain }
}

# ---------------------------------------------------------------- Anti-spam (outbound)
$out = @{
    AutoForwardingMode                = 'Off'
    RecipientLimitExternalPerHour     = $OutboundHourlyExternalLimit
    RecipientLimitInternalPerHour     = 400
    RecipientLimitPerDay              = 500
    ActionWhenThresholdReached        = 'BlockUser'
    NotifyOutboundSpam                = $true
    NotifyOutboundSpamRecipients      = $SecurityAdminEmail
}
Invoke-Step "Outbound spam policy $Prefix-AntiSpam-Outbound (auto-forward OFF)" {
    Initialize-Policy 'Get-HostedOutboundSpamFilterPolicy' 'New-HostedOutboundSpamFilterPolicy' 'Set-HostedOutboundSpamFilterPolicy' "$Prefix-AntiSpam-Outbound" $out
    Initialize-Rule 'Get-HostedOutboundSpamFilterRule' 'New-HostedOutboundSpamFilterRule' "$Prefix-AntiSpam-Outbound-Rule" @{ HostedOutboundSpamFilterPolicy = "$Prefix-AntiSpam-Outbound"; SenderDomainIs = $Domain }
}

# ---------------------------------------------------------------- Anti-malware
$mal = @{
    EnableFileFilter                       = $true
    FileTypes                              = @('exe', 'js', 'jse', 'vbs', 'vbe', 'wsf', 'iso', 'img', 'lnk', 'ps1', 'bat', 'cmd', 'scr', 'jar', 'msi', 'hta', 'reg')
    ZapEnabled                             = $true
    EnableInternalSenderAdminNotifications = $true
    InternalSenderAdminAddress             = $SecurityAdminEmail
}
Invoke-Step "Anti-malware policy $Prefix-AntiMalware" {
    Initialize-Policy 'Get-MalwareFilterPolicy' 'New-MalwareFilterPolicy' 'Set-MalwareFilterPolicy' "$Prefix-AntiMalware" $mal
    Initialize-Rule 'Get-MalwareFilterRule' 'New-MalwareFilterRule' "$Prefix-AntiMalware-Rule" @{ MalwareFilterPolicy = "$Prefix-AntiMalware"; RecipientDomainIs = $Domain }
}

# ---------------------------------------------------------------- Safe Links (Defender for Office 365)
$sl = @{
    EnableSafeLinksForEmail  = $true
    EnableSafeLinksForTeams  = $true
    EnableSafeLinksForOffice = $true
    ScanUrls                 = $true
    DeliverMessageAfterScan  = $true
    EnableForInternalSenders = $true
    DisableUrlRewrite        = $false
    TrackClicks              = $true
    AllowClickThrough        = $false
}
Invoke-Step "Safe Links policy $Prefix-SafeLinks" {
    Initialize-Policy 'Get-SafeLinksPolicy' 'New-SafeLinksPolicy' 'Set-SafeLinksPolicy' "$Prefix-SafeLinks" $sl
    Initialize-Rule 'Get-SafeLinksRule' 'New-SafeLinksRule' "$Prefix-SafeLinks-Rule" @{ SafeLinksPolicy = "$Prefix-SafeLinks"; RecipientDomainIs = $Domain }
}

# ---------------------------------------------------------------- Safe Attachments (Defender for Office 365)
$sa = @{ Enable = $true; Action = 'DynamicDelivery' }
Invoke-Step "Safe Attachments policy $Prefix-SafeAttachments (Dynamic Delivery)" {
    Initialize-Policy 'Get-SafeAttachmentPolicy' 'New-SafeAttachmentPolicy' 'Set-SafeAttachmentPolicy' "$Prefix-SafeAttachments" $sa
    Initialize-Rule 'Get-SafeAttachmentRule' 'New-SafeAttachmentRule' "$Prefix-SafeAttachments-Rule" @{ SafeAttachmentPolicy = "$Prefix-SafeAttachments"; RecipientDomainIs = $Domain }
}
Invoke-Step 'Global: Safe Attachments for SharePoint, OneDrive, Teams (+ Safe Documents, no click-through)' {
    Set-AtpPolicyForO365 -EnableATPForSPOTeamsODB $true -EnableSafeDocs $true -AllowSafeDocsOpen $false
}

Write-Host "`nVerify:  Get-AntiPhishPolicy | ft Name,Enabled,PhishThresholdLevel   |   Defender portal > Threat policies > Configuration analyzer"
Write-Host 'Test:    send GTUBE (spam) and EICAR (malware) test strings from an external account you own, then check Quarantine and message trace.'
