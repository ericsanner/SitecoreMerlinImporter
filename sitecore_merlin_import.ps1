<#
    .SYNOPSIS
       Sitecore Merlin Importer
        
    .DESCRIPTION
        Includes helper functions to write custom content importers for Sitecore
        
    .NOTES	
        Eric Sanner | Perficient | eric.sanner@perficient.com | https://www.linkedin.com/in/ericsanner/
		
	.TODO
		Import media	
#>

#BEGIN Config
$database = "master"
$masterIndex = "sitecore_master_index"
$webIndex = "sitecore_web_index"
$allowDelete = $false
#END Config

#BEGIN Helper Functions

function Write-LogExtended {
	param(
		[string]$Message,
		[System.ConsoleColor]$ForegroundColor = $host.UI.RawUI.ForegroundColor,
		[System.ConsoleColor]$BackgroundColor = $host.UI.RawUI.BackgroundColor
	)

	Write-Log -Object $message
	Write-Host -Object $message -ForegroundColor $ForegroundColor -BackgroundColor $backgroundColor
}

function Truncate-Output {
	param (
		$obj,
		$maxLeng
	)
	
	$ret = "";
	
	if($obj -ne $null)
	{
		$str = $obj.ToString().Trim()
		$leng = [System.Math]::Min($str.Length, $maxLeng)
		$truncated = ($str.Length -gt $maxLeng)
		
		$ret = $str.Substring(0, $leng)
		if($truncated -eq $true)
		{
			$ret = $ret + "..."
		}
	}

	return $ret
}

function Get-SourceDataFromFile {
	param(
		[string]$path,
		[string]$encoding = "utf8"
	)
	
	return Get-Content -Path $path -Encoding $encoding -Raw
}

function Get-SourceDataFromUrl {
	param(
		[string]$uri
	)
	
	#TODO: Include authorization
		
	Invoke-WebRequest -Uri $uri -UseBasicParsing
}

function Convert-DataToJson {
	param(
		[string]$data
	)
	
	return ConvertFrom-Json $data
}

#END Helper Functions

#BEGIN Sitecore Functions

function Get-SitecoreItemByPath {
	#Returned Item uses item.ID
	#https://doc.sitecorepowershell.com/working-with-items#get-item-by-path
	param(
		[string]$path
	)

	return Get-Item -Path "${database}:${path}" -ErrorAction SilentlyContinue
}


function Index-SitecoreItems {
	#https://doc.sitecorepowershell.com/appendix/indexing/initialize-searchindexitem
	param (
		[Sitecore.Data.Items.Item]$itemRoot,
		[string]$index = "master"
	)
	
	if($index -eq "web")
	{
		$index = $webIndex
	}
	else
	{
		$index = $masterIndex
	}
		
	Write-LogExtended "[I] Updating $($index) for $($itemRoot.ID) - $($itemRoot.Paths.Path)"
	
	Initialize-SearchIndexItem -Item $itemRoot -Name $index
}

function Find-SitecoreItems {	
	#Find-Item uses content search api.  
	#Search service must be running and indexes must to be up to date.  
	#Will only search for fields that are indexed.
	#Could miss items that are recently added (In this case use Get-Item)
	#Returned Items use item.ID (because of "| Initialize-Item", otherwise returned items use item.ItemId).
	#https://doc.sitecorepowershell.com/appendix/indexing/find-item
	#https://doc.sitecorepowershell.com/appendix/indexing/initialize-item
	param(
		[array]$criteria
	)	
	
	return Find-Item -Index $masterIndex -Criteria $criteria | Initialize-Item
}

function Get-ValidSitecoreItemName {
	#https://sitecore.stackexchange.com/questions/27307/creating-a-new-item-with-in-itemname Removes any invalid characters based on InvalidItemNameChars in the config
	#https://www.regular-expressions.info/lookaround.html#lookahead Replaces multiple -- with a single -
	param (
		[string]$itemName
	)	
	
	#TODO: ProposeValidItemName cannot accept an empty string
	
	if($itemName -ne $null -or $itemName -ne "")
	{		
		$itemName = [Sitecore.Data.Items.ItemUtil]::ProposeValidItemName($itemName)
		$itemName = $itemName -replace " ", "-"
		$itemName = $itemName -replace "-(?=-)", "$1"
		$itemName = $itemName.ToLower()
	}
	
	return $itemName 
}

