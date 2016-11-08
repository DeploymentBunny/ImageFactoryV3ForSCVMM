<#
.Synopsis
   Short description
.DESCRIPTION
   Long description
.EXAMPLE
   Example of how to use this cmdlet
.EXAMPLE
   Another example of how to use this cmdlet
#>
# Read Settings from XML
[xml]$Global:Settings = Get-Content E:\ImageFactoryV3\ImageFactoryV3.xml
$Global:StartUpRAM = 1024*1024*1024*$Global:Settings.Settings.Common.StartUpRAM
$Global:VLANID = $Global:Settings.Settings.Common.VLANID
$Global:ConcurrentRunningVMs = $Global:Settings.Settings.Common.ConcurrentRunningVMs

$Global:DeploymentShare = $Global:Settings.Settings.MDT.DeploymentShare
$Global:RefTaskSequenceFolder = $Global:Settings.Settings.MDT.RefTaskSequenceFolder

$Global:SWitchName = $Global:Settings.Settings.HyperV.HyperVHostNetwork
$Global:VMLocation = $Global:Settings.Settings.hyperv.HyperVStorage
$Global:HyperVISOFolder = $Global:Settings.Settings.HyperV.HyperVISOFolder
$Global:VHDSize = 1024*1024*1024*$Global:Settings.Settings.HyperV.VHDSize

$Global:SCVMMHost = $Global:Settings.Settings.SCVMM.SCVMMHost
$Global:SCVMMServerName = $Global:Settings.Settings.SCVMM.SCVMMServer
$Global:SCLibraryShareName = $Global:Settings.Settings.SCVMM.SCLibraryShare
$Global:VirtualHardDiskName = $Global:Settings.Settings.SCVMM.SCVMMVirtualHardDiskName
$Global:VMNetworkName = $Global:Settings.Settings.SCVMM.SCVMMNetworkName
$Global:SCVMMHostGroup = $Global:Settings.Settings.SCVMM.SCVMMHostGroup
$Global:SCVMMPortClassification = $Global:Settings.Settings.SCVMM.SCVMMPortClassification

