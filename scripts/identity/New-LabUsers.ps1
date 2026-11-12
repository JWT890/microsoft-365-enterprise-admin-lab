#Requires -Version 7.0
<#
.SYNOPSIS
    Joiner script: bulk-create users from CSV, license them, set managers, optionally create dynamic department groups.

.DESCRIPTION
    Idempotent. Existing users are skipped (but still used for manager mapping).
    Initial passwords are written to a gitignored CSV (output/). Hand them out securely,
    or replace this with a Temporary Access Pass flow.

.PARAMETER SkuPartNumber
    Find yours with:  Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits, @{n='Total';e={$_.PrepaidUnits.Enabled}}
    Examples: SPE_E5 (Microsoft 365 E5), SPE_E3, SPB (Business Premium).

.EXAMPLE
    ./New-LabUsers.ps1 -Domain contoso.com -CreateDepartmentGroups -WhatIf
.EXAMPLE
    ./New-LabUsers.ps1 -Domain contoso.com -SkuPartNumber SPB -CreateDepartmentGroups
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CsvPath = (Join-Path $PSScriptRoot '..' '..' 'data' 'users.csv'),
    [Parameter(Mandatory)][string]$Domain,
    [string]$SkuPartNumber = 'SPE_E5',
    [ValidatePattern('^[A-Z]{2}$')][string]$UsageLocation = 'US',
    [switch]$CreateDepartmentGroups,
    [string]$PasswordOutputPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'initial-passwords.csv'),
    [string]$LogPath = (Join-Path $PSScriptRoot '..' '..' 'output' 'joiner.log')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'common' 'LabCommon.psm1') -Force
Initialize-LabLog -Path $LogPath
Assert-LabConnection -Graph

$rows = @(Import-Csv -Path $CsvPath)
if ($rows.Count -eq 0) { throw "No rows in $CsvPath" }

$sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber }
if (-not $sku) { throw "SKU '$SkuPartNumber' not found. Run Get-MgSubscribedSku to list available SKUs." }
$free = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
if ($free -lt $rows.Count) { Write-LabLog "Only $free free $SkuPartNumber licenses for $($rows.Count) users. Some assignments may fail." WARN }

$idByAlias = @{}
$passwords = [System.Collections.Generic.List[object]]::new()

# ---- Pass 1: create + license
foreach ($u in $rows) {
    $upn = "$($u.Alias)@$Domain"
    $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-LabLog "Exists, skipping create: $upn" INFO
        $idByAlias[$u.Alias] = $existing.Id
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($upn, "Create user ($($u.Department), $($u.JobTitle)) and assign $SkuPartNumber")) {
        Write-LabLog "Would create $upn" WHATIF; continue
    }
    try {
        $pw = New-LabRandomPassword
        $new = New-MgUser -DisplayName "$($u.FirstName) $($u.LastName)" -GivenName $u.FirstName -Surname $u.LastName `
            -UserPrincipalName $upn -MailNickname $u.Alias -Department $u.Department -JobTitle $u.JobTitle `
            -UsageLocation $UsageLocation -AccountEnabled `
            -PasswordProfile @{ Password = $pw; ForceChangePasswordNextSignIn = $true }
        Set-MgUserLicense -UserId $new.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
        $idByAlias[$u.Alias] = $new.Id
        $passwords.Add([pscustomobject]@{ UserPrincipalName = $upn; InitialPassword = $pw })
        Write-LabLog "Created and licensed $upn" ACTION
    } catch {
        Write-LabLog "Failed to create ${upn}: $($_.Exception.Message)" ERROR
    }
}

# ---- Pass 2: managers (after everyone exists)
foreach ($u in $rows | Where-Object { $_.Manager }) {
    if (-not $idByAlias.ContainsKey($u.Alias) -or -not $idByAlias.ContainsKey($u.Manager)) {
        Write-LabLog "Skipping manager link for $($u.Alias) -> $($u.Manager) (user not found or not created)" WARN; continue
    }
    if ($PSCmdlet.ShouldProcess("$($u.Alias)@$Domain", "Set manager to $($u.Manager)@$Domain")) {
        try {
            Set-MgUserManagerByRef -UserId $idByAlias[$u.Alias] -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($idByAlias[$u.Manager])" }
            Write-LabLog "Manager set: $($u.Alias) -> $($u.Manager)" ACTION
        } catch { Write-LabLog "Manager link failed for $($u.Alias): $($_.Exception.Message)" ERROR }
    }
}

# ---- Dynamic department groups
if ($CreateDepartmentGroups) {
    foreach ($dept in ($rows.Department | Sort-Object -Unique)) {
        $name = "DG-$dept"
        if (Get-MgGroup -Filter "displayName eq '$name'" -ErrorAction SilentlyContinue) { Write-LabLog "Group exists: $name"; continue }
        if ($PSCmdlet.ShouldProcess($name, 'Create dynamic security group')) {
            try {
                $nick = 'dg' + (($dept -replace '[^A-Za-z0-9]', '').ToLower())
                New-MgGroup -DisplayName $name -MailEnabled:$false -MailNickname $nick -SecurityEnabled:$true `
                    -GroupTypes @('DynamicMembership') -MembershipRule ('(user.department -eq "{0}")' -f $dept) `
                    -MembershipRuleProcessingState 'On' | Out-Null
                Write-LabLog "Created dynamic group $name (membership can take several minutes to populate; needs Entra ID P1)" ACTION
            } catch { Write-LabLog "Group create failed for ${name}: $($_.Exception.Message)" ERROR }
        }
    }
}

if ($passwords.Count -gt 0) {
    $dir = Split-Path $PasswordOutputPath -Parent
    New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false | Out-Null
    $passwords | Export-Csv -Path $PasswordOutputPath -NoTypeInformation -WhatIf:$false
    Write-LabLog "Initial passwords written to $PasswordOutputPath (gitignored). Delete after use." WARN
}
Write-LabLog 'Joiner run complete. Mailboxes can take a few minutes to provision after licensing.'
