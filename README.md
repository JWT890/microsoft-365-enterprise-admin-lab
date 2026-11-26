# microsoft-365-enterprise-admin-lab

Being able to administer Microsoft 365 environments is important since companies utilize Microsoft 365 for administrative and business purposes.

# Setup
Go to billing and go your products and start a free trial for the Microsoft E5 trial, then on the host computer run:    
Install-Module Microsoft.Graph, ExchangeOnlineManagement -Scope CurrentUser 
Connect-MgGraph -Scopes "User.ReadWrite.All","Group.ReadWrite.All","Directory.ReadWrite.All","RoleManagement.ReadWrite.Directory","Policy.ReadWrite.ConditionalAccess","IdentityRiskyUser.Read.All","AuditLog.Read.All"
Connect-ExchangeOnline -UserPrincipalName jontaylor@patchlab26.onmicrosoft.com  
Connect-ExchangeOnline -UserPrincipalName adm-yourname@yourdomain.com   


# Identity and Foundation

After getting connected, turn on logging:   
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true and if this pops up: 
![Error](./images/error.png)    
Then start by checking to see if a change is needed by running Get-AdminAuditLogConfig | Select UnifiedAuditLogIngestionEnabled and if it returns false run Enable-OrganizationCustimzation which will pop up with: 
![Error1](./images/error1.png)  
Open up a new PowerShell and run:   
Disconnect-ExchangeOnline -Confirm:$false   
Connect-ExchangeOnline -UserPrincipalName adm-yourname@yourdomain.com   
Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true  
And the last command can take up to 60 minutes to complete or fast in this situation:   
![Status](./images/status.png)  
Then run to get the license: Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits, @{n='Total';e={$_.PrepaidUnits.Enabled}}    
And see this:   
![Error3](./images/error3.png)      
Saying that the cause is PowerShell 5.1 since the current version is PowerShell 7.0. Update by running winget install --id Microsoft.PowerShell -e. Then verify with pwsh -v and switch to the latest with pwsh and to check the version with $PSVersionTable.PSVersion:    
![Version](./images/version.png)    
Then re-install with Install-Module Microsoft.Graph, ExchangeOnlineManagement -Scope CurrentUser -Force 
And when this happens:  
![Yellow](./images/yellow.png)
Check the PowerShell version by running $PSVersionTable.PSVersion.Major and run Get-InstalledModule Microsoft.Graph, ExchangeOnlineManagement | Select Name, Version. If it prints the current version number then its fine. For PowerShell if its 7, also good.    
Then cd into the folder on host computer and to allow downloaded scripts to run, type: Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned. Then run Get-ChildItem C:\Users\user\github name -Recurse -File | Unblock-File.    
Be good to add a few folders in the repo so run:    
mkdir scripts\common, scripts\identity, scripts\conditional-access, scripts\security, scripts\exchange, scripts\incident-response, data -Force
Then type Move-Item C:\Users\user\Downloads\LabCommon.psm1 scripts\common\  
*These scripts was made by Claude*    
Then run Import-Module .\scripts\common\LabCommon.psm1 -Force and import the script and if this occurs: 
![Error4](./images/error4.png)  
The solution is to unblock the file by running: 
Unblock-File .\scripts\common\LabCommon.psm1 and checking the policy by running Get-ExecutionPolicy-List and see if CurrentUser says RemoteSigned or not. If not run Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force.   
This time it will work so run: Connect-Lab -AdminUpn adm-yourname@yourdomain.com with the admin domain and wait a couple times for sign in prompts. 
Then check how many licenses are left with: Get-MgSubscribedSku | Select SkuPartNumber, ConsumedUnits, @{n='Total';e={$_.PrepaidUnits.Enabled}} and unlock the rest of the files with Get-ChildItem . - Recurse File | Unblock-File which should show.  
Then find the domain with for user addresses by typing Get-MgDomain | Select Id, IsDefault, IsVerified. 
Then run: .\scripts\identity\New-LabUsers.ps1 -Domain jon-maillab.org -CreateDepartmentGroups -WhatIf and watch the dry run go. 
Then run it live without -WhatIf:   
![Run](./images/run.png)    
The users and department groups have been created.  
And check Microsoft 365:    
![Users](./images/users.png)    
And to fully verify run these from the screenshot:  
![Test](./images/test.png)  
Now since the users are created its time to do a leaver test on two users for a test run by running .\scripts\identity\Invoke-Leaver.ps1 -UserPrincipalName kdube@jon-maillab.org -WhatIf:  
![One](./images/one.png)    
![Two](./images/two.png)    
This shows both the manager links for both users and the steps taken such as password reset, mailbox conversion, and more. Then run a live version next without -WhatIf.    
![Error5](./images/error5.png)  
Note the red means the password reset failed but everything else worked.    
*Downloaded a new LabCommon.psm1 from Claude*
Then delete the old one and put the new LabCommon.psm1 in there instead, then run Get-ChildItem . -Recurse -File | Unblock-File. Then close and open a new PowerShell script.   
In the new PowerShell script run:   
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy Bypass -Force   
Import-Module .\scripts\common\LabCommon.psm1 -Force    
$null = Reset-LabPassword -UserPrincipalName kdube@jon-maillab.org and should show  
![Action](./images/action.png)  
Then verify by running these commands:  
![Script](./images/script.png)  
Then check with ecross by running:  
.\scripts\identity\Invoke-Leaser.ps1 -UserPrincipalName eross@jon-maillab.org with no errors this time: 
![Ran](./images/ran.png)    

