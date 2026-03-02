# Configuration Reference

This document describes every configuration value in the LAPS Self-Service Portal,
where each value comes from, and how it flows from Azure into the application.

---

## Quick-start checklist

After running the deployment script, the script prints all values you need.
For manual deployments, collect the following:

**From the App Registration (created by the deploy script via `az ad app`):**

```bash
# Client ID — also needed as a Bicep input parameter
CLIENT_ID=$(az ad app list --display-name "laps-prod-laps-portal" \
  --query '[0].appId' -o tsv)
```

**From the Bicep deployment outputs:**

```bash
az deployment sub show \
  --name laps-laps-prod \
  --query 'properties.outputs' \
  -o table
```

| Output name                  | Used in                            |
|------------------------------|------------------------------------|
| `backendUrl`                 | `authConfig.js` → `apiBaseUrl`     |
| `frontendUrl`                | App Registration redirect URI      |
| `managedIdentityPrincipalId` | Graph permission assignment        |

> **Note:** The App Registration `clientId` is **not** a Bicep output — it is an input.
> It was captured when the App Registration was created in Step 1 of the deploy script.

---

## Frontend configuration (`frontend/authConfig.js`)

> **One file to edit per deployment.** Copy `authConfig.example.js` → `authConfig.js`
> and fill in the values below. `authConfig.js` is gitignored and must never be committed.

### How the config is loaded

`index.html` loads `authConfig.js` at startup (before MSAL):

```html
<script src="authConfig.js" onerror="void 0"></script>
```

The script sets `window.LAPS_CONFIG`. The embedded app code reads:

```javascript
const C = Object.assign({
  msalClientId: '', tenantId: '', apiBaseUrl: '', apiScope: '',
  passwordTimeout: 60, justificationMinLength: 10,
}, window.LAPS_CONFIG ?? {});
```

If `authConfig.js` is missing (e.g. first local run), the page falls back to empty strings
and MSAL will fail with a descriptive error — no silent misconfiguration.

### Required values

| Key | Description | Source |
|-----|-------------|--------|
| `msalClientId` | App Registration (client) ID — used by MSAL to identify the application | Azure Portal → Entra ID → App registrations → *your-app* → **Application (client) ID** |
| `tenantId` | Entra ID Tenant ID — used to build the MSAL authority URL | Azure Portal → Entra ID → Overview → **Tenant ID** |
| `apiBaseUrl` | Base URL of the backend Function App, **no trailing slash** | Bicep output `backendUrl` |
| `apiScope` | OAuth 2.0 scope used to acquire the backend API token | `api://{msalClientId}/access_as_user` |

### Optional values (defaults match backend defaults)

| Key | Default | Description |
|-----|---------|-------------|
| `passwordTimeout` | `60` | Seconds the LAPS password stays visible before being hidden |
| `justificationMinLength` | `10` | Minimum characters required in the justification text field |

> **Note:** If you change `passwordTimeout` or `justificationMinLength` here,
> update the matching backend app settings (`PASSWORD_DISPLAY_SECONDS`,
> `JUSTIFICATION_MIN_LENGTH`) on the Function App to keep them in sync.

### Example `authConfig.js`

```javascript
window.LAPS_CONFIG = {
  msalClientId: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  tenantId:     'f9e8d7c6-b5a4-3210-fedc-ba9876543210',
  apiBaseUrl:   'https://laps-prod-func.azurewebsites.net',
  apiScope:     'api://a1b2c3d4-e5f6-7890-abcd-ef1234567890/access_as_user',
  passwordTimeout:        60,
  justificationMinLength: 10,
};
```

---

## Backend configuration (Azure Function App app settings)

All backend values are injected as **app settings** by the Bicep deployment.
In local development they come from `backend/local.settings.json` (gitignored).

### App settings reference

