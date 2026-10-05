param(
    [Parameter(Mandatory)][string]$CredentialDirectory,
    [string]$GhPath = 'gh',
    [switch]$Configure
)
$ErrorActionPreference = 'Stop'
$repo = 'gnaboret/nabcam-ios'
$environment = 'apple-testflight'
$bundle = 'com.gnabcamirl.app'
function Secret([string]$name) {
    return [IO.File]::ReadAllText((Join-Path $CredentialDirectory "$name.txt")).Trim()
}
function B64Url([byte[]]$bytes) {
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}
function Apple([string]$path, [string]$method = 'GET', $body = $null) {
    try {
        $args = @{ Uri = "https://api.appstoreconnect.apple.com/v1/$path"; Method = $method;
            Headers = @{ Authorization = "Bearer $script:token" }; ContentType = 'application/json' }
        if ($null -ne $body) { $args.Body = ($body | ConvertTo-Json -Depth 20 -Compress) }
        return Invoke-RestMethod @args
    } catch { throw "Apple API request failed for $method $($path.Split('?')[0]); no credentials were printed." }
}
function GitHub([string[]]$arguments, [string]$inputText = '') {
    $start = [Diagnostics.ProcessStartInfo]::new($GhPath)
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.Write($inputText)
    $process.StandardInput.Close()
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $outputTask.GetAwaiter().GetResult()
    $null = $errorTask.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0) { throw 'GitHub configuration failed; private command output was suppressed.' }
    return $output
}
try {
    $keyId = Secret 'APP_STORE_CONNECT_API_KEY_ID'
    $issuer = Secret 'APP_STORE_CONNECT_ISSUER_ID'
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = B64Url ([Text.Encoding]::UTF8.GetBytes((@{ alg='ES256'; kid=$keyId; typ='JWT' } | ConvertTo-Json -Compress)))
    $payload = B64Url ([Text.Encoding]::UTF8.GetBytes((@{ iss=$issuer; iat=$now; exp=$now+600; aud='appstoreconnect-v1' } | ConvertTo-Json -Compress)))
    $signer = [Security.Cryptography.ECDsa]::Create()
    try {
        $pem = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Secret 'APP_STORE_CONNECT_API_KEY_BASE64')))
        $signer.ImportFromPem($pem)
        $signature = $signer.SignData([Text.Encoding]::UTF8.GetBytes("$header.$payload"),
            [Security.Cryptography.HashAlgorithmName]::SHA256,
            [Security.Cryptography.DSASignatureFormat]::IeeeP1363FixedFieldConcatenation)
        $script:token = "$header.$payload.$(B64Url $signature)"
    } finally { $signer.Dispose(); $pem = $null }
    $apps = @( (Apple "apps?filter[bundleId]=$bundle").data )
    $bundles = @( (Apple "bundleIds?filter[identifier]=$bundle").data )
    if ($apps.Count -ne 1 -or $bundles.Count -ne 1) { throw 'Expected one existing GNAB app and explicit bundle ID.' }
    $certificateContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $CredentialDirectory 'distribution.cer')))
    $certificates = @( (Apple 'certificates?limit=200').data | Where-Object {
        $_.attributes.certificateContent -eq $certificateContent -and
        $_.attributes.certificateType -in @('DISTRIBUTION','IOS_DISTRIBUTION') -and
        [DateTimeOffset]$_.attributes.expirationDate -gt [DateTimeOffset]::UtcNow.AddDays(7)
    })
    if ($certificates.Count -ne 1) { throw 'No unexpired Apple distribution certificate matches the local public certificate.' }
    $builds = @( (Apple "builds?filter[app]=$($apps[0].id)&sort=-uploadedDate&limit=5").data )
    Write-Host "Verified app: $($apps[0].attributes.name), bundle $bundle, app ID $($apps[0].id)"
    Write-Host "Matching distribution certificate: $($certificates[0].id); existing build count (up to five): $($builds.Count)"
    foreach ($build in $builds) { Write-Host "Build $($build.attributes.version): $($build.attributes.processingState)" }
    if (-not $Configure) { Write-Host 'Read-only inspection complete. No credentials uploaded.'; exit 0 }
    # Never use the other app's profile, even though the team identity is shared.
    $bundleId = $bundles[0].id
    $certificateId = $certificates[0].id
    $profileName = 'GNAB CAM IRL App Store GitHub'
    $profiles = @( (Apple "profiles?filter[name]=$([Uri]::EscapeDataString($profileName))&include=bundleId,certificates&limit=100").data | Where-Object {
        $_.attributes.profileState -eq 'ACTIVE' -and $_.attributes.profileType -eq 'IOS_APP_STORE' -and
        $_.relationships.bundleId.data.id -eq $bundleId -and
        $certificateId -in @($_.relationships.certificates.data.id) -and
        [DateTimeOffset]$_.attributes.expirationDate -gt [DateTimeOffset]::UtcNow.AddDays(7)
    })
    if ($profiles.Count -gt 1) { throw 'Multiple matching GNAB profiles; select explicitly before configuring.' }
    if ($profiles.Count -eq 0) {
        $profile = (Apple 'profiles' 'POST' @{ data=@{ type='profiles'; attributes=@{ name=$profileName; profileType='IOS_APP_STORE' };
            relationships=@{ bundleId=@{ data=@{ type='bundleIds'; id=$bundleId } };
                certificates=@{ data=@(@{ type='certificates'; id=$certificateId }) } } } }).data
    } else { $profile = $profiles[0] }
    if (-not $profile.attributes.profileContent) { throw 'GNAB profile content is missing.' }
    $null = GitHub -arguments @('api','--method','PUT',"repos/$repo/environments/$environment",'--input','-') -inputText '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    $policies = (GitHub @('api',"repos/$repo/environments/$environment/deployment-branch-policies") | ConvertFrom-Json).branch_policies
    if (@($policies | Where-Object { $_.name -ne 'main' -or $_.type -ne 'branch' }).Count) {
        throw 'Unexpected signing-environment branch policy; secrets were not uploaded.'
    }
    if (@($policies).Count -eq 0) {
        $null = GitHub -arguments @('api','--method','POST',"repos/$repo/environments/$environment/deployment-branch-policies",'--input','-') -inputText '{"name":"main","type":"branch"}'
    }
    $values = @{
        APPLE_CERTIFICATE_P12_BASE64 = (Secret 'APPLE_CERTIFICATE_P12_BASE64')
        APPLE_CERTIFICATE_PASSWORD = (Secret 'APPLE_CERTIFICATE_PASSWORD')
        APPLE_TEAM_ID = (Secret 'APPLE_TEAM_ID')
        APPLE_PROVISIONING_PROFILE_BASE64 = $profile.attributes.profileContent
        APP_STORE_CONNECT_API_KEY_BASE64 = (Secret 'APP_STORE_CONNECT_API_KEY_BASE64')
        APP_STORE_CONNECT_API_KEY_ID = $keyId
        APP_STORE_CONNECT_ISSUER_ID = $issuer
    }
    foreach ($name in $values.Keys) {
        $null = GitHub @('secret','set',$name,'--repo',$repo,'--env',$environment) $values[$name]
        Write-Host "Encrypted environment secret configured: $name"
    }
    Write-Host "GNAB-only profile configured: $($profile.id). Signing is restricted to main."
} catch {
    # Do not expose HTTP bodies, tokens, secret values, or process arguments.
    Write-Error "Signing setup stopped: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
} finally { $script:token = $null }
