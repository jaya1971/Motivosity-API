<# 
.SYNOPSIS
    This script pulls a list of all users on Motivosity platform then runs a compare against an SSO group.
    Their API will pull a list of active and deleted users.

.INPUTS
    Modify the Path containing the password for the azure admin account
    Modify the Azure Admin account name
    Modify the SSO group
.OUTPUTS


.NOTES
    Author:         Alex Jaya
    Creation Date:  01/14/2022 - Running as azure runbook
    Modified Date:  01/18/2022

.EXAMPLE
#>
$Group = 'SSOGroup'
$pswdPath = 'Path\pswd.txt'
$AzureAdm = 'Admin@domain.com'

#AZ login credentials
[Byte[]] $key = (1..32)
$password = get-content $pswdPath | ConvertTo-SecureString -Key $key
$LiveCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $AzureAdm, $password

#Grab secrets from Azure Key Vault
Login-AzAccount -Credential $LiveCred
$MVAPIsecret = Get-AzKeyVaultSecret -VaultName "KVName" -Name "SecretKey1"
$MVAppsecret = Get-AzKeyVaultSecret -VaultName "KVName" -Name "SecretKey2"
$MVAppID = Get-AzKeyVaultSecret -VaultName "KVName" -Name "SecretKey3"
Logout-AzAccount

#Import all needed modules
import-module ActiveDirectory

#Get current members of Motivosity group
$GroupDNs = get-adgroup -identity $Group -Properties Member | Select-Object -Property 'Member' -ExpandProperty 'Member'
$currentMembers = foreach($GroupDN in $GroupDNs){
    get-aduser -filter * -SearchBase $GroupDN -Properties name,samaccountname,mail | select name,samaccountname,mail

}

#Create the Security JW Token for the API call and get temporary access token--------------------------------------------------------------------------------
$JWT = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MVAPIsecret.SecretValue))
$JWApp = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MVAppsecret.SecretValue))
$JWAppID = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MVAppID.SecretValue))
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/json")

$body = "{`"appId`":`"$JWAppID`",`"secureToken`":`"$JWT`",`"appSecret`":`"$JWApp`"}"

$response = Invoke-RestMethod 'https://app.motivosity.com/auth/v1/servicetoken' -Method 'POST' -Headers $headers -Body $body
$response | ConvertTo-Json

#Temporary Token
$TJWT = $response.response.accessToken

#Use the temporary access token to get all users------------------------------------------------------------------
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", "Bearer $TJWT")
$headers.Add("Content-Type", "application/json")

$response = Invoke-RestMethod 'https://app.motivosity.com/api/v2/user?pageLimit=1000' -Method 'GET' -Headers $headers
$response | ConvertTo-Json

$MVUsers = $response.response | Select-Object firstname,lastname,email,payrollID

#ExtensionAttribute12 is a copy of our user's objectGUID in Active Directory
$MVADUsers = foreach($user in $MVUsers){
    $email = $user.email
    $payrollID = $user.payrollID
    Get-ADUser -Filter {ExtensionAttribute12 -eq $payrollID} -Properties samaccountname,mail | Select-Object samaccountname,mail
}


$UpdateUsers = $MVADUsers | Where-Object -FilterScript{$_.samaccountname -in $currentMembers.samaccountname} | Select-Object -ExpandProperty samaccountname
$DeleteUsers = $MVADUsers | Where-Object -FilterScript{$_.samaccountname -notin $currentMembers.samaccountname} | Select-Object -ExpandProperty samaccountname
$AddUsers = $currentMembers | Where-Object -FilterScript{$_.samaccountname -notin $MVADUsers.samaccountname} | Select-Object -ExpandProperty samaccountname

#Delete users from Motivosity------------------------------------------------------------------
if($DeleteUsers){
    foreach($user in $DeleteUsers){
        $mvuser = Get-ADUser $user -Properties objectGUID,extensionAttribute12,mail | select-object objectGUID,extensionAttribute12,mail
        $Email = $mvuser.mail.ToLower()
        $PayRollID = $mvuser.extensionAttribute12
        $NewPayrollID = $mvuser.extensionAttribute12 -split("-")[0]
        $NewPayrollID = $NewPayrollID[0]
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Content-Type", "application/json")
        $headers.Add("Authorization", "Bearer $TJWT")
        
        #update the payrollid to not reflect User's GUID. This is so this user will not get pulled on the next run.
        $body = "[{
        `n     `"email`":`"$Email`",
        `n     `"payrollID`":`"$NewPayRollID`",
        `n     `"function`":`"UPDATE`"}]"

        $response = Invoke-RestMethod 'https://app.motivosity.com/api/v2/user/sync' -Method 'POST' -Headers $headers -Body $body
        $response | ConvertTo-Json

        #Delete account
        $body = "[{
        `n     `"payrollID`":`"$NewPayRollID`",
        `n     `"function`":`"DELETE`"}]"

        $response = Invoke-RestMethod 'https://app.motivosity.com/api/v2/user/sync' -Method 'POST' -Headers $headers -Body $body
        $response | ConvertTo-Json
    }
}

