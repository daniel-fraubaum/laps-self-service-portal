# Architecture

## Overview

The LAPS Self-Service Portal is a two-tier web application hosted entirely in Azure:

| Tier | Technology | Azure Service |
|------|------------|---------------|
| Frontend | Static HTML + MSAL.js + Vanilla JS | Azure Static Web App |
| Backend | Node.js 24 Azure Functions v4 | Azure Function App (Dedicated Linux B1) |
| Identity | Entra ID | Built-in Easy Auth |
| Graph access | Managed Identity | System-assigned to Function App |
| Audit storage | Azure Table Storage | Included in Function App storage account |
| Monitoring | Application Insights | Linked to Log Analytics Workspace |

---

## Authentication Flow

```
Browser                    Entra ID                 Function App          Microsoft Graph
  │                            │                          │                      │
  │── Open portal ────────────▶│                          │                      │
  │                            │                          │                      │
  │◀── Redirect to login ──────│                          │                      │
  │                            │                          │                      │
  │── Credentials ────────────▶│                          │                      │
  │                            │                          │                      │
  │◀── ID token + access token─│                          │                      │
  │                            │                          │                      │
  │── GET /api/my-devices ───────────────────────────────▶│                      │
  │   Authorization: Bearer <token>                        │                      │
  │                            │                          │                      │
  │                            │◀── Easy Auth validates ──│                      │
  │                            │    token, injects header │                      │
  │                            │                          │                      │
  │                            │                          │── GET /users/{oid}/registeredDevices ────▶│
  │                            │                          │   (Managed Identity token)                │
  │                            │                          │◀── Device list (Windows + macOS only) ────│
  │                            │                          │                      │
  │◀── 200 { devices: [...] } ─────────────────────────────│                      │
  │                            │                          │                      │
  │── POST /api/laps-password ───────────────────────────▶│                      │
  │   { deviceId, justification }                         │                      │
  │                            │                          │                      │
  │                            │                          │── verify ownership ──▶│
  │                            │                          │── GET /beta/deviceLocalCredentials/{id} ─▶│
  │                            │                          │◀── password ──────────────────────────────│
  │                            │                          │                      │
  │                            │                          │── write audit log ──▶ Table Storage
  │                            │                          │                      │
  │◀── 200 { password, ... } ──────────────────────────────│                      │
```

---

## Security Model

### Token Validation

The Function App's built-in authentication (Easy Auth) validates the Bearer token on every
request before the function code runs. Unauthenticated requests receive HTTP 401. No manual
JWT validation code is required.

### "Only My Device" Rule

Device ownership is enforced **in the backend** on every request, not just in the UI:

1. The backend reads the user's Object ID (OID) from the Easy Auth header (`X-MS-CLIENT-PRINCIPAL`)
2. It queries Graph for all registered devices of that user (`GET /users/{oid}/registeredDevices`)
3. The requested `deviceId` must appear in that list — otherwise HTTP 403 is returned

The frontend device list is a UX convenience only; it does not constitute an authorization boundary.

### Managed Identity

The Function App uses a system-assigned Managed Identity to authenticate against Microsoft Graph.
No client secrets, certificates, or connection strings are stored for Graph access.

Token acquisition flow:

```
Function App
  └── @azure/identity DefaultAzureCredential
        └── ManagedIdentityCredential
              └── Azure IMDS endpoint (http://169.254.169.254, internal)
                    └── Entra ID token endpoint
                          └── access_token for https://graph.microsoft.com
```

Required application permissions on the Managed Identity:

| Permission | Purpose |
|-----------|---------|
| `Device.Read.All` | Read device properties |
| `DeviceLocalCredential.Read.All` | Read LAPS passwords |
| `Directory.Read.All` | Required to navigate `/users/{id}/registeredDevices` |

### Audit Trail

Every invocation of `POST /api/laps-password` writes a record to Azure Table Storage before
returning a response, regardless of outcome (success, denial, or error).

| Field | Value |
|-------|-------|
| PartitionKey | `YYYY-MM-DD` (UTC date) |
| RowKey | UUID v4 |
| UserId | Entra Object ID |
| UserPrincipalName | UPN |
| DeviceId | Entra Device Object ID |
| DeviceName | Display name |
| Justification | User-provided reason |
| Action | `SUCCESS` / `DENIED` / `ERROR` |
| DenialReason | e.g. `DEVICE_NOT_OWNED`, `NO_LAPS_CREDENTIAL` |
| ClientIp | Source IP address |
| UserAgent | Browser user agent |