| App setting | Source | Description |
|-------------|--------|-------------|
| `AzureWebJobsStorage` | `storage.outputs.storageConnectionString` | Azure Functions runtime storage |
| `FUNCTIONS_EXTENSION_VERSION` | `~4` (fixed) | Azure Functions runtime version |
| `FUNCTIONS_WORKER_RUNTIME` | `node` (fixed) | Node.js worker runtime |
| `WEBSITE_NODE_DEFAULT_VERSION` | `~24` (fixed) | Node.js version |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | `monitoring.outputs.connectionString` | Application Insights telemetry |
| `ApplicationInsightsAgent_EXTENSION_VERSION` | `~3` (fixed) | AI agent version |
| `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` | `authClientSecret` param (Key Vault ref) | Easy Auth client secret |
| `TENANT_ID` | `subscription().tenantId` | Entra ID Tenant ID for local JWT validation |
| `AUTH_CLIENT_ID` | `authClientId` Bicep param | App Registration client ID for JWT audience check |
| `AUDIT_STORAGE_CONNECTION_STRING` | `storage.outputs.storageConnectionString` | Table Storage for audit log |
| `AUDIT_TABLE_NAME` | `storage.outputs.auditTableName` | Name of the audit log table |
| `GRAPH_API_ENDPOINT` | `https://graph.microsoft.com` (fixed) | Microsoft Graph base URL |
| `JUSTIFICATION_MIN_LENGTH` | `10` (default) | Minimum justification length (characters) |
| `PASSWORD_DISPLAY_SECONDS` | `60` (default) | Seconds to display the password |

### How the backend reads configuration

```javascript
// lib/auth.js
const TENANT_ID = process.env.TENANT_ID;
const CLIENT_ID = process.env.AUTH_CLIENT_ID;

// lib/graph.js
const GRAPH_ENDPOINT = process.env.GRAPH_API_ENDPOINT ?? 'https://graph.microsoft.com';

// lib/audit.js
const CONNECTION_STRING = process.env.AUDIT_STORAGE_CONNECTION_STRING;
const TABLE_NAME        = process.env.AUDIT_TABLE_NAME ?? 'LapsAuditLog';

// functions/lapsPassword.js
const MIN_JUSTIFICATION = parseInt(process.env.JUSTIFICATION_MIN_LENGTH ?? '10', 10);
```

### Local development (`backend/local.settings.json`)

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "TENANT_ID": "<your-tenant-id>",
    "AUTH_CLIENT_ID": "<your-client-id>",
    "AUDIT_STORAGE_CONNECTION_STRING": "UseDevelopmentStorage=true",
    "AUDIT_TABLE_NAME": "LapsAuditLog",
    "GRAPH_API_ENDPOINT": "https://graph.microsoft.com",
    "JUSTIFICATION_MIN_LENGTH": "10",
    "PASSWORD_DISPLAY_SECONDS": "60"
  }
}
```

> **Note:** `APPLICATIONINSIGHTS_CONNECTION_STRING` and
> `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` are intentionally omitted from
> local settings — Application Insights telemetry is disabled locally,
> and Easy Auth is not active when running with `func start`.

---

## Bicep parameters (`infra/main.parameters.json`)

> Copy `infra/main.parameters.example.json` → `infra/main.parameters.json` (gitignored).

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `projectName` | ✅ | — | Prefix for all Azure resource names (e.g. `laps-prod`) |
| `location` | ❌ | `germanywestcentral` | Azure region for all resources except the Static Web App |
| `swaLocation` | ❌ | `westeurope` | Azure region for the Static Web App (allowed: `westus2`, `centralus`, `eastus2`, `westeurope`, `eastasia`) |
| `resourceGroupName` | ❌ | `rg-{projectName}` | Resource group name |
| `customDomain` | ❌ | `""` | Custom domain FQDN for the Static Web App (leave empty to skip) |
| `authClientId` | ✅ | — | App Registration (client) ID — created by the deploy script before Bicep runs |
| `authClientSecret` | ✅ | — | Easy Auth client secret — generated by the deploy script before Bicep runs |

> **Single-pass deployment:** Unlike some architectures, there is **no two-step Bicep process**.
> The deploy script creates the App Registration and generates the client secret via `az ad app`
> commands **before** Bicep runs, so all parameters are available in a single deployment pass.

---

## Managed Identity Graph permissions

The Function App's system-assigned Managed Identity requires three Microsoft Graph
**application permissions** that cannot be assigned via Bicep. The deploy script handles this
automatically. For manual assignment:

```bash
MI_ID="<managedIdentityPrincipalId from Bicep output>"
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)