#TODO - Add intermediateItemTemplateId param instead of hard coding folderTemplateId
function Get-NewOrExistingSitecoreItemByPath {
	param (
		[Sitecore.Data.Items.Item]$itemRoot,		
		[string]$itemTemplateId,
		[string]$path,
		[string]$lang = "en"
	)
			
	$folderTemplateId = "{A87A00B1-E6DB-45AB-8B54-636FEC3B5523}"
		
	#Remove leading and trailing slashs
	$path = $path -replace '^/([.]*)', '$1'
	$path = $path -replace '(.*)/$', '$1'	
	
	$fullPath = "$($itemRoot.Paths.FullPath)/$($path)"
	
	#Does the item already exist?
	if(Test-Path -Path $fullPath)
	{
		$item = Get-SitecoreItemByPath $fullPath
		Write-LogExtended "[I] Found existing item $($item.ID) - $($item.Name)"
	}
	else
	{
		#Set intital folder
		$folder = $itemRoot
		
		$paths = $path.Split("/")
		for($i = 0; $i -lt $paths.Length - 1; $i++)
		{			
			$folder = Get-NewOrExistingSitecoreItem $folder $folderTemplateId $paths.Get($i) $lang
		}
				
		$item = Get-NewOrExistingSitecoreItem $folder $itemTemplateId $paths.Get($paths.Length - 1) $lang
	}
	
	return $item	
}

function Get-NewOrExistingSitecoreItemById {
	#https://doc.sitecorepowershell.com/working-with-items#new-item
	param (
		[Sitecore.Data.Items.Item]$itemRoot,
		[string]$itemTemplateId,
		[string]$itemId,
		[string]$itemName,
		[string]$lang = "en"
	)
	
	$item = $null
	$itemName = Get-ValidSitecoreItemName $itemName
	$itemPath = "$($itemRoot.Paths.Path)/$($itemName)"
		
	if(Test-Path -Path $itemPath)
	{
		$item = Get-SitecoreItemByPath $itemPath
		Write-LogExtended "[I] Found existing item $($item.ID) - $($item.Name)"
	}
	else
	{		
		$item = New-Item -Parent $itemRoot -ItemType $itemTemplateId -ForceId $itemId -Name $itemName -Language $lang
		Write-LogExtended "[A] Created new item $($item.ID) - $($item.Name)"
	}	
		
	return $item
}

#TODO: Make this function a little more flexible so the method signatures are more consistant
function Get-NewOrExistingSitecoreItem {
	#https://doc.sitecorepowershell.com/working-with-items#new-item
	param (
		[Sitecore.Data.Items.Item]$itemRoot,
		[string]$itemTemplateId,
		[string]$itemName,
		[string]$lang = "en"
	)
	
	$item = $null
	$itemName = Get-ValidSitecoreItemName $itemName
	$itemPath = "$($itemRoot.Paths.Path)/$($itemName)"
		
	if(Test-Path -Path $itemPath)
	{
		$item = Get-SitecoreItemByPath $itemPath
		Write-LogExtended "[I] Found existing item $($item.ID) - $($item.Name)"
	}
	else
	{		
		$item = New-Item -Parent $itemRoot -ItemType $itemTemplateId -Name $itemName -Language $lang
		Write-LogExtended "[A] Created new item $($item.ID) - $($item.Name)"
	}	
		
	return $item
}

#TODO: Made value comparison case sensative
function Update-SitecoreItem {
	#Reads key/value pairs in hashtable to update item
	#Any keys in the hashtable that are not available on the item are skipped
	#Item is only updated if at least one value was updated
	#https://learn.microsoft.com/en-us/powershell/scripting/lang-spec/chapter-10?view=powershell-7.3
	param(
		[Sitecore.Data.Items.Item]$item,
		[System.Collections.Hashtable]$updates
	)
	
	if($item -eq $null)
	{
		Write-LogExtended "[E] Error updating item $($item) - Item is null" Red
	    return
	}
	
	if($updates -eq $null)
	{
		Write-LogExtended "[E] Error updating item $($item) - Update hashtable is null" Red
		return
	}
		
	$changeDetected = $false
	$foregroundColor = "Green"
	
	Write-LogExtended "[I] Updating Item $($item.ID) - $($item.Name)"
	$item.Editing.BeginEdit()
	
	foreach($key in $updates.GetEnumerator())
	{
	    if($item.($key.Name) -ne $null)
	    {
	        $output = "Field Name '$($key.Name)' Current Value: '$(Truncate-Output $item.($key.Name) 40)' New Value: '$(Truncate-Output $key.Value 40)'"			
	        
	        if($item.($key.Name) -cne $key.Value)
	        {
	            Write-LogExtended "[U] $($output)"
	            $item.($key.Name) = $key.Value
	            $changeDetected = $true
	        }
	        else
	        {
	            Write-LogExtended "[-] $($output)"
	        }
	    }
	}
	
	$itemModified = $item.Editing.EndEdit()
	
	if($changeDetected -ne $itemModified)
	{
	    $foregroundColor = "Red"
	}
	
	Write-LogExtended "[I] Change Detected: $($changeDetected) Item modified $($itemModified)" $foregroundColor
}

function Remove-SitecoreItem {
	param(
		[Sitecore.Data.Items.Item]$item,
		[boolean]$delete = $false
	)
	
	if($item -eq $null)
	{
		Write-LogExtended "[E] Error removing item $($item) - Item is null" Red
	    return
	}
	
	$itemRemoved = $null
	
	if($allowDelete -and $delete)
	{
		$itemRemoved = ($item.Delete() -or $true)
		
		if($itemRemoved -ne $null)
		{
			Write-LogExtended "[D] Item $($item.ID) deleted"    
		}
	}
	else
	{		
		$itemRemoved = $item.Recycle()		
	
		if($itemRemoved -ne $null)
		{
			Write-LogExtended "[R] Item $($item.ID) moved to recycle bin"    
		}
	}
	
	if($itemRemoved -eq $null)
	{
	    Write-LogExtended "[E] Error removing item $($item.ID)" Red
	}
}

