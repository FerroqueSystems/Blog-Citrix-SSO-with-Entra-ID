# Citrix-SSO-with-Entra-ID

**StoreFront Entra ID SSO Store Builder**

A PowerShell script that builds a new Citrix StoreFront store for Microsoft Entra ID single sign-on. The store sits alongside your existing DaaS/CVAD store. It sets up:

- Entra ID / OAuth settings
- CitrixAGBasic (Gateway) authentication
- The Delivery Controller farm
- Receiver for Web
- A roaming gateway

> [!NOTE]
> The existing store is never modified. Everything is created under a new set of virtual paths.

## Contents

- [What it creates](#what-it-creates)
- [Requirements](#requirements)
- [Parameters](#parameters)
- [Usage](#usage)
- [Re-running](#re-running)
- [Post-deployment steps](#post-deployment-steps)
- [Troubleshooting](#troubleshooting)
- [Disclaimer](#disclaimer)

## What it creates

| Component | Virtual path / name | Notes |
|---|---|---|
| Authentication service | `/Citrix/<NewStoreName>Auth` | CitrixAGBasic + ExplicitForms enabled, Entra ID settings applied, CitrixAGBasic credential validation = `Auto` |
| Store service | `/Citrix/<NewStoreName>` | Farm added, Entra ID SSO enabled in launch options, VDA logon data provider cleared |
| Receiver for Web | `/Citrix/<NewStoreName>Web` | Auth methods CitrixAGBasic, ExplicitForms; Workspace (modern) UI |
| Roaming gateway | `<GatewayName>` | Domain logon, session reliability on, STA URLs, callback URL, subnet IP; registered as the store's default gateway |

When it finishes, the script prints the gateway and store configuration so you can check them.

## Requirements

- Run on the StoreFront server, in an elevated **Windows PowerShell 5.1** session.
- A StoreFront version that supports `Set-STFEntraIdSettings` and the `-EntraIdSsoEnabled` launch option.
- An existing Entra ID app registration for the StoreFront/Gateway OAuth flow.
- Delivery Controllers reachable over the configured transport (HTTPS/443 by default).
- A NetScaler Gateway for remote access. You can create the gateway vServer after running the script (see [Post-deployment steps](#post-deployment-steps)).

> [!IMPORTANT]
> No client secret is stored in StoreFront. The OAuth client secret belongs in the NetScaler OAuth/OIDC action, not here.

## Parameters

> [!WARNING]
> Review every default before running. The placeholder values (`<...>`) must be replaced.

### Store

| Parameter | Default | Description |
|---|---|---|
| `NewStoreName` | `EntraSSO` | Store name. Also used to build the Auth and Web virtual paths. |

### Entra ID

| Parameter | Default | Description |
|---|---|---|
| `EntraTenantId` | `<TenantId>` | Entra tenant (directory) ID. |
| `CitrixIdentityCustomer` | `_` | Citrix identity customer value. |
| `GraphApiTimeoutSeconds` | `5` | Timeout for a single Graph API call. |
| `TotalGraphApiTimeoutSeconds` | `100` | Total timeout across Graph API calls. |
| `GraphApiUrl` | `https://graph.microsoft.com/v1.0` | Graph endpoint. Change for sovereign clouds. |
| `AuthorityUrl` | `https://login.microsoftonline.com/` | Entra authority. Change for sovereign clouds. |
| `AlwaysForceLogon` | `$true` | Forces an interactive Entra sign-in. |

### Farm / Delivery Controllers

| Parameter | Default | Description |
|---|---|---|
| `FarmName` | `<Farm Name>` | Farm name shown in StoreFront. |
| `Controllers` | `@('<DDC1 FQDN>','<DDC2 FQDN>')` | Delivery Controller FQDNs. |
| `FarmType` | `XenDesktop` | Farm type. |
| `Port` | `443` | XML service port. |
| `TransportType` | `HTTPS` | XML transport. |
| `SSLRelayPort` | `443` | SSL relay port. |
| `LoadBalance` | `$true` | Load balance across controllers. |

### Gateway

| Parameter | Default | Description |
|---|---|---|
| `GatewayName` | `gw-entra` | Roaming gateway display name. |
| `GatewayUrl` | `https://<gateway-fqdn>/` | Gateway URL. **Keep the trailing slash.** The callback URL is built as `<GatewayUrl>CitrixAuthService/AuthService.asmx`. |
| `StaUrls` | `https://<DDC>/scripts/ctxsta.dll` ×2 | Secure Ticket Authority URLs. These must match the STAs bound on the NetScaler vServer. |
| `GatewaySubnetIP` | `<Gateway VIP>` | Gateway VIP, used to tell gateways apart when several share one URL. |

These gateway settings are fixed. You can change them in the script if needed:

| Setting | Value |
|---|---|
| `LogonType` | `Domain` |
| `Version` | `Version10_0_69_4` |
| `SessionReliability` | `$true` |
| `RequestTicketTwoSTAs` | `$false` |
| `StasUseLoadBalancing` | `$false` |
| `StasBypassDuration` | 1 hour |

## Usage

Edit the parameter defaults in the script, or pass them on the command line:

```powershell
.\script.ps1 `
    -NewStoreName    'EntraSSO' `
    -EntraTenantId   '00000000-0000-0000-0000-000000000000' `
    -FarmName        'CVAD' `
    -Controllers     'ddc01.corp.example.com','ddc02.corp.example.com' `
    -GatewayName     'gw-entra' `
    -GatewayUrl      'https://entra.example.com/' `
    -StaUrls         'https://ddc01.corp.example.com/scripts/ctxsta.dll','https://ddc02.corp.example.com/scripts/ctxsta.dll' `
    -GatewaySubnetIP '10.0.10.50'
```

Add `-Verbose` to see more detail from the StoreFront cmdlets.

## Re-running

Each stage checks whether its component already exists and reuses it instead of creating a duplicate:

- The auth service, store, Receiver for Web and gateway are looked up by virtual path or name first.
- The farm is skipped if a farm with the same `FarmName` is already on the store.
- Gateway registration is skipped if the gateway is already bound to the store.

Settings (Entra ID, auth methods, launch options, UI experience) are applied again on every run. If you need a completely clean rebuild, remove the store first in the StoreFront console or with `Remove-STFStoreService`.

## Post-deployment steps

The script stops at the StoreFront boundary. Before you test, finish these steps:

1. **Entra ID: add the redirect URI.** Add the new Receiver for Web path to the app registration:

   ```text
   https://<storefront-base-url>/Citrix/<NewStoreName>Web
   ```

   Without it, sign-in fails with `AADSTS50011` (redirect URI mismatch).

2. **NetScaler: build the gateway vServer** for `<GatewayName>`. It needs:
   - a certificate
   - an OAuth/OIDC authentication policy (the client secret goes here)
   - STA bindings that match `StaUrls`
   - session policies pointing at the new store (`/Citrix/<NewStoreName>`)

3. **DNS:** create an A record for the gateway FQDN pointing to the gateway VIP.

4. **Multi-server StoreFront groups:** push the changes to the other servers in the group:

   ```powershell
   Publish-STFServerGroupConfiguration
   ```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `AADSTS50011` during sign-in | The `/Citrix/<NewStoreName>Web` redirect URI is missing from the Entra app registration. |
| Auth service / Store / Web Receiver not found after create | The StoreFront cmdlet failed silently. Re-run with `-Verbose` and check the **Citrix Delivery Services** event log. |
| Gateway sign-in works but app enumeration fails | `GatewayUrl` has no trailing slash (so the callback URL is malformed), or the callback FQDN doesn't resolve from StoreFront. |
| Launch fails with an STA error | `StaUrls` in StoreFront don't match the STA servers bound on the NetScaler vServer. |
| `Set-STFEntraIdSettings` not recognized | The installed StoreFront version doesn't support Entra ID SSO. Upgrade StoreFront. |

## Disclaimer

Provided as-is. Test in a non-production environment first, and review every parameter against your own environment before running.