#Create users in Motivosity.  This query has custom attributes we created in our Active Directory-----------------------------------------------------------------
if($AddUsers){
    foreach($user in $AddUsers){
        $mvuser = Get-ADUser $user -Properties extensionAttribute12,samaccountname,givenname,surname,mail,title,department,manager,usrBirthDate,usrHireDate `
        ,distinguishedname | Select-Object extensionAttribute12,samaccountname,@{name="FirstName";E={$_.givenname}},@{name="LastName";E={$_.surname}},mail,title `
        ,department,@{n='Manager';e={$_.manager.split(',')[0].split('=')[1]}},@{n='ManagerDN';e={$_.manager}},@{name="Birth Date";e={$_.usrBirthDate.ToUniversalTime()}} `
        ,@{name="Hire Date";e={$_.usrHireDate.ToUniversalTime()}}

        #Map Attributes
        $firstname = $mvuser.FirstName
        $lastname = $mvuser.LastName
        $Email = $mvuser.mail.ToLower()
        $HireDate = $mvuser.'Hire Date'
        $Birthdate = $mvuser.'Birth Date'
        $MgrDN = $mvuser.ManagerDN
        if($MgrDN){$managerEmail = get-aduser -filter * -SearchBase $MgrDN -Properties mail | Select-Object -ExpandProperty mail}
        if($managerEmail){$managerEmail = $managerEmail.ToLower()}
        $title = $mvuser.title
        $department = $mvuser.department
        $PayRollID  = $mvuser.extensionAttribute12
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Content-Type", "application/json")
        $headers.Add("Authorization", "Bearer $TJWT")
        
        $body = "[{
        `n     `"firstName`":`"$firstname`", 
        `n     `"lastName`":`"$lastname`",
        `n     `"hireDate`":`"$HireDate`",
        `n     `"birthDate`":`"$Birthdate`",
        `n     `"department`":`"$department`",
        `n     `"email`":`"$Email`",
        `n     `"supervisorEmail`":`"$managerEmail`",
        `n     `"countryCode`":`"USA`",
        `n     `"payrollID`":`"$PayRollID`",
        `n     `"title`":`"$title`",
        `n     `"function`":`"CREATE`"}]"

        $response = Invoke-RestMethod 'https://app.motivosity.com/api/v2/user/sync' -Method 'POST' -Headers $headers -Body $body
        $response | ConvertTo-Json
    }
}

#Update users in Motivosity. This query has custom attributes we created in our Active Directory-----------------------------------------------------------------
if($UpdateUsers){
    foreach($user in $UpdateUsers){
        $mvuser = Get-ADUser $user -Properties extensionAttribute12,samaccountname,givenname,surname,mail,title,department,manager,usrBirthDate,usrHireDate `
        ,distinguishedname | Select-Object extensionAttribute12,samaccountname,@{name="FirstName";E={$_.givenname}},@{name="LastName";E={$_.surname}},mail,title `
        ,department,@{n='Manager';e={$_.manager.split(',')[0].split('=')[1]}},@{n='ManagerDN';e={$_.manager}},@{name="Birth Date";e={$_.usrBirthDate.ToUniversalTime()}} `
        ,@{name="Hire Date";e={$_.usrHireDate.ToUniversalTime()}}

        #Map Attributes
        $firstname = $mvuser.FirstName
        $lastname = $mvuser.LastName
        $Email = $mvuser.mail.ToLower()
        $HireDate = $mvuser.'Hire Date'
        $Birthdate = $mvuser.'Birth Date'
        $MgrDN = $mvuser.ManagerDN
        if($MgrDN){$managerEmail = get-aduser -filter * -SearchBase $MgrDN -Properties mail | Select-Object -ExpandProperty mail}
        if($managerEmail){$managerEmail = $managerEmail.ToLower()}
        $title = $mvuser.title
        $department = $mvuser.department
        $PayRollID  = $mvuser.extensionAttribute12
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Content-Type", "application/json")
        $headers.Add("Authorization", "Bearer $TJWT")

        $body = "[{
        `n     `"firstName`":`"$firstname`", 
        `n     `"lastName`":`"$lastname`",
        `n     `"hireDate`":`"$HireDate`",
        `n     `"birthDate`":`"$Birthdate`",
        `n     `"department`":`"$department`",
        `n     `"email`":`"$Email`",
        `n     `"supervisorEmail`":`"$managerEmail`",
        `n     `"countryCode`":`"USA`",
        `n     `"payrollID`":`"$PayRollID`",
        `n     `"title`":`"$title`",
        `n     `"function`":`"UPDATE`"}]"

        $response = Invoke-RestMethod 'https://app.motivosity.com/api/v2/user/sync' -Method 'POST' -Headers $headers -Body $body
        $response | ConvertTo-Json
    }
}
