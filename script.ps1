<#
.SYNOPSIS
    Rebuilds a StoreFront store for Entra ID SSO alongside an existing DaaS store,
    carrying over Entra ID / OAuth and CitrixAGBasic (Gateway) authentication config.

.DESCRIPTION
    Run on the StoreFront server. Creates a NEW store; does not modify the existing one.
    Review every parameter default below before running - especially TenantId, the farm
    controllers, and the gateway settings.

    IMPORTANT (OAuth redirect): the Entra app registration must include a redirect URI for
    the new virtual path (e.g. /Citrix/<NewStoreName>Web) or the OAuth round-trip fails with
    AADSTS50011 redirect mismatch. Add it in Entra before testing.

.NOTES
    PS 5.1. Fails if the store already exists (remove it first to re-run).
    Fill in the variables requires denoted by <var>
#>

[CmdletBinding()]
param(
    [string]   $NewStoreName             = 'EntraSSO',

    # Entra ID settings (StoreFront stores no client secret - that lives on the NetScaler
    # OAuth side, not here)
    [string]   $EntraTenantId            = '<TenantId>',
    [string]   $CitrixIdentityCustomer   = '_',
    [int]      $GraphApiTimeoutSeconds       = 5,
    [int]      $TotalGraphApiTimeoutSeconds  = 100,
    [string]   $GraphApiUrl              = 'https://graph.microsoft.com/v1.0',
    [string]   $AuthorityUrl             = 'https://login.microsoftonline.com/',
    [bool]     $AlwaysForceLogon         = $true,

    # Farm / Delivery Controllers
    [string]   $FarmName                 = '<Farm Name>',
    [string[]] $Controllers              = @('<DDC1 FQDN>', '<DDC2 FQDN>'),
    [string]   $FarmType                 = 'XenDesktop',
    [int]      $Port                     = 443,
    [string]   $TransportType            = 'HTTPS',
    [int]      $SSLRelayPort             = 443,
    [bool]     $LoadBalance              = $true,

    # Gateway (roaming gateway registered to the new store)
    [string]   $GatewayName              = 'gw-entra',
    [string]   $GatewayUrl               = 'https://<gateway-fqdn>/',
    [string[]] $StaUrls                  = @('https://<DDC1 FQDN>/scripts/ctxsta.dll', 'https://<DDC2 FQDN>/scripts/ctxsta.dll'),
    [string]   $GatewaySubnetIP          = '<Gateway VIP>'
)

$StoreVP = "/Citrix/$NewStoreName"
$AuthVP  = "/Citrix/${NewStoreName}Auth"
$WebVP   = "/Citrix/${NewStoreName}Web"

& "$env:ProgramFiles\Citrix\Receiver StoreFront\Scripts\ImportModules.ps1"

# ============================ AUTH SERVICE ============================
Write-Host "Creating authentication service $AuthVP ..." -ForegroundColor Cyan
$authService = Get-STFAuthenticationService -VirtualPath $AuthVP -ErrorAction SilentlyContinue
if (-not $authService) {
    Add-STFAuthenticationService -VirtualPath $AuthVP | Out-Null
    $authService = Get-STFAuthenticationService -VirtualPath $AuthVP -ErrorAction SilentlyContinue
}
if (-not $authService) { throw "Auth service not found after create at $AuthVP" }

foreach ($p in @('CitrixAGBasic', 'ExplicitForms')) {
    try { Enable-STFAuthenticationServiceProtocol -Name $p -AuthenticationService $authService }
    catch { Write-Host "[WARN] protocol $p : $($_.Exception.Message)" -ForegroundColor Yellow }
}

Write-Host "Applying Entra ID settings ..." -ForegroundColor Cyan
Set-STFEntraIdSettings -AuthenticationService $authService `
    -TenantId $EntraTenantId `
    -CitrixIdentityCustomer $CitrixIdentityCustomer `
    -GraphApiTimeoutSeconds $GraphApiTimeoutSeconds `
    -TotalGraphApiTimeoutSeconds $TotalGraphApiTimeoutSeconds `
    -GraphApiUrl $GraphApiUrl `
    -AuthorityUrl $AuthorityUrl `
    -AlwaysForceLogon $AlwaysForceLogon `
    -Enabled $true

Write-Host "Applying CitrixAGBasic options ..." -ForegroundColor Cyan
Set-STFCitrixAGBasicOptions -AuthenticationService $authService -CredentialValidationMode Auto

# ============================ STORE SERVICE ============================
Write-Host "Creating store service $StoreVP ..." -ForegroundColor Cyan
$store = Get-STFStoreService -VirtualPath $StoreVP -ErrorAction SilentlyContinue
if (-not $store) {
    Add-STFStoreService -FriendlyName $NewStoreName -VirtualPath $StoreVP -AuthenticationService $authService | Out-Null
    $store = Get-STFStoreService -VirtualPath $StoreVP -ErrorAction SilentlyContinue
}
if (-not $store) { throw "Store not found after create at $StoreVP" }

