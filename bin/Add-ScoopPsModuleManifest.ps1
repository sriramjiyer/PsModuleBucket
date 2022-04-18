[CmdletBinding()]
param(
    # Name of module to install
    [Parameter(Mandatory, ValueFromPipelineByPropertyName, ValueFromPipeline, Position = 0 )]
    [string]
    $Name,

    # Version of module to install
    [Parameter(ValueFromPipelineByPropertyName, Position = 1 )]
    [version]
    $Version = $null,

    # Recreate manifest if it exists
    [switch]
    $Force
)

begin {
    Add-Type -AssemblyName System.Web
    Function Get-PowershellGalleryUri($Type, $ModuleName, $Version) {
        $Filter = switch -Regex ($Type) {
            'home|download' { '' }
            'query' { "`$filter=Id eq '$ModuleName' and $( if ($Version) {"Version eq '$Version'"} else {'IsLatestVersion eq true'})" }
            'checkver' { "`$filter=Id eq '$ModuleName' and IsLatestVersion eq true" }
            'hash' { "`$filter=Id eq '$ModuleName' and Version eq '`$version'" }
        }
        $Uri = [System.UriBuilder]@{
            Scheme = 'https'
            Host   = 'www.powershellgallery.com'
            Path   = switch -Regex ($Type) {
                'query|checkver|hash' { '/api/v2/Packages()' }
                'home' { "/packages/$ModuleName" }
                'download' { "/Package/$ModuleName/`$version#/mod.nupkg" }
            }
            Query  = $Filter
        }
        # $Uri.ToString()
        'https://www.powershellgallery.com{0}{1}' -f
        $(
            switch -Regex ($Type) {
                'query|checkver|hash' { '/api/v2/Packages()' }
                'home' { "/packages/$ModuleName" }
                'download' { "/api/v2/Package/$ModuleName/`$version#/mod.nupkg" }
            }
        ),
        $(
            switch -Regex ($Type) {
                'home|download' { '' }
                'query' { "?`$filter=Id eq '$ModuleName' and $( if ($Version) {"Version eq '$Version'"} else {'IsLatestVersion eq true'})" }
                'checkver' { "?`$filter=Id eq '$ModuleName' and IsLatestVersion eq true" -replace ' ', '%20' }
                'hash' { "?`$filter=Id eq '$ModuleName' and Version eq '`$version'" }
            }
        )
    }

    $BucketDir = "$psscriptroot/../bucket"
    $null = Resolve-Path -Path $BucketDir -ErrorAction Stop

    $CheckVer = "$psscriptroot/checkver.ps1"
    $null = Resolve-Path -Path $CheckVer -ErrorAction Stop
}

process {
    $ManifestPath = "$BucketDir/$Name.json"
    if ( ( Test-Path $ManifestPath ) -and -not $Force ) {
        throw "Manifest already exists for $Name at $ManifestPath"
    }
    $ModuleInfo = ( Invoke-RestMethod -Uri ( Get-PowershellGalleryUri 'query' $Name $Version ) ).properties
    if ( -not $ModuleInfo ) {
        throw "Powershell module $Name not found in Powershell gallery"
    }
    $Dependencies = @( $ModuleInfo.Dependencies -split ':[^:]+:\|*' | Where-Object { $_ } )
    $Dependencies |
    ForEach-Object { 
        try {
            & "$psscriptroot\Add-ScoopPsModuleManifest.ps1"  -Name $_
        }
        catch {
            if ( -Not $_.Exception.Message.StartsWith('Manifest already exists for ') ) {
                throw
            }
        }
    }
    @{
        'version'     = 'To be generated by checkver'
        'url'         = 'to be generated by checkver'
        'hash'        = 'to be generated by checkver'
        'description' = $ModuleInfo.Description
        'homepage'    = Get-PowershellGalleryUri 'home' $ModuleInfo.Id 
        'license'     =
        if ($ModuleInfo.LicenseUrl.null) {
            'Unknown'
        }
        else {
            @{
                'url' = $ModuleInfo.LicenseUrl
            }
        }
        'checkver'    =
        @{
            'url'     = Get-PowershellGalleryUri 'checkver' $ModuleInfo.Id
            'regex'   = '(?i)<d:Version>(?<ver>[^<]+)<.d:Version>'
            'replace' = '${ver}'
        }
        'autoupdate'  =
        @{
            'url'  = Get-PowershellGalleryUri 'download' $ModuleInfo.Id
            'hash' = @{
                'url'   = Get-PowershellGalleryUri 'hash' $ModuleInfo.Id
                'regex' = '<d:PackageHash>$base64<.d:PackageHash>'
            }
        }
        'depends'     = $Dependencies
        'psmodule'    = @{
            'name' = $ModuleInfo.Id
        }
    } |
    ConvertTo-Json -Depth 5 |
    Set-Content -Path "$BucketDir/$($ModuleInfo.Id).json" -Encoding ascii -NoNewline
    
    & $CheckVer -App $ModuleInfo.Id -Update
}

end {}