Function Get-RefTaskSequence{
    $RefTaskSequences = Get-ChildItem $Global:RefTaskSequenceFolder
    Foreach($TS in $RefTaskSequences){
        New-Object PSObject -Property @{ 
        TaskSequenceID = $TS.ID
        Name = $TS.Name
        Comments = $TS.Comments
        Version = $TS.Version
        Enabled = $TS.enable
        LastModified = $TS.LastModifiedTime
        } 
        }
}
Function Create-VMBootFromISO{
    Param(
    $VMName=,
    $ISOName=,
    $VMNetworkName=,
    $VirtualHardDiskName=,
    $SCVMMServerName=,
    $SCVMMHostName = $Global:SCVMMHost
    )
    #Get Host
    $vmHost = Get-SCVMHost -ComputerName $SCVMMHostName

    #Generate GUID's
    $JobGroupID1 = [Guid]::NewGuid().ToString()
    $HardwareProfileID = [Guid]::NewGuid().ToString()
    $TemplateID = [Guid]::NewGuid().ToString()

    #Generate Hardware
    $ISO = Get-SCISO -VMMServer $SCVMMServerName | where {$_.Name -eq $ISOName}
    $VMNetwork = Get-SCVMNetwork -VMMServer $SCVMMServerName -Name $VMNetworkName
    $PortClassification = Get-SCPortClassification -VMMServer $SCVMMServerName | where {$_.Name -eq "High bandwidth"}
    $CPUType = Get-SCCPUType -VMMServer $SCVMMServerName | where {$_.Name -eq "3.60 GHz Xeon (2 MB L2 cache)"}
    $VirtualHardDisk = Get-SCVirtualHardDisk -VMMServer $SCVMMServerName | where {$_.Name -eq $VirtualHardDiskName} | where {$_.HostName -eq "$Global:SCVMMServerName"}
    New-SCVirtualScsiAdapter -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -AdapterID 7 -ShareVirtualScsiAdapter $false -ScsiControllerType DefaultTypeNoType 
    New-SCVirtualDVDDrive -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -Bus 1 -LUN 0 -ISO $ISO 
    New-SCVirtualNetworkAdapter -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -MACAddressType Dynamic -VLanEnabled $false -Synthetic -IPv4AddressType Dynamic -IPv6AddressType Dynamic -VMNetwork $VMNetwork -PortClassification $PortClassification 
    New-SCHardwareProfile -VMMServer $SCVMMServerName -CPUType $CPUType -Name "Profile$HardwareProfileID" -Description "Profile used to create a VM/Template" -CPUCount 2 -MemoryMB 3072 -DynamicMemoryEnabled $false -MemoryWeight 5000 -VirtualVideoAdapterEnabled $false -CPUExpectedUtilizationPercent 20 -DiskIops 0 -CPUMaximumPercent 100 -CPUReserve 0 -NumaIsolationRequired $false -NetworkUtilizationMbps 0 -CPURelativeWeight 100 -HighlyAvailable $false -DRProtectionRequired $false -NumLock $false -BootOrder "CD", "IdeHardDrive", "PxeBoot", "Floppy" -CPULimitFunctionality $false -CPULimitForMigration $false -Generation 1 -JobGroup $JobGroupID1
    New-SCVirtualDiskDrive -VMMServer $SCVMMServerName -IDE -Bus 0 -LUN 0 -JobGroup $JobGroupID1 -CreateDiffDisk $false -VirtualHardDisk $VirtualHardDisk -FileName "REF_Blank Disk - Large.vhdx" -VolumeType BootAndSystem 
    $HardwareProfile = Get-SCHardwareProfile -VMMServer $SCVMMServerName | where {$_.Name -eq "Profile$HardwareProfileID"}

    #Generate Template
    New-SCVMTemplate -Name "Temporary Template$TemplateID" -Generation 1 -HardwareProfile $HardwareProfile -JobGroup $JobGroupID1 -NoCustomization 

    #Generate Configuration
    $template = Get-SCVMTemplate -All | where { $_.Name -eq "Temporary Template$TemplateID" }
    $virtualMachineConfiguration = New-SCVMConfiguration -VMTemplate $template -Name $VMName
    Write-Output $virtualMachineConfiguration

    #Update Configuration W HostData
    Set-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration -VMHost $vmHost
    Update-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration

    #Update Configuration W Networkdata
    $AllNICConfigurations = Get-SCVirtualNetworkAdapterConfiguration -VMConfiguration $virtualMachineConfiguration
    Update-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration

    #Create VM
    New-SCVirtualMachine -Name $VMName -VMConfiguration $virtualMachineConfiguration -JobGroup $JobGroupID1
    Set-SCVirtualMachine -Tag "REFIMAGE" -VM (Get-SCVirtualMachine -Name $VMName)
}
Function Create-HAVMBootFromISO{
    Param(
    $VMName,
    $ISOName,
    $VMNetworkName,
    $VirtualHardDiskName,
    $SCVMMServerName,
    $SCVMMHostGroup,
    $SCVMMVLANID,
    $SCVMMPortClassification
    )

    #Generate GUID's
    $JobGroupID1 = [Guid]::NewGuid().ToString()
    $HardwareProfileID = [Guid]::NewGuid().ToString()
    $TemplateID = [Guid]::NewGuid().ToString()

    #Generate Hardware
    $ISO = Get-SCISO -VMMServer $SCVMMServerName | where {$_.Name -eq $ISOName}
    $VMNetwork = Get-SCVMNetwork -VMMServer $SCVMMServerName -Name $VMNetworkName
    $PortClassification = Get-SCPortClassification -VMMServer $SCVMMServerName | where {$_.Name -eq $SCVMMPortClassification}
    $CPUType = Get-SCCPUType -VMMServer $SCVMMServerName | where {$_.Name -eq "3.60 GHz Xeon (2 MB L2 cache)"}
    $VirtualHardDisk = Get-SCVirtualHardDisk -VMMServer $SCVMMServerName | where {$_.Name -eq $VirtualHardDiskName} | where {$_.HostName -eq "$Global:SCVMMServerName"}
    New-SCVirtualScsiAdapter -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -AdapterID 7 -ShareVirtualScsiAdapter $false -ScsiControllerType DefaultTypeNoType 
    New-SCVirtualDVDDrive -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -Bus 1 -LUN 0 -ISO $ISO 
    New-SCVirtualNetworkAdapter -VMMServer $SCVMMServerName -JobGroup $JobGroupID1 -MACAddressType Dynamic -VLanEnabled $false -Synthetic -IPv4AddressType Dynamic -IPv6AddressType Dynamic -VMNetwork $VMNetwork -PortClassification $PortClassification 

    New-SCHardwareProfile -VMMServer $SCVMMServerName -CPUType $CPUType -Name "Profile$HardwareProfileID" -Description "Profile used to create a VM/Template" -CPUCount 2 -MemoryMB 3072 -DynamicMemoryEnabled $false -MemoryWeight 5000 -VirtualVideoAdapterEnabled $false -CPUExpectedUtilizationPercent 20 -DiskIops 0 -CPUMaximumPercent 100 -CPUReserve 0 -NumaIsolationRequired $false -NetworkUtilizationMbps 0 -CPURelativeWeight 100 -HighlyAvailable $true -DRProtectionRequired $false -NumLock $false -BootOrder "CD", "IdeHardDrive", "PxeBoot", "Floppy" -CPULimitFunctionality $false -CPULimitForMigration $false -Generation 1 -JobGroup $JobGroupID1 -HAVMPriority 2000
    New-SCVirtualDiskDrive -VMMServer $SCVMMServerName -IDE -Bus 0 -LUN 0 -JobGroup $JobGroupID1 -CreateDiffDisk $false -VirtualHardDisk $VirtualHardDisk -FileName "REF_Blank Disk - Large.vhdx" -VolumeType BootAndSystem 
    $HardwareProfile = Get-SCHardwareProfile -VMMServer $SCVMMServerName | where {$_.Name -eq "Profile$HardwareProfileID"}

    #Generate Template
    New-SCVMTemplate -Name "Temporary Template$TemplateID" -Generation 1 -HardwareProfile $HardwareProfile -JobGroup $JobGroupID1 -NoCustomization 
    #Generate Configuration
    $template = Get-SCVMTemplate -All | where { $_.Name -eq "Temporary Template$TemplateID" }
    $virtualMachineConfiguration = New-SCVMConfiguration -VMTemplate $template -Name $VMName
    Write-Output $virtualMachineConfiguration

    $SCVMMHostGroup = Get-SCVMHostGroup $SCVMMHostGroup
    $prefVMHost = Get-SCVMHostRating -VMHostGroup $SCVMMHostGroup -VMTemplate $template -VMName $VMName -PlacementGoal LoadBalance -DiskSpaceGB 80 -ReturnFirstSuitableHost
    $vmHost = Get-SCVMHost $prefVMHost

    #Update Configuration W HostData
    Set-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration -VMHost $vmHost -VMLocation $prefVMHost.PreferredVolume.name
    Update-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration

    #Update Configuration W Networkdata
    $AllNICConfigurations = Get-SCVirtualNetworkAdapterConfiguration -VMConfiguration $virtualMachineConfiguration
    Update-SCVMConfiguration -VMConfiguration $virtualMachineConfiguration

    #Create VM
    New-SCVirtualMachine -Name $VMName -VMConfiguration $virtualMachineConfiguration -JobGroup $JobGroupID1
    Set-SCVirtualMachine -Tag "REFIMAGE" -VM (Get-SCVirtualMachine -Name $VMName) -BlockDynamicOptimization $true

    if(!($VLANID -eq 0)){Get-SCVirtualMachine -Name $VMName | Get-SCVirtualNetworkAdapter | Set-SCVirtualNetworkAdapter -VLanEnabled $true -VLanID $VLANID}
}
Function Upload-MDTBootImage{
    #Upload BootImage
    Read-SCLibraryShare -LibraryShare $SCLibraryShare 
    Import-SCLibraryPhysicalResource -SourcePath "$Global:DeploymentShare\Boot\$MDTISO" -SharePath "$($SCLibraryShare.Path)\ISO" -OverwriteExistingFiles
    $SCMDTBuildISO = Get-SCISO | Where Name -EQ $MDTISO
    Return $SCMDTBuildISO
}
Function Update-MDTBootImage{
    Update-MDTDeploymentShare -Path MDT:
}