# Access
First after adding Claude generated New-LabAccessModel.ps1 do a test run with .\scripts\groups\New-LabAccessModel.ps1 -Domain jon-maillab.org -CreateBreakGlass -BreakGlassDomain patchlab26.onmicrosoft.com -WhatIf to see if a test run works.    
And make sure to run: Connect-MgGraph -NoWelcome -Scopes User.ReadWrite.All,Group.ReadWrite.All,Directory.ReadWrite.All,RoleManagement.ReadWrite.Directory,Policy.ReadWrite.ConditionalAccess,Policy.Read.All,Application.Read.All,UserAuthenticationMethod.ReadWrite.All,IdentityRiskyUser.ReadWrite.All,AuditLog.Read.All,DelegatedPermissionGrant.ReadWrite.All,User-PasswordProfile.ReadWrite.All,AdministrativeUnit.ReadWrite.All,RoleEligibilitySchedule.ReadWrite.Directory just in case PowerShell was signed out of.   
After running:  
![Test1](./images/test1.png)    
Since it worked, run without -WhatIf.   
![Test2](./images/test2.png)    
Since 2 break glass accounts were created, sign in as one of them to confirm they work. 
After sigining as one:  
![Sign](./images/sign.png)  
Then run this command to assign licenses:   
![Command](./images/command.png)    
After verifying that the script worked, verify it with: 
'adm-helpdesk','adm-useradmin','adm-exchange','adm-secops','adm-soc' | ForEach-Object {
  Get-MgUserLicenseDetail -UserId "$_@jon-maillab.org" | Select-Object @{n='User';e={$_}}, SkuPartNumber
}   
Its time to move on to Conditional access with a What-if Test run with: 
.\scripts\conditional-access\Deploy-ConditionalAccess.ps1 -BreakGlassUpn bg-admin1@patchlab26.onmicrosoft.com,bg-admin2@patchlab26.onmicrosoft.com -IncludeRiskPolicies -WhatIf:    
![Access](./images/access.png)  
Then live without -WhatIf.  
![Live](./images/live.png)  
Since its read only go to the Entra admin center -> Conditional Access -> Policies and they should be there:    
![Policy](./images/policy.png)  
Then click on CA001, click on edit or view and get here:    
![Edit](./images/edit.png)  
Then click on users and set to specific and exclude SG-CA-Exclusions and save it.   
Then go check security defaults by going to Overview -> Properties -> scroll down and click on manage security defaults and change it to disabled from enabled with the reason being my organization is using conditional access.   
Then go to Authentication Methods and make sure that Microsoft Authenticator and Temporary Access Pass is enabled. With TAP enabled, temporary access pass codes can be sent out and used for different users run:  
foreach ($u in 'dpatel','mlee','pshah','anguyen','adm-secops','adm-helpdesk') {
  $tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId "$u@jon-maillab.org" -BodyParameter @{ lifetimeInMinutes = 60; isUsableOnce = $false }
  [pscustomobject]@{ User = $u; TAP = $tap.TemporaryAccessPass }
}
Then sign as one of the users in a private window with their email and sign in with the TAP code to sign in and get here:   
![SIgned](./images/signed.png)  
Then go to outlook.office.com and teams.microsoft.com to verify:    
![Outlook](./images/outlook.png)    
![Teams](./images/teams.png)    
And through checking sign in logs through Monitoring & Health:  
![Events](./images/events.png)  
And through read only view: 
![Read](./images/read.png)  
And from checking the admin sign in from earlier:   
![Admin](./images/admin.png)    
Which shows not applicable since its a break glass account. 
And when checking the second admin account: 
![Admin1](./images/admin1.png)  
Then sign in with TAP as one of the adm accounts and reach here:    
![Error](./images/error6.png)   
Then sign as another adm account, such as adm-secops since last was adm-helpdesk and reach the same error message as before since the script created them without licenses. Then go check the logs: 
![Sec](./images/sec.png)    
With CA001 it shows not applied for all users since its a regular member, lets check one of adm-helpdesk's logs:    
![Scope](./images/scope.png)    
From looking over this, adm-helpdesk is not covered by CA002 with the cause being the role doesn't pick up admin assignments, so run this:  
Group of all admin accounts
$g = New-MgGroup -DisplayName 'SG-Admin-Accounts' -Description 'All admin accounts (CA002 targets this in addition to roles)' -MailEnabled:$false -MailNickname 'sgadminaccounts' -SecurityEnabled:$true -GroupTypes @()
foreach ($a in 'adm-helpdesk','adm-useradmin','adm-exchange','adm-secops','adm-soc') {
  $u = Get-MgUser -Filter "userPrincipalName eq '$a@jon-maillab.org'"
  New-MgGroupMember -GroupId $g.Id -DirectoryObjectId $u.Id
}

