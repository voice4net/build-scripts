# ApplyVersionFromSourceControl.ps1

<#
	.SYNOPSIS

		Powershell script to be used as the pre-build script in a build definition on Team Foundation Server.
		Applies the version number from SharedAssemblyInfo.cs to the assemblies.
		Optionally increments the build or revision number. The default behavior is to increment the build number
		and not increment the revision number.
		Optionally checks in any changes made to the assembly info files. The default behavior is to check in changes.
		Changes the build number to match the version number applied to the assemblies.

	.DESCRIPTION

		This script assumes that your .NET solution contains an assembly info file, named SharedAssemblyInfo.cs, that is
		shared across all of the projects as a linked file.
		This layout is described in detail here: http://blogs.msdn.com/b/jjameson/archive/2009/04/03/shared-assembly-info-in-visual-studio-projects.aspx
		The SharedAssemblyInfo.cs file should at the very least contain an AssemblyVersion attribute.
		My SharedAssemblyInfo.cs file contains the following attributes:
			- AssemblyCompany
			- AssemblyProduct
			- AssemblyCopyright
			- AssemblyTrademark
			- AssemblyVersion
			- AssemblyFileVersion
			- AssemblyInformationalVersion
			
		Each project can still have it's own AssemblyInfo.cs file, but it should not contain any version number attributes,
		such as AssemblyVersion, AssemblyFileVersion, or AssemblyInformationalVersion.
		
		My AssemblyInfo.cs files contain the following attributes:
			- AssemblyTitle
			- AssemblyCulture
			- Guid

		The script locates the SharedAssemblyInfo.cs file after the TFS Build Server has downloaded all of the source files.
		Then it extracts the current version number from it. Then it optionally increments the version number and overwrites
		that file with the new version number. It also looks for files named app.rc (version files in C++ projects are named
		app.rc) and overwrites the version number there	as well.

		After it has edited all of the assembly info files that contain version numbers,
		it checks those changes back into source control.

		As TFS builds the assemblies the version number applied will match the new version number.

		The name of the build in the build definition should be named something that contains a stubbed out version number,
		e.g. $(BuildDefinitionName)_$(Date:yyyyMMddHHmmss)_1.0.0.0. The script will update the build number as the build is
		running so that the build number matches the version from source control as well as the version applied to the
		assemblies.

		To use this script:
			1. Check it into source control
			2. Select it as the pre-build script in your build definition in TFS under Process->Build->Advanced->Pre-build script path
			3. Add the parameters to the build definition under Process->Build->Advanced->Pre-build script arguments

		This script was inspired by:
			http://blogs.msdn.com/b/jjameson/archive/2009/04/03/shared-assembly-info-in-visual-studio-projects.aspx
			http://blogs.msdn.com/b/jjameson/archive/2009/04/03/best-practices-for-net-assembly-versioning.aspx
			http://blogs.msdn.com/b/jjameson/archive/2010/03/25/incrementing-the-assembly-version-for-each-build.aspx
			https://blogs.msdn.microsoft.com/visualstudioalm/2013/07/23/get-started-with-some-basic-tfbuild-scripts/
			http://stackoverflow.com/questions/30337124/set-tfs-build-version-number-powershell
			http://www.dotnetcurry.com/visualstudio/1035/environment-variables-visual-studio-2013-tfs

	.PARAMETER DoNotIncrement
		disable incrementing of version numbers and checkout/checkin of assembly info files
	.PARAMETER IncrementBuildNumber
		increment the build number before applying the version number to the assemblies
	.PARAMETER IncrementRevisionNumber
		increment the revision number before applying the version number to the assemblies
	.PARAMETER DoNotCheckIn
		disable checking in changes made to the assembly info files
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1 -IncrementBuildNumber
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1 -IncrementRevisionNumber
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1 -IncrementBuildNumber -IncrementRevisionNumber
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1 -DoNotIncrement
	.EXAMPLE
		powershell.exe -File .\ApplyVersionFromSourceControl.ps1 -IncrementBuildNumber -DoNotCheckIn
	.NOTES
		Author: Brad Foster
		Company: Voice4Net
		Web Page: www.voice4net.com
	.LINK
		http://github.com/voice4net/build-scripts/ApplyVersionFromSourceControl.ps1
#>

[CmdletBinding(PositionalBinding=$false)]