$existingFarm = (Get-STFStoreFarm -StoreService $store -ErrorAction SilentlyContinue) | Where-Object FarmName -eq $FarmName
if (-not $existingFarm) {
    Add-STFStoreFarm -StoreService $store -FarmName $FarmName -FarmType $FarmType `
        -Servers $Controllers -Port $Port -TransportType $TransportType `
        -SSLRelayPort $SSLRelayPort -LoadBalance:$LoadBalance
} else {
    Write-Host "Farm $FarmName already present on store - skipping" -ForegroundColor Yellow
}

# Entra SSO toggle
Set-STFStoreLaunchOptions -StoreService $store -VdaLogonDataProvider '' -EntraIdSsoEnabled $true

# ============================ RECEIVER FOR WEB ============================
Write-Host "Creating Receiver for Web $WebVP ..." -ForegroundColor Cyan
$wr = Get-STFWebReceiverService -StoreService $store -ErrorAction SilentlyContinue
if (-not $wr) {
    Add-STFWebReceiverService -StoreService $store -VirtualPath $WebVP | Out-Null
    $wr = Get-STFWebReceiverService -StoreService $store -ErrorAction SilentlyContinue
}
if (-not $wr) { throw "Web Receiver not found after create at $WebVP" }

Set-STFWebReceiverAuthenticationMethods -WebReceiverService $wr -AuthenticationMethods 'CitrixAGBasic', 'ExplicitForms'

Write-Host "Setting UI experience to Modern (Workspace) ..." -ForegroundColor Cyan
Set-STFWebReceiverService -WebReceiverService $wr -WebUIExperience Workspace

# ============================ GATEWAY ============================
Write-Host "Creating/associating gateway $GatewayName ..." -ForegroundColor Cyan
$gw = Get-STFRoamingGateway | Where-Object { $_.Name -eq $GatewayName }
if (-not $gw) {
    $gwParams = @{
        Name                      = $GatewayName
        LogonType                 = 'Domain'
        Version                   = 'Version10_0_69_4'
        GatewayUrl                = $GatewayUrl
        CallbackUrl               = "$GatewayUrl" + 'CitrixAuthService/AuthService.asmx'
        SecureTicketAuthorityUrls = $StaUrls
        SessionReliability        = $true
        RequestTicketTwoSTAs      = $false
        StasUseLoadBalancing      = $false
        StasBypassDuration        = (New-TimeSpan -Hours 1)
        SubnetIPAddress           = $GatewaySubnetIP
    }
    Add-STFRoamingGateway @gwParams | Out-Null
    $gw = Get-STFRoamingGateway | Where-Object { $_.Name -eq $GatewayName }
}
if (-not $gw) { throw "Gateway $GatewayName not found after create - aborting before register" }
Write-Host ("Gateway ready: {0} ({1})" -f $gw.Name, $gw.Location) -ForegroundColor Green

$alreadyRegistered = (Get-STFStoreService -VirtualPath $StoreVP).Gateways | Where-Object { $_.Name -eq $GatewayName }
if (-not $alreadyRegistered) {
    Register-STFStoreGateway -Gateway $gw -StoreService $store -DefaultGateway
    Write-Host "Gateway $GatewayName registered to $StoreVP (remote access enabled)" -ForegroundColor Green
} else {
    Write-Host "Gateway $GatewayName already registered to $StoreVP - skipping" -ForegroundColor Yellow
}

# ============================ VERIFY ============================
Write-Host "`n--- Verification ---" -ForegroundColor Cyan
Get-STFRoamingGateway | Where-Object Name -eq $GatewayName |
    Format-List Name, Version, Logon, Location, CallbackUrl, SecureTicketAuthorityUrls, SessionReliability
Get-STFStoreService -VirtualPath $StoreVP | Select-Object -ExpandProperty Gateways

Write-Host "`n[PASS] Store '$NewStoreName' created with remote access via $GatewayName." -ForegroundColor Green
Write-Host "REMAINING (outside StoreFront):" -ForegroundColor Yellow
Write-Host "  1. NetScaler: create the $GatewayName Gateway vserver (cert, OAuth/OIDC policy, STA bindings)" -ForegroundColor Yellow
Write-Host "  2. DNS: A record for the gateway FQDN -> gateway VIP" -ForegroundColor Yellow
Write-Host "  3. Entra: add https://<sf-base>/Citrix/${NewStoreName}Web redirect URI to the app registration" -ForegroundColor Yellow
