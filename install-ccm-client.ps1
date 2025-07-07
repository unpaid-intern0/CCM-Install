<#SYNOPSIS
    Script to install MECM client to computers from a GPO startup script

DESCRIPTION
    This script allows you to automatically install the latest MECM client to a computer from a GPO startup script 
    
Usage
    You deploy this script as a start up script.
    The script checks if MECM client is installed and if it is pointed at CCM site,  If installed it exits.
    If no client is detected is downloads the client installer and launches the install.
    It logs actions and errors into c:\windows\debug\$scriptName.log and emails if wrong site code detected
#>

# Set this variable to set the log file name
$scriptName = "log-file-var"

# Set Variables for the server and site code
$CMMP='site-server'
$CMSiteCode='site-code'
$ErrorPreference = "SilentlyContinue"
$serviceStatus = "OK"

# Set to $true to enable email notifications, $false to disable
$sendEmail = $false

#Set email for notifications
$email = 'IT Staff Alias <email-address>'

function Get-LogDate {
    Param()
    return "[{0:MM/dd/yy} {0:HH:mm:ss}]" -f (Get-Date)  
} 
function Set-LogFile {
    Param ()
    $SystemRoot = $env:SystemRoot
    $logFile = "$SystemRoot\Debug\$scriptName.log"
    # Test if the log file exists and create it if not
    If(!(test-path $logFile)) {
        new-item $logFile -force -type file
    }
    else {
        # Once the log reaches 1000 lines keep the last 250
        $file = Get-Content $logFile
        if($file.Count -gt 1000) {
            $content = Get-Content $logFile -Tail 250
            Set-Content -Path $logFile -Value $content
        }
    }
    return $logFile
}
function Install-MECMClient {
    Param ()
    try 
    { 
    #Get ccm cache path for later cleanup... 
        try 
        { 
            $ccmcache = ([wmi]"ROOT\ccm\SoftMgmtAgent:CacheConfig.ConfigKey='Cache'").Location 
        } catch {} 

        #download ccmsetup.exe from MP 
        Add-Content $Log_File  "$(Get-LogDate) - Downloading Client Installer"
        $webclient = New-Object System.Net.WebClient 
        $url = "http://$($CMMP)/CCM_Client/ccmsetup.exe" 
        $file = "c:\windows\temp\ccmsetup.exe" 
        $webclient.DownloadFile($url,$file) 

        #stop the old sms agent service 
        stop-service 'ccmexec' -ErrorAction $ErrorPreference

        #Cleanup cache 
        if($null -ne $ccmcache) 
        { 
            try 
            { 
            Get-ChildItem $ccmcache '*' -directory | ForEach-Object { [io.directory]::delete($_.fullname, $true)  } -ErrorAction $ErrorPreference
            } catch {} 
        } 

        $ccm = (Get-Process 'ccmsetup' -ErrorAction $ErrorPreference) 
        if($null -ne $ccm) 
        { 
                $ccm.kill(); 
        } 

        #run ccmsetup 
        Add-Content $Log_File  "$(Get-LogDate) - Client install starting"
        Start-Process -FilePath 'c:\windows\temp\ccmsetup.exe' -PassThru -Wait -ArgumentList "/mp:$($CMMP) /source:http://$($CMMP)/CCM_Client CCMHTTPPORT=portnumber-here /forceinstall RESETKEYINFORMATION=TRUE SMSSITECODE=$($CMSiteCode) SMSSLP=$($CMMP) FSP=$($CMMP)" 
        Start-Sleep -Seconds 5
        Add-Content $Log_File  "$(Get-LogDate) - Client install started"
    } 
    catch 
    { 
        Add-Content $Log_File  "$(Get-LogDate) - an Error occurred $_"
        Exit 1
    }
}

$Log_File = Set-LogFile -logName $scriptName
Add-Content $Log_File  "$(Get-LogDate) - Starting MECM Client Install check"
$sccmClient = (Get-WmiObject Win32_Service -ErrorAction $ErrorPreference | Where-Object {$_.Name -eq "ccmexec"})


# Checking if MECM client is already installed
if ($sccmClient.Status -eq $serviceStatus) {
    $cversion=(Get-WMIObject -namespace "root\ccm" -class sms_client).clientversion
    Add-Content $Log_File  "$(Get-LogDate) - Current MECM Installed Client version $cversion" 
    $sccmclient =Get-WmiObject -list -Namespace root\ccm -Class SMS_client -ErrorAction $ErrorPreference
    if (($sccmclient.getassignedsite()).ssitecode -eq $CMSiteCode) 
   { 
    #Client detected so exiting from script as no more actions are needed
    Add-Content $Log_File  "$(Get-LogDate) - SCCM Site code is $CMSiteCode - Client properly installed"
    Exit 0
   }
   else {
    Add-Content $Log_File  "$(Get-LogDate) - Wrong site code detected. Client needs to be reinstalled"
    # Wrong site code detected, emailing technicians set $sendemail to $true to enable
    if ($sendEmail) {
        $hostname = hostname
        $sendMailMessageSplat = @{
            From = $email
            To = $email
            Subject = "MECM Client needs to be fixed on $hostname"
            Body = "MECM Client site code is not: $CMSiteCode. Please check client $hostname"
            SmtpServer = 'post-office.uh.edu'
        }
        Send-MailMessage @sendMailMessageSplat -WarningAction SilentlyContinue
        Add-Content $Log_File  "$(Get-LogDate) - Email notification sent about wrong site code"
    }
   }
}
else {
    Add-Content $Log_File  "$(Get-LogDate) - Launching install of MECM Client"
    Install-MECMClient
}