param([switch] $DoNotIncrement=$false,[switch] $IncrementBuildNumber=$true,[switch] $IncrementRevisionNumber=$false,[switch] $DoNotCheckIn=$false)

if ($PSBoundParameters.ContainsKey('DoNotIncrement'))
{
	# if the DoNotIncrement flag has been set, that overrides the other flags
	$IncrementRevisionNumber=$false
	$IncrementBuildNumber=$false
	$DoNotCheckIn=$true
}
elseif ($PSBoundParameters.ContainsKey('IncrementRevisionNumber') -eq $true -and $PSBoundParameters.ContainsKey('IncrementBuildNumber') -eq $false)
{
	# if IncrementRevisionNumber is set and IncrementBuildNumber is not set, disable incrementing the build number
	$IncrementRevisionNumber=$true
	$IncrementBuildNumber=$false
}

Write-Host "IncrementBuildNumber=$IncrementBuildNumber"
Write-Host "IncrementRevisionNumber=$IncrementRevisionNumber"
Write-Host "DoNotCheckIn=$DoNotCheckIn"

function File-Content-Contains-Version-Number([string] $filecontent)
{
	$pattern='AssemblyVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		return $true
	}

	$pattern='AssemblyFileVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		return $true
	}

	$pattern='AssemblyInformationalVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		return $true
	}

	$pattern='"FileVersion", "\d+\.\d+\.\d+\.\d+"' # "FileVersion", "9.0.0.0"

	if ($filecontent -match $pattern -eq $true)
	{
		return $true
	}

	return $false
}

function Extract-Version-Number([string] $filecontent)
{
	$pattern='AssemblyVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		$match=$matches[0]
		return $match.Substring(0, $match.Length - 2).Replace('AssemblyVersion("',[string]::Empty)
	}

	$pattern='AssemblyFileVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		$match=$matches[0]
		return $match.Substring(0, $match.Length - 2).Replace('AssemblyFileVersion("',[string]::Empty)
	}

	$pattern='AssemblyInformationalVersion\("\d+\.\d+\.\d+\.\d+"\)'

	if ($filecontent -match $pattern -eq $true)
	{
		$match=$matches[0]
		return $match.Substring(0, $match.Length - 2).Replace('AssemblyInformationalVersion("',[string]::Empty)
	}

	return [string]::Empty
}

function Increment-Version-Number([string] $CurrentVersion)
{
	if ([string]::IsNullOrEmpty($CurrentVersion))
	{
		return [string]::Empty
	}

	$tokens=$CurrentVersion.Split("{.}")

	if ($tokens.Length -ne 4)
	{
		return $CurrentVersion
	}

	if ($IncrementBuildNumber -eq $true)
	{
		$buildNumber=0

		if ([int32]::TryParse($tokens[2], [ref]$buildNumber) -eq $true)
		{
			$tokens[2]=[string]($buildNumber+1)
		}
	}

	if ($IncrementRevisionNumber -eq $true)
	{
		$revNumber=0

		if ([int32]::TryParse($tokens[3], [ref]$revNumber) -eq $true)
		{
			$tokens[3]=[string]($revNumber+1)
		}
	}

	return [string]::Join(".",$tokens)
}

function Modify-Build-Number([Microsoft.TeamFoundation.Build.Client.IBuildDetail] $BuildDetail,[string] $NewVersion)
{
	$pattern="\d+\.\d+\.\d+\.\d+"

	$OldBuildNumber=$BuildDetail.BuildNumber

	Write-Host "OldBuildNumber=$OldBuildNumber"

	$NewBuildNumber=$OldBuildNumber -replace $pattern,$NewVersion

	Write-Host "NewBuildNumber=$NewBuildNumber"

	$OldDropLocation=$BuildDetail.DropLocation

	Write-Host "OldDropLocation=$OldDropLocation"

	$NewDropLocation=$OldDropLocation.Replace($OldBuildNumber,$NewBuildNumber)

	Write-Host "NewDropLocation=$NewDropLocation"

	$OldLabelName=$BuildDetail.LabelName

	Write-Host "OldLabelName=$OldLabelName"

	$NewLabelName=$OldLabelName.Replace($OldBuildNumber,$NewBuildNumber)

	Write-Host "NewLabelName=$NewLabelName"

	# update the build number
	$BuildDetail.BuildNumber=$NewBuildNumber

	# update the build label name
	$BuildDetail.LabelName=$NewLabelName

	# update the drop location
	$BuildDetail.DropLocation=$NewDropLocation

	# save the changes
	$BuildDetail.Save()
}