for ROLE in "Device.Read.All" "DeviceLocalCredential.Read.All" "Directory.Read.All"; do
  ROLE_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
    --query "appRoles[?value=='$ROLE'].id | [0]" -o tsv)

  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"${MI_ID}\",\"resourceId\":\"${GRAPH_SP_ID}\",\"appRoleId\":\"${ROLE_ID}\"}"
done
```

---

## Access control (restricting who can use the portal)

By default, **any user in your Entra ID tenant** can authenticate against the App Registration.
To restrict access to specific users or groups, enable **assignment enforcement** on the
corresponding Enterprise Application.

### How it works

The assignment check is enforced by Entra ID at the token-issuance level:
- Assigned users → sign-in succeeds, token issued, portal loads normally
- Unassigned users → Entra ID rejects the login with `AADSTS50105` **before** the app
  or backend sees anything

This means no code changes or backend logic are needed — the IdP handles it entirely.

### Setup

1. Go to **Microsoft Entra ID** → **Enterprise Applications**
2. Search for your app by the name you gave it during deployment (same as the App Registration display name, e.g. `laps-prod-laps-portal`)
3. Open **Properties** → set **"Assignment required?"** to **Yes** → **Save**
4. Open **Users and groups** → **Add assignment** → select the users or groups that should have access

> **Recommendation:** Assign a security group (e.g. `SG-LAPS-Self-Service`) rather than
> individual users. Group membership can then be managed independently of the app.

### Via CLI

```bash
# Enable assignment requirement
OBJECT_ID=$(az ad sp list --display-name "laps-prod-laps-portal" --query '[0].id' -o tsv)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body '{"appRoleAssignmentRequired": true}'

# Assign a group
GROUP_ID=$(az ad group show --group "SG-LAPS-Self-Service" --query id -o tsv)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${OBJECT_ID}/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"${GROUP_ID}\",\"resourceId\":\"${OBJECT_ID}\",\"appRoleId\":\"00000000-0000-0000-0000-000000000000\"}"
```

> The `appRoleId` `00000000-0000-0000-0000-000000000000` is the default role
> (used when no custom app roles are defined).

---

## Configuration flow diagram

```
Deploy script (az ad app / az CLI)
    │
    ├─► App Registration created
    │       └─► clientId ──────────────────────────► authConfig.js: msalClientId
    │                                                 authConfig.js: apiScope
    │                     ──────────────────────────► Bicep param:   authClientId
    │                                                 Function App:  AUTH_CLIENT_ID
    │
    └─► Client secret generated
            └─► secret ────────────────────────────► Bicep param:   authClientSecret
                                                      Function App:  MICROSOFT_PROVIDER_AUTHENTICATION_SECRET

Bicep deployment
    │
    ├─► Function App created
    │       └─► defaultHostName ──────────────────► authConfig.js: apiBaseUrl
    │
    ├─► Storage Account created
    │       └─► connectionString ─────────────────► Function App: AzureWebJobsStorage
    │                                                               AUDIT_STORAGE_CONNECTION_STRING
    │
    ├─► Application Insights created
    │       └─► connectionString ─────────────────► Function App: APPLICATIONINSIGHTS_CONNECTION_STRING
    │
    └─► subscription().tenantId ───────────────────► Function App: TENANT_ID
                                                      authConfig.js: tenantId