---

## Resource Topology

```
Subscription
└── Resource Group: rg-<projectName>
    ├── Storage Account: <projectName-prefix><uniquehash>
    │   ├── Blob container: func-deployments  (WEBSITE_RUN_FROM_PACKAGE zip)
    │   ├── Blob containers: azure-webjobs-*  (Functions runtime internal)
    │   └── Table: LapsAuditLog
    │
    ├── App Service Plan: <projectName>-plan  (Linux B1 Dedicated)
    │
    ├── Function App: <projectName>-func
    │   ├── System-assigned Managed Identity
    │   └── Graph permissions: Device.Read.All, DeviceLocalCredential.Read.All, Directory.Read.All
    │   ├── Easy Auth → Entra ID (validates JWT before code runs)
    │   ├── WEBSITE_RUN_FROM_PACKAGE → Blob Storage SAS URL
    │   └── App Settings (TENANT_ID, AUTH_CLIENT_ID, AUDIT_*, GRAPH_API_ENDPOINT, …)
    │
    ├── Static Web App: <projectName>-swa  (Standard tier, westeurope by default)
    │   └── Custom Domain (optional)
    │
    ├── Log Analytics Workspace: <projectName>-law
    │
    └── Application Insights: <projectName>-ai
```

> **Note:** The Static Web App must be deployed to one of the five supported regions:
> `westus2`, `centralus`, `eastus2`, `westeurope`, `eastasia`. All other resources
> can use any Azure region (controlled by the `--location` parameter).

---

## Data Flow – LAPS Password Retrieval

```
POST /api/laps-password
{ "deviceId": "...", "justification": "..." }

Step 1 – Easy Auth validates Bearer token (audience: api://<clientId>)
         → extracts X-MS-CLIENT-PRINCIPAL header (base64-encoded claims JSON)

Step 2 – getCallerIdentity() reads OID and UPN from the header

Step 3 – Input validation
         → deviceId present?
         → justification >= JUSTIFICATION_MIN_LENGTH characters?

Step 4 – findOwnedDevice(deviceId, oid)
         → Graph: GET /v1.0/users/{oid}/registeredDevices
         → Is deviceId in the result set?
         → No → write DENIED audit log → return HTTP 403

Step 5 – getLapsPassword(deviceId)
         → Graph: GET /beta/deviceLocalCredentials/{deviceId}?$select=credentials,deviceName
         → No credential → write DENIED audit log → return HTTP 404

Step 6 – writeAuditLog(action: 'SUCCESS')

Step 7 – Return { deviceName, password, expiresAt, auditId }
```

---

## Backend Deployment

The Function App is deployed using the `WEBSITE_RUN_FROM_PACKAGE` pattern:

1. Backend source is zipped locally
2. Zip is uploaded to the project's Storage Account (`func-deployments` container)
3. A SAS URL (2-year expiry) is generated for the blob
4. The SAS URL is written to the `WEBSITE_RUN_FROM_PACKAGE` app setting via ARM REST API
5. Azure Functions runtime mounts the zip read-only and runs from it

This avoids the Kudu SCM endpoint (which is unreliable for Linux Dedicated plans) and
gives deterministic, fast deployments.

---

## Scalability & Cost

The portal runs on a **Dedicated B1** App Service Plan to avoid cold-start delays that
are common with the Consumption plan. Expected cost breakdown for a typical 500-user organization:

| Resource | Estimated monthly cost |
|----------|----------------------|
| App Service Plan (Linux B1) | ~€12 |
| Static Web App (Standard) | ~€9 |
| Storage Account | < €1 |
| Application Insights | < €2 (first 5 GB/month free) |
| Log Analytics Workspace | < €1 |
| **Total** | **~€25/month** |

> To reduce costs, the App Service Plan can be changed to `B1` → `Y1` (Consumption) in
> `infra/modules/appServicePlan.bicep`. This trades cold-start latency (~3–5 s on first
> request after idle) for near-zero compute cost.