#ImageFactory

#Connect to MDT
Import-Module -Global "C:\Program Files\Microsoft Deployment Toolkit\bin\MicrosoftDeploymentToolkit.psd1" -Force
if(!(Test-Path MDT:)){$MDTPSDrive = New-PSDrive -Name MDT -PSProvider MDTProvider -Root $Global:DeploymentShare -ErrorAction Stop}
Write-Host "Connected to $($MDTPSDrive.Root)"

#Connect to SCVMM
#Connnect to SCVMM
Import-Module -Global -Name  virtualmachinemanager,virtualmachinemanagercore
$SCVMMServer = Get-SCVMMServer -ComputerName $Global:SCVMMServerName -ErrorAction Stop
Write-Host "Connected to $($SCVMMServer.FullyQualifiedDomainName)"

#Get MDT Settings
$MDTSettings = Get-ItemProperty MDT:
$MDTISO = $MDTSettings.'Boot.x86.LiteTouchISOName'

#Get SCVMM Settings
$SCVMServer = Get-SCVMMServer -ComputerName $Global:SCVMMServerName
$SCLibraryShare = Get-SCLibraryShare | where Name -EQ $Global:SCLibraryShareName

#Update BootImage
Update-MDTBootImage

#Upload BootImage
Upload-MDTBootImage