function Create-New-File-Content([string] $FileContent,[string] $NewVersion)
{
	$NewContent=$FileContent

	$pattern='AssemblyVersion\("\d+\.\d+\.\d+\.\d+"\)'

	$NewContent=$NewContent -replace $pattern,[string]::Format('AssemblyVersion("{0}")',$NewVersion)

	$pattern='AssemblyFileVersion\("\d+\.\d+\.\d+\.\d+"\)'

	$NewContent=$NewContent -replace $pattern,[string]::Format('AssemblyFileVersion("{0}")',$NewVersion)

	$pattern='AssemblyInformationalVersion\("\d+\.\d+\.\d+\.\d+"\)'

	$NewContent=$NewContent -replace $pattern,[string]::Format('AssemblyInformationalVersion("{0}")',$NewVersion)

	$pattern='"FileVersion", "\d+\.\d+\.\d+\.\d+"'

	$NewContent=$NewContent -replace $pattern,[string]::Format('"FileVersion", "{0}"',$NewVersion)

	$pattern='"ProductVersion", "\d+\.\d+\.\d+\.\d+"'

	$NewContent=$NewContent -replace $pattern,[string]::Format('"ProductVersion", "{0}"',$NewVersion)

	$pattern='FILEVERSION \d+,\d+,\d+,\d+'

	$NewContent=$NewContent -replace $pattern,[string]::Format('FILEVERSION {0}',$NewVersion.Replace(".",","))

	$pattern='PRODUCTVERSION \d+,\d+,\d+,\d+'

	$NewContent=$NewContent -replace $pattern,[string]::Format('PRODUCTVERSION {0}',$NewVersion.Replace(".",","))

	return $NewContent
}

