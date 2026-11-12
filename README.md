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
![Run](./images/run.png)    
The users and department groups have been created.  
And check Microsoft 365:    
![Users](./images/users.png)    
And to fully verify run these from the screenshot:  
![Test](./images/test.png)  

# Access