#Get Ref Image Task Sequnce Names
$RefTaskSequenceIDs = (Get-RefTaskSequence | where Enabled -EQ $true).TasksequenceID
Write-Host "Found $($RefTaskSequenceIDs.count) TaskSequences:"
$RefTaskSequenceIDs

#check number of TS
if($RefTaskSequenceIDs.count -eq 0){Write-Warning "Sorry, could not find any TaskSequences to work with";BREAK}

#Create the VM's on Host
#Foreach($Ref in $RefTaskSequenceIDs){
#    Create-VMBootFromISO -VMName $Ref -ISOName $MDTISO -SCVMMServerName $Global:SCVMMServerName -SCVMMHostName $Global:SCVMMHost -VirtualHardDiskName $Global:VirtualHardDiskName -VMNetworkName $Global:VMNetworkName
#}

#Create the VM's in SCVMM HostGroup
Foreach($Ref in $RefTaskSequenceIDs){
    Create-HAVMBootFromISO -VMName $Ref -ISOName $MDTISO -SCVMMServerName $Global:SCVMMServerName -SCVMMHostGroup $Global:SCVMMHostGroup -VirtualHardDiskName $Global:VirtualHardDiskName -SCVMMPortClassification $Global:SCVMMPortClassification -SCVMMVLANID $Global:VLANID -VMNetworkName $Global:VMNetworkName
}

#Get the VMs as Objects
$RefVMs = Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" | Where-Object -Property Enabled -like -Value "True"
foreach($RefVM in $RefVMs){
    Write-Host "REFVM $($RefVM.Name) is allocated to $($RefVM.HostName) at $($refvm.Location)"
}

#Start VMs
foreach($RefVM in $RefVMs){
    $StartedVM = Start-SCVirtualMachine -VM $RefVM
    Write-Host "Starting $($StartedVM.name)"
    Do
        {
            $RunningVMs = $((Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" | Where-Object -Property Status -EQ -Value Running))
            Write-Host "Currently running VMs: $RunningVMs at $(Get-Date)"
            Start-Sleep -Seconds "30"
        
        }
    While((Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" | Where-Object -Property Status -EQ -Value Running).Count -gt ($Global:ConcurrentRunningVMs - 1))
    }

#Wait until they are done
Do{
    $RunningVMs = $((Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" | Where-Object -Property Status -EQ -Value Running))
    Write-Host "Currently running VMs: $RunningVMs at $(Get-Date)"
    Start-Sleep -Seconds "30"
        
}until((Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" | Where-Object -Property Status -EQ -Value Running).count -eq '0')

#Cleanup VMs
$RefVMs = Get-SCVirtualMachine | Where-Object -Property Tag -EQ -Value "REFIMAGE" 
Foreach($VM in $RefVMs){
    Write-Host "Deleting REFVM $($RefVM.Name) is allocated to $($RefVM.HostName) at $($refvm.Location)"
    Stop-SCVirtualMachine -VM $VM -Force -RunAsynchronously
    Remove-SCVirtualMachine -VM $VM -RunAsynchronously
}