Add the group to CA002, keeping the roles and the exclusion
$p = Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA002-Require-MFA-Admins'
$users = @{
  includeRoles  = @($p.Conditions.Users.IncludeRoles)
  includeGroups = @($g.Id)
  excludeGroups = @($p.Conditions.Users.ExcludeGroups)
}
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -BodyParameter @{ conditions = @{ users = $users } }  
Then issue a new TAP for adm-helpdesk by running: 
foreach ($u in 'dpatel','mlee','pshah','anguyen','adm-secops','adm-helpdesk') {
  $tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId "$u@jon-maillab.org" -BodyParameter @{ lifetimeInMinutes = 60; isUsableOnce = $false }
  [pscustomobject]@{ User = $u; TAP = $tap.TemporaryAccessPass }
} 
And sign in on entra.microsoft.com and then go check the logs:  
![More](./images/more.png)  
Since it still isn't working check the policy stuff by running: 
![Status1](./images/status1.png) 
The dump shows the IncludeUsers as empty, fix CA001 by running: 
$p = Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA001-Require-MFA-AllUsers'
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -BodyParameter @{
  conditions = @{ users = @{ includeUsers = @('All'); includeGroups = @(); excludeGroups = @('b2df6909-276d-417d-b7b9-ddfbf26b7f00') } }
} 
And check the other policies too: 
![Status2](./images/status2.png)  
Fix it by running:  
$excl = (Get-MgGroup -Filter "displayName eq 'SG-CA-Exclusions'").Id
$p = Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA001-Require-MFA-AllUsers'
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -BodyParameter @{
  conditions = @{ users = @{ includeUsers = @('All'); includeGroups = @(); excludeGroups = @($excl) } }
} 
And verifying from here:  
![Status3](./images/status3.png)  
With that all are now correct time to rerun conditional access with this script with -WhatIf: 
.\scripts\conditional-access\Deploy-ConditionalAccess.ps1 -BreakGlassUpn bg-admin1@patchlab26.onmicrosoft.com,bg-admin2@patchlab26.onmicrosoft.com -AdminAccountUpn adm-helpdesk@jon-maillab.org,adm-useradmin@jon-maillab.org,adm-exchange@jon-maillab.org,adm-secops@jon-maillab.org,adm-soc@jon-maillab.org -IncludeRiskPolicies -WhatIf. Should result: 
![Scope1](./images/scope1.png)  
Then run without what if but see a mismatch or some dups:  
![Mismatch](./images/mismatch.png)  
Since its complaining about duplicates run: 
Get-MgGroup -Filter "displayName eq 'SG-Admin-Accounts'" | ForEach-Object {
  [pscustomobject]@{ Id = $_.Id; Created = $_.CreatedDateTime; Members = @(Get-MgGroupMember -GroupId $_.Id -All).Count }
} 
Which should show the dups: 
![Dup](./images/dup.png)  
To delete, run this in sequence:

```powershell
$keep = '3c7f8bc7-bf0a-49be-b591-a75ca616b422'
$extras = Get-MgGroup -Filter "displayName eq 'SG-Admin-Accounts'" | Where-Object Id -ne $keep
$policies = Get-MgIdentityConditionalAccessPolicy -All

foreach ($g in $extras) {
    $used = $policies | Where-Object {
        $_.Conditions.Users.IncludeGroups -contains $g.Id -or
        $_.Conditions.Users.ExcludeGroups -contains $g.Id
    }

    if ($used) {
        Write-Warning "SKIPPING $($g.Id): used by $($used.DisplayName -join ', ')"
        continue
    }

    Remove-MgGroup -GroupId $g.Id
    Write-Host "Deleted duplicate $($g.Id)"
}
```
Get-MgGroup -Filter "displayName eq 'SG-Admin-Accounts'" | Select-Object Id, DisplayName  
Which should keep the specific id, filters to see whether the SG group has more dups and checks the policies for extras and deletes the dups and run the commands from this:  
![Commmand1](./images/command1.png) 
Which should show only one version and verifies the users within the group and then rerun the Deploy-ConditionalAccess.ps1 script once again: 
![Script1](./images/script1.png)  
Which should verify now with the green indicator, then go verify with bg-admin1, dpatel and adm-helpdesk. After getting the new TAPs by running:  
foreach ($u in 'dpatel','adm-helpdesk') {
  $tap = New-MgUserAuthenticationTemporaryAccessPassMethod -UserId "$u@jon-maillab.org" -BodyParameter @{ lifetimeInMinutes = 60; isUsableOnce = $false }
  [pscustomobject]@{ User = $u; TAP = $tap.TemporaryAccessPass }
} 
For bg-admin1:  
![Test3](./images/test3.png)  
For Dev Patel:  
![Dev](./images/dev.png)  
With it showing CA001 as a success. 
For adm-helpdesk: 
![Adm](./images/adm.png)  
Since adm is success for CA001 and not for 2, check the group and policy by running:  
$keep = '3c7f8bc7-bf0a-49be-b591-a75ca616b422'
Get-MgGroupMember -GroupId $keep | ForEach-Object { $_.AdditionalProperties['userPrincipalName'] }
(Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA002-Require-MFA-Admins').Conditions.Users | Select-Object IncludeGroups, ExcludeGroups  
ANd result: 
![Info](./images/info.png)  
Then wait a couple minutes and should see it update:  
![Update](./images/update.png)  
The enforcement is now complate or at least on track. 

Then its time to move on to configuring DNS and DKIM. 
Start by getting the Microsoft records by running:  
Get-MgDomainServiceConfigurationRecord -DomainId jon-maillab.org |
  Select-Object RecordType, Label, Text, MailExchange, CanonicalName, Ttl | Format-List 
And since it will likely error message about privileges go to -> Settings -> Domains -> jon-maillab.org -> DNS records and verify it has the correct configurations.  
Then go to Cloudflare and go to the domain's DNS records and turn off email routing if its there or on. 
Then its time to create a shared mailbox by running:  
New-Mailbox -Shared -Name "SecOps Alerts" -PrimarySmtpAddress secops-alerts@jon-maillab.org
Add-MailboxPermission -Identity secops-alerts@jon-maillab.org -User <your admin UPN> -AccessRights FullAccess -AutoMapping $true  
And the result: 
![Mail](./images/mail.png)  
Then run the following from this screenshot to create DKIM config and check its status: 
![Ran1](./images/ran1.png)  
What the error means is that it already exists, now its time to check the permissions with: 
Get-MailboxPermission secops-alerts@jon-maillab.org | Where-Object { $_.User -ne 'NT AUTHORITY\SELF' } | Select-Object User, AccessRights 
![Permissions](./images/permissions.png)  
And get the DKIM records by running: Get-DkimSigningConfig -Identity jon-maillab.org | Format-List Domain, Enabled, Selector1CNAME, Selector2CNAME  
![Record](./images/record.png)  
Then check the DNS names to see if they resolve:  
Resolve-DnsName selector1._domainkey.jon-maillab.org -Type CNAME  
Resolve-DnsName selector2._domainkey.jon-maillab.org -Type CNAME  
Which they should and enable signing afterwards with Set-DkimSigningConfig -Identity jon-maillab.org -Enabled $true, then run a WhatIf for mail protection: 
.\scripts\security\Deploy-MailProtection.ps1 -Domain jon-maillab.org -SecurityAdminEmail secops-alerts@jon-maillab.org -ProtectedUsers 'Casey Morgan;cmorgan@jon-maillab.org','Jordan Hartley;jhartley@jon-maillab.org' -WhatIf 
![What](./images/what.png)  
Without WhatIf: 
![V](./images/v.png)  
And verify with the commands from the screenshot: 
![V1](./images/v1.png)  
The important ones from the above is threshold of 3, the two C suite protected, autoforwardingmode is off, filefilter and ZAP are on, AllowClickThrough is false and Action: DynamicDelivery is set and all should print enabled. 
Then check the rule scope from this picture:  
![Phish](./images/phish.png)  
And then verify SPF, DMARC, and DKIM like so: 
![Mail1](./images/mail1.png)
Then I signed in as Dev Patel and sent an email to myself:  
![Outbound](./images/outbound-spf-dkim-dmarc-pass-blurred.png)  
Then run a trace in Exchange and through the command line:  
![Trace](./images/trace.png)  
![V2](./images/v2.png)  
Then do a inbound test to Dev and check in mail and command line: 
![I](./images/i.png)  
and in mail:  
![Result](./images/result.png)  
From this image it shows as arc=pass which shows intactness.  
Then its time to do protection tests by sending emails to Dev by doing GTUBE spam, safe links.  
For GTUBE, i sent:  
![Tube](./images/tube.png)  
For Safe Links i sent an email with a link attached which when hovering over it changes to include safelinks. 
When looking at details for GTUBE spam test:  
![S](./images/s.png)  
Shows with SFV:SPM and CAT:SPM which means spam. Then its time to test out auto-forward block by running: 
Set-Mailbox dpatel@jon-maillab.org -ForwardingSmtpAddress you@gmail.com 
And send an email internally to Dev and wait a few moments to receive the block:  
![Block](./images/block.png)  
This comes up with running Get-HostedOutboundSpamFilterPolicy | Select-Object Name, AutoForwardingMode  
![Off](./images/off.png)  
With the custom set to off it doesn't have to depend on Microsoft's one staying similar. Then turn it off by running: 
Set-Mailbox dpatel@jon-maillab.org -ForwardingSmtpAddress $null -ForwardingAddress $null  
Get-InboxRule -Mailbox dpatel@jon-maillab.org | Select-Object Name, ForwardTo, RedirectTo, Enabled  
Then to check for authenticator for admin account run:  
Get-MgUserAuthenticationMethod -UserId jontaylor@patchlab26.onmicrosoft.com | ForEach-Object { $_.AdditionalProperties['@odata.type'] } 
Which should show:  
![Result1](./images/result1.png)  
And run to check for legacy authentication: 
$since = (Get-Date).AddDays(-7).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")  
Get-MgAuditLogSignIn -Filter "createdDateTime ge $since" -All | 
  Where-Object { $_.ClientAppUsed -in 'Exchange ActiveSync','Other clients','IMAP4','POP3','Authenticated SMTP' } | 
  Select-Object CreatedDateTime, UserPrincipalName, ClientAppUsed, AppDisplayName 

Now its time to enforce policies like CA003 so run: 
$p = Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA003-Block-Legacy-Auth'  
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State enabled  
Then wait around 10 minutes and run:  
Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -like 'CA00*' | Sort-Object DisplayName | Select-Object DisplayName, State | Format-Table -AutoSize 
![3](./images/3.png)  
Since this is testing CA003, it is good. Then sign in as Dev Patel through myaccount.microsoft.com for account and Outlook, then head to Entra -> Monitoring -> Sign in logs and check Conditional Access on the dev patel log: 
![Log](./images/log.png)  
With that it shows the correct result, noe time for CA002.  
Run:  
$p = Get-MgIdentityConditionalAccessPolicy -All | Where-Object DisplayName -eq 'CA002-Require-MFA-Admins' 
Update-MgIdentityConditionalAccessPolicy -ConditionalAccessPolicyId $p.Id -State enabled  
Then wait around 10 minutes.  
Then open adm-secops in security.microsoft.com, adm-helpdesk in entra.microsoft.com, and bg-admin1 in myaccount.microsoft.com.  
ADM-Secops log: 
![Sec1](./images/sec1.png)  
ADM-Helpdesk log: 
![Help](./images/help.png)  
And BG-Admin1:  
![Bg](./images/bg.png)  
Unlike the other two since BG is a admin account and has the expected result of No MFA. 
Results can also be pulled in as text by running this command with result:  
![Result2](./images/result2.png) 
And confirm the policies by running:  
![Confirm](./images/confirm.png)  