function Get-Source-Location([Microsoft.TeamFoundation.Build.Client.IBuildDefinition] $BuildDefinition,[string] $FileName)
{
	$SourceDir="$env:TF_BUILD_SOURCESDIRECTORY"
	$WorkspaceTemplate=$BuildDefinition.Workspace
	$MatchingLocalItem=[string]::Empty
	$MatchingServerItem=[string]::Empty

	<#
	SourceDir: F:\Builds\1\Code_V9_0\V4Email_DEV\src
	FileName: F:\Builds\1\Code_V9_0\V4Email_DEV\src\Code_V9_0\Dev\V4Email\Properties\SharedAssemblyInfo.cs
	LocalItem: $(SourceDir)\Code_V9_0\Dev\V4Email
	ServerItem: $/Code_V9_0/Dev/V4Email
	#>

	foreach ($Mapping in $WorkspaceTemplate.Mappings)
	{
		$LocalItem=$Mapping.LocalItem
		$ServerItem=$Mapping.ServerItem
		$LocalPath=$LocalItem.Replace('$(SourceDir)',$SourceDir)

		if ($FileName.Contains($LocalPath))
		{
			if ($LocalItem.Length -gt $MatchingLocalItem.Length)
			{
				$MatchingLocalItem=$LocalItem
				$MatchingServerItem=$ServerItem
			}
		}
	}

	Write-Host "LocalPath=$MatchingLocalItem"
	Write-Host "ServerPath=$MatchingServerItem"

	if ([string]::IsNullOrEmpty($MatchingLocalItem) -eq $false)
	{
		$LocalPath=$MatchingLocalItem.Replace('$(SourceDir)',$SourceDir)

		$SourceLocation=$FileName.Replace($LocalPath,$MatchingServerItem).Replace("\","/")

		Write-Host "SourceLocation=$SourceLocation"

		return $SourceLocation
	}

	return [string]::Empty
}

function Create-Temp-Path([string] $FileName)
{
	# there is an environment variable called TEMP that is a temp directory where the checked out files will be put temporarily
	# example: C:\Windows\SERVIC~2\LOCALS~1\AppData\Local\Temp

	# get temp directory
	$TempDir="$env:TEMP"

	# get file name and extension from full path
	$FileName=[System.IO.Path]::GetFileName($FileName)

	# combine the temp dir and file name
	return [string]::Format("{0}\{1}",$TempDir,$FileName)
}

function Create-Mapping([Microsoft.TeamFoundation.VersionControl.Client.Workspace] $WorkSpace,[string] $SourcePath,[string] $TempPath)
{
	# create a working folder mapping
	$Mapping=New-Object Microsoft.TeamFoundation.VersionControl.Client.WorkingFolder -ArgumentList $SourcePath,$TempPath

	# add the mapping to the workspace
	$WorkSpace.CreateMapping($Mapping)

	return $Mapping
}

function Check-Out([Microsoft.TeamFoundation.VersionControl.Client.Workspace] $WorkSpace,[string] $SourcePath,[string] $TempPath)
{
	# set recursion type to None
	$RecursionType=[Microsoft.TeamFoundation.VersionControl.Client.RecursionType]::None

	# create the item to get from source control
	$ItemSpec=New-Object Microsoft.TeamFoundation.VersionControl.Client.ItemSpec -ArgumentList $SourcePath,$RecursionType

	# set version spec to Latest
	$VersionSpec=[Microsoft.TeamFoundation.VersionControl.Client.VersionSpec]::Latest

	# create the get request
	$GetRequest=New-Object Microsoft.TeamFoundation.VersionControl.Client.GetRequest -ArgumentList $ItemSpec,$VersionSpec

	# set the get options
	$GetOptions=[Microsoft.TeamFoundation.VersionControl.Client.GetOptions]::GetAll

	# get the file from source control
	[void]$WorkSpace.Get($GetRequest,$GetOptions)

	# check out the file for edit
	[void]$WorkSpace.PendEdit($TempPath)
}

function Check-In-Pending-Changes([Microsoft.TeamFoundation.VersionControl.Client.Workspace] $WorkSpace,[string] $NewVersion)
{
	# get pending changes
	$PendingChanges=$WorkSpace.GetPendingChanges()

	# create a check-in comment
	$Comment=[string]::Format("version {0} checked in by TFS Build Server",$NewVersion)

	# check in pending changes
	$ChangeSet=$WorkSpace.CheckIn($PendingChanges,$Comment)

	Write-Host "ChangeSet=$ChangeSet"
}

function Remove-Mapping([Microsoft.TeamFoundation.VersionControl.Client.Workspace] $WorkSpace,[Microsoft.TeamFoundation.VersionControl.Client.WorkingFolder] $Mapping)
{
	# delete the mapping from the workspace
	$WorkSpace.DeleteMapping($Mapping)
}

if (-not $env:TF_BUILD_SOURCESDIRECTORY)
{
	Write-Host ("TF_BUILD_SOURCESDIRECTORY environment variable is missing.")
	exit 1
}

if (-not (Test-Path $env:TF_BUILD_SOURCESDIRECTORY))
{
	Write-Host "TF_BUILD_SOURCESDIRECTORY does not exist: $Env:TF_BUILD_SOURCESDIRECTORY"
	exit 1
}

if (-not $env:TF_BUILD_BUILDURI)
{
	Write-Host ("TF_BUILD_BUILDURI environment variable is missing.")
	exit 1
}

if (-not $env:TF_BUILD_COLLECTIONURI)
{
	Write-Host ("TF_BUILD_COLLECTIONURI environment variable is missing.")
	exit 1
}

if (-not $env:TEMP)
{
	Write-Host ("TEMP environment variable is missing.")
	exit 1
}

Write-Host "TF_BUILD_SOURCESDIRECTORY: $env:TF_BUILD_SOURCESDIRECTORY"
Write-Host "TF_BUILD_BUILDURI: $env:TF_BUILD_BUILDURI"
Write-Host "TF_BUILD_COLLECTIONURI: $env:TF_BUILD_COLLECTIONURI"
Write-Host "TEMP: $env:TEMP"

$CurrentVersion=[string]::Empty
$NewVersion=[string]::Empty

# find the SharedAssemblyInfo.cs file
$files=Get-ChildItem $Env:TF_BUILD_SOURCESDIRECTORY -recurse -include SharedAssemblyInfo.cs

if ($files -and $files.count -gt 0)
{
	foreach ($file in $files)
	{
		Write-Host "FileName=$file"

		# read the file contents
		$FileContent=[IO.File]::ReadAllText($file,[Text.Encoding]::Default)

		# check the file contents for a version number
		if (-not (File-Content-Contains-Version-Number($FileContent)))
		{
			# this file does not contain a version number. keep searching...
			continue
		}

		# extract the version number from the file contents
		$CurrentVersion=Extract-Version-Number($FileContent)

		# check the version number
		if ([string]::IsNullOrEmpty($CurrentVersion) -eq $false)
		{
			# found the version number. stop searching.
			break
		}
	}
}

Write-Host "CurrentVersion=$CurrentVersion"

if ([string]::IsNullOrEmpty($CurrentVersion))
{
	Write-Host "failed to retrieve the current version number. exit."
	exit
}

# load the TFS assemblies
[void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Client")
[void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.Build.Client")
[void][System.Reflection.Assembly]::LoadWithPartialName("Microsoft.TeamFoundation.VersionControl.Client")

# get the TFS URLs from environment variables
$CollectionUrl="$env:TF_BUILD_COLLECTIONURI"
$BuildUrl="$env:TF_BUILD_BUILDURI"

# get the team project collection
$TeamProjectCollection=[Microsoft.TeamFoundation.Client.TfsTeamProjectCollectionFactory]::GetTeamProjectCollection($CollectionUrl)

# get the build server
$BuildServer=$TeamProjectCollection.GetService([Microsoft.TeamFoundation.Build.Client.IBuildServer])

# get the build detail
$BuildDetail=$BuildServer.GetBuild($BuildUrl)

# get the build definition
$BuildDefinition=$BuildDetail.BuildDefinition

# check the DoNotCheckIn flag
if ($DoNotCheckIn -eq $false)
{
	# get the version control server
	$VersionControlServer=$TeamProjectCollection.GetService([Microsoft.TeamFoundation.VersionControl.Client.VersionControlServer])

	# create a temporary workspace. workspace names must be unique, therefore use a guid
	$WorkSpace=$VersionControlServer.CreateWorkSpace([string]([GUID]::NewGuid()))
}

# check the increment flags
if ($IncrementBuildNumber -eq $true -or $IncrementRevisionNumber -eq $true)
{
	# increment the version number
	$NewVersion=Increment-Version-Number($CurrentVersion)
}
else
{
	# use the current version number
	$NewVersion=$CurrentVersion
}

Write-Host "NewVersion=$NewVersion"

# change the build number and drop location
Modify-Build-Number $BuildDetail $NewVersion

# find all files that might contain version numbers
$files=Get-ChildItem $Env:TF_BUILD_SOURCESDIRECTORY -recurse -include SharedAssemblyInfo.cs,AssemblyInfo.cs,app.rc

if ($files -and $files.count -gt 0)
{
	foreach ($file in $files)
	{
		# read the file contents
		$FileContent=[IO.File]::ReadAllText($file,[Text.Encoding]::Default)

		# check the file contents for a version number
		if (-not (File-Content-Contains-Version-Number($FileContent)))
		{
			# this file does not contain a version number
			continue
		}

		Write-Host "FileName=$file"

		# overwrite the old version number with the new version number
		$NewContent=Create-New-File-Content $FileContent $NewVersion

		# overwrite the contents of the file
		Set-Content -path $file -value $NewContent -encoding String -force

		# check the DoNotCheckIn flag
		if ($DoNotCheckIn -eq $true)
		{
			# skip the checkout/checkin process
			continue
		}

		# get the source location of this file
		$SourceLocation=Get-Source-Location $BuildDefinition $file

		if ([string]::IsNullOrEmpty($SourceLocation))
		{
			Write-Host "failed to determine the source location. skip checking out the file."
			continue
		}

		# create a temp path to save the checked out file
		$TempPath=Create-Temp-Path($file)

		Write-Host "TempPath=$TempPath"

		# create a working folder mapping
		$Mapping=Create-Mapping $WorkSpace $SourceLocation $TempPath

		# get the latest version and check it out
		Check-Out $WorkSpace $SourceLocation $TempPath

		# overwrite the contents of the checked out file
		Set-Content -path $TempPath -value $NewContent -encoding String -force

		# check in the pending change
		Check-In-Pending-Changes $WorkSpace $NewVersion

		# remove the mapping from the workspace
		Remove-Mapping $WorkSpace $Mapping

		# change the file attributes so it can be deleted
		[IO.File]::SetAttributes($TempPath, [IO.FileAttributes]::Normal)

		# delete the temp file
		[IO.File]::Delete($TempPath)
	}
}
else
{
	Write-Host "found no assembly info files."
}

if ($WorkSpace)
{
	# delete the workspace
	[void]$WorkSpace.Delete()
}