function Publish-SitecoreItem {
	#https://doc.sitecorepowershell.com/appendix/common/publish-item
	param (
		[Sitecore.Data.Items.Item]$item,
		[string]$lang = "en"
	)
	
	Write-LogExtended "[I] Publishing $($item.ID) - $($item.Paths.Path)"
	
	Publish-Item -Item $item -PublishMode Smart -Language $lang
}

function Publish-SitecoreItemAndChildren {
	#https://doc.sitecorepowershell.com/appendix/common/publish-item
	param (
		[Sitecore.Data.Items.Item]$item,
		[string]$lang = "en"
	)
	
	Write-LogExtended "[I] Publishing $($item.ID) - $($item.Paths.Path) and children"
	
	Publish-Item -Item $item -PublishMode Smart -Language $lang -Recurse
}

#END Sitecore Functions


#BEGIN Import Functions

function ReadSourceData {
	param (
		[string]$fileName
	)
	$data = Get-SourceDataFromFile "c:\inetpub\wwwroot\$($fileName)"
		
	return Convert-DataToJson $data
}

function IterateSourceData-Categories {
	param (
		[System.Object[]]$dataArray,
		[Sitecore.Data.Items.Item]$categoryRootItem,
		[string]$categoryItemId
	)
	
	Write-LogExtended "[I] Iterating Source Data - Categories"
	
	Foreach($data in ($dataArray.data | Get-Member -MemberType NoteProperty).Name)
	{
		$item = $null
		
		Write-LogExtended "[I] Importing category $($dataArray.data.$data.name)"	
				
		$item = Get-NewOrExistingSitecoreItemById $categoryRootItem $categoryItemId $dataArray.data.$data.uuid $dataArray.data.$data.name
		
		$updates = @{}
		$updates.Add("Title", $($dataArray.data.$data.name))
		
		Update-SitecoreItem $item $updates
	}
	
	Publish-SitecoreItemAndChildren $categoryRootItem
	Index-SitecoreItems $categoryRootItem "master"
	Index-SitecoreItems $categoryRootItem "web"	
}

function IterateSourceData-Blogs {
	param (
		[System.Object[]]$dataArray
	)
	
	Write-LogExtended "[I] Iterating Source Data - Blogs"
	
	$rootItem = $null
	
	Foreach($data in $dataArray)
	{
		$item = $null
		
		Write-LogExtended "[I] Importing blog $($data.url)"				
		
		if($rootItem -eq $null)
		{
			$rootItem = Get-SitecoreItemByPath $data.sitecore_root_path
		}
		
		$item = Get-NewOrExistingSitecoreItemByPath $rootItem $data.sitecore_template_id $data.url
		
		if($item -ne $null)
		{			
			$updates = @{}
			#$updates.Add("__Display name", )
			
			$updates.Add("MetaKeywords", "")
			$updates.Add("MetaDescription", $data.meta_description)
			
			$updates.Add("OpenGraphTitle", $data.title)
			$updates.Add("OpenGraphDescription", $data.meta_og_description)
			$updates.Add("OpenGraphImageUrl", $data.meta_og_image)
			$updates.Add("OpenGraphType", $data.meta_og_type)
			$updates.Add("OpenGraphSiteName", $data.meta_og_sitename)
			$updates.Add("OpenGraphAdmins", "")
			$updates.Add("OpenGraphAppId", "")
			
			$updates.Add("TwitterTitle", $data.title)
			$updates.Add("TwitterSite", "")
			$updates.Add("TwitterDescription", "")
			$updates.Add("TwitterImage", "")
			$updates.Add("TwitterCardType", "")
			
			$updates.Add("Title", $data.title)
			$updates.Add("Content", $data.content.value)		
			
			$updates.Add("NavigationTitle", $data.title)
			
			$updates.Add("__Semantics", $data.categories -join "|")

			Update-SitecoreItem $item $updates
		}
	}

	Publish-SitecoreItemAndChildren $rootItem
	Index-SitecoreItems $rootItem "master"
	Index-SitecoreItems $rootItem "web"	
}

#END Import Functions

#BEGIN Main

	$categoryRootItem = Get-SitecoreItemByPath "/sitecore/content/ESTest/Prft/Data/Categories"
	$categoryItemId = "{6B40E84C-8785-49FC-8A10-6BCA862FF7EA}"
	$categoryData = ReadSourceData "category.json"
	IterateSourceData-Categories $categoryData $categoryRootItem $categoryItemId
	
	$blogData = ReadSourceData "blogs.json"	
	IterateSourceData-Blogs $blogData
	
#END Main