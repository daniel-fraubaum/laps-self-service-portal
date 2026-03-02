# 📦 Deployment Guide

This guide covers everything from first-time setup to ongoing maintenance of
the LAPS Self-Service Portal. For a quick overview, see the [README](../README.md).

---

## ✅ Prerequisites

Install the following tools before running the deployment scripts.

| Tool | Min. Version | Install |
|------|-------------|---------|
| Azure CLI | 2.50 | [docs.microsoft.com](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Static Web Apps CLI | latest | `npm install -g @azure/static-web-apps-cli` |
| Node.js | 24 LTS | [nodejs.org](https://nodejs.org) |
| PowerShell | 7+ | [aka.ms/powershell](https://aka.ms/powershell) *(PS script only)* |

### 🔐 Required Azure permissions

The identity running the deployment needs:

| Scope | Role / Permission |
|-------|-------------------|
| Azure subscription | **Contributor** (create resource group and all resources) |
| Entra ID tenant | **Application Administrator** or **Global Administrator** (create App Registration, grant consent) |
| Entra ID tenant | **Privileged Role Administrator** (assign Graph permissions to Managed Identity) |

> **Tip:** A Global Administrator has all of the above by default.

---

## 🚀 Automated deployment (recommended)

The deployment scripts handle the entire process in a single run.

### 🍎 Bash (Linux / macOS / WSL)

```bash
# Clone the repository and enter the project root
cd laps-self-service-portal

# Make the script executable
chmod +x infra/deploy.sh

# First deployment
./infra/deploy.sh --project laps-prod

# With custom options
./infra/deploy.sh \
  --project   laps-prod \
  --location  germanywestcentral \
  --domain    laps.company.com
```

### 🪟 PowerShell (Windows)

```powershell
# From the project root
.\infra\deploy.ps1 -Project laps-prod

# With custom options
.\infra\deploy.ps1 `
  -Project      laps-prod `
  -Location     germanywestcentral `
  -CustomDomain laps.company.com
```

### ⚙️ What the script does

The script executes these steps in order:

| Step | Action |
|------|--------|
| 1 | Check prerequisites (`az`, `swa`, `node`, `npm`) |
| 2 | Verify Azure CLI login (`az login` if needed), confirm subscription |
| 3 | Create Entra ID App Registration via `az ad app` (or reuse existing), set identifier URI `api://<clientId>`, generate client secret |
| 4 | Deploy Bicep infrastructure (single pass, all parameters known upfront) |
| 5 | Assign `Device.Read.All`, `DeviceLocalCredential.Read.All`, `Directory.Read.All` to the Function App's Managed Identity |
| 6 | Deploy backend via zip-to-blob + `WEBSITE_RUN_FROM_PACKAGE` |
| 7 | Generate `frontend/authConfig.js` from deployment outputs |
| 8 | Deploy frontend (`swa deploy`) |
| 9 | Add Static Web App URL to App Registration redirect URIs |
| 10 | Grant admin consent for `User.Read` |

At the end, the script prints the portal URL and the generated client secret.
**Save the client secret** — it cannot be retrieved again after the script exits.

---

## 🔧 Manual deployment (step by step)

Use this if you prefer full control or need to deploy individual components.

> **Note:** The automated scripts (`deploy.ps1` / `deploy.sh`) perform all of
> these steps in sequence. Use the manual steps only for troubleshooting,
> partial deploys, or audit purposes.

### 1️⃣ Step 1 – Create App Registration

The App Registration must exist **before** Bicep runs, because its `clientId`
is a required Bicep parameter.

```bash
az login
TENANT_ID=$(az account show --query tenantId -o tsv)
APP_NAME="laps-prod-laps-portal"

# Create (or look up existing) App Registration
CLIENT_ID=$(az ad app list --display-name "$APP_NAME" \
  --query '[0].appId' -o tsv 2>/dev/null)

if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID=$(az ad app create \
    --display-name "$APP_NAME" \
    --sign-in-audience AzureADMyOrg \
    --query appId -o tsv)
  az ad sp create --id "$CLIENT_ID" --output none
fi

echo "Client ID: $CLIENT_ID"

# Set identifier URI (required for Easy Auth audience validation)
az ad app update --id "$CLIENT_ID" \
  --identifier-uris "api://$CLIENT_ID"

# Generate client secret (save this – it cannot be retrieved again)
CLIENT_SECRET=$(az ad app credential reset \
  --id "$CLIENT_ID" \
  --append \
  --years 2 \
  --display-name "LAPS Portal Easy Auth – $(date +%Y-%m-%d)" \
  --query password \
  -o tsv)

echo "Client Secret: $CLIENT_SECRET"
# ⚠ Save the client secret – you will need it for re-deployments
```

### 2️⃣ Step 2 – Deploy Bicep infrastructure

All parameters are now known, so Bicep runs in a single pass.

```bash
az deployment sub create \
  --location germanywestcentral \
  --template-file infra/main.bicep \
  --parameters \
    projectName=laps-prod \
    location=germanywestcentral \
    authClientId="$CLIENT_ID" \
    authClientSecret="$CLIENT_SECRET" \
  --name laps-laps-prod
```

Read the outputs (needed in subsequent steps):

```bash
DEPLOY_NAME="laps-laps-prod"

MI_PRINCIPAL_ID=$(az deployment sub show --name "$DEPLOY_NAME" \
  --query properties.outputs.managedIdentityPrincipalId.value -o tsv)
BACKEND_URL=$(az deployment sub show --name "$DEPLOY_NAME" \
  --query properties.outputs.backendUrl.value -o tsv)
FRONTEND_URL=$(az deployment sub show --name "$DEPLOY_NAME" \
  --query properties.outputs.frontendUrl.value -o tsv)
DEPLOYMENT_TOKEN=$(az staticwebapp secrets list \
  --name laps-prod-swa \
  --resource-group rg-laps-prod \
  --query 'properties.apiKey' -o tsv)

echo "Backend:  $BACKEND_URL"
echo "Frontend: $FRONTEND_URL"
```

### 3️⃣ Step 3 – Assign Graph permissions to the Managed Identity

The Function App uses its Managed Identity to call Microsoft Graph. Three
application permissions must be assigned (Bicep cannot do this directly).

```bash
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)

# Helper function: assign a Graph app role
assign_role() {
  local ROLE_NAME=$1
  local ROLE_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
    --query "appRoles[?value=='${ROLE_NAME}'].id | [0]" -o tsv)

  az rest --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_PRINCIPAL_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${MI_PRINCIPAL_ID}\",
      \"resourceId\":  \"${GRAPH_SP_ID}\",
      \"appRoleId\":   \"${ROLE_ID}\"
    }"
}

assign_role "Device.Read.All"
assign_role "DeviceLocalCredential.Read.All"
assign_role "Directory.Read.All"
```

### 4️⃣ Step 4 – Deploy the backend

The backend is deployed via a zip package uploaded to Azure Blob Storage
(`WEBSITE_RUN_FROM_PACKAGE`). Azure Functions Core Tools (`func`) are **not** used.

```bash
# Create a production build
cd backend
npm ci --omit=dev
cd ..

# Zip and upload
zip -r /tmp/laps-backend.zip backend/ --exclude "backend/node_modules/.cache/*"

# Upload to the storage account and deploy
SUB_ID=$(az account show --query id -o tsv)
RG="rg-laps-prod"
FUNC_NAME="laps-prod-func"
STORAGE=$(az storage account list --resource-group $RG --query '[0].name' -o tsv)
CONNSTR=$(az storage account show-connection-string --name $STORAGE --resource-group $RG --query connectionString -o tsv)

az storage blob upload \
  --connection-string "$CONNSTR" \
  --container-name func-deployments \
  --name backend.zip \
  --file /tmp/laps-backend.zip \
  --overwrite

SAS=$(az storage blob generate-sas \
  --connection-string "$CONNSTR" \
  --container-name func-deployments \
  --name backend.zip \
  --permissions r \
  --expiry "$(date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+2H '+%Y-%m-%dT%H:%MZ')" \
  --full-uri \
  --output tsv)

az functionapp config appsettings set \
  --name "$FUNC_NAME" \
  --resource-group "$RG" \
  --settings "WEBSITE_RUN_FROM_PACKAGE=$SAS"
```

> **Note (Windows PowerShell):** The automated script (`deploy.ps1`) handles this 
> step automatically, including the SAS URL quoting workaround.

### 5️⃣ Step 5 – Generate authConfig.js and deploy the frontend

```bash
# Create authConfig.js from the deployment values
cat > frontend/authConfig.js << EOF
// Generated manually – do not commit
window.LAPS_CONFIG = {
  msalClientId: '${CLIENT_ID}',
  tenantId:     '${TENANT_ID}',
  apiBaseUrl:   '${BACKEND_URL}',
  apiScope:     'api://${CLIENT_ID}/access_as_user',
  passwordTimeout:        60,
  justificationMinLength: 10,
};
EOF

# Deploy frontend to Static Web App
swa deploy \
  --app-location ./frontend \
  --deployment-token "$DEPLOYMENT_TOKEN"
```

### 6️⃣ Step 6 – Register redirect URI and grant admin consent

```bash
# Add the Static Web App URL as a SPA redirect URI
APP_OBJ_ID=$(az ad app show --id "$CLIENT_ID" --query id -o tsv)
CURRENT_URIS=$(az ad app show --id "$CLIENT_ID" --query "spa.redirectUris" -o json)

PATCH_BODY=$(echo "$CURRENT_URIS" | \
  jq --arg url "$FRONTEND_URL" '{"spa": {"redirectUris": (. + [$url])}}')

az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
  --headers "Content-Type=application/json" \
  --body "$PATCH_BODY"

# Grant admin consent for User.Read
az ad app permission grant \
  --id "$CLIENT_ID" \
  --api "$GRAPH_APP_ID" \
  --scope "User.Read"
```

---

## 🔄 Re-deployment / updates

### 📄 Code-only update (no infrastructure changes)

```bash
# Bash
./infra/deploy.sh --project laps-prod --skip-infra

# PowerShell
.\infra\deploy.ps1 -Project laps-prod -SkipInfra
```

### 🔁 Full update with existing secret

Provide the secret you saved from the initial deployment to avoid rotating it:

```bash
# Bash
./infra/deploy.sh --project laps-prod --secret "your-existing-secret"

# PowerShell
.\infra\deploy.ps1 -Project laps-prod -Secret "your-existing-secret"
```

### ⚡ Backend only

```bash
cd backend
npm ci --omit=dev
func azure functionapp publish laps-prod-func --node
```

### 🌐 Frontend only

```bash
swa deploy \
  --app-location ./frontend \
  --deployment-token "$(az deployment sub show --name laps-laps-prod \
      --query properties.outputs.staticWebAppDeploymentToken.value -o tsv)"
```

### 🔑 Rotate client secret

When the client secret approaches expiry (default: 2 years), generate a new one
and redeploy. The `--append` flag keeps existing secrets valid during the transition.

```bash
CLIENT_ID="<your-client-id>"

NEW_SECRET=$(az ad app credential reset \
  --id "$CLIENT_ID" \
  --append \
  --years 2 \
  --display-name "LAPS Portal Easy Auth – $(date +%Y-%m-%d)" \
  --query password -o tsv)

./infra/deploy.sh --project laps-prod --secret "$NEW_SECRET"
```

After confirming the new secret works, delete the old one in Azure Portal →
App registrations → Certificates & secrets.

---

## 🔒 Restricting access (assignment enforcement)

> ⚠️ **Security requirement — do this before going live.**
> By default, **any user in your Entra ID tenant** can log in to the portal.
> Without assignment enforcement, every Entra ID user who knows the URL can sign in.

### 🏢 Via Azure Portal

1. **Entra ID** → **Enterprise Applications** → search for your app by name (e.g. `laps-prod-laps-portal`)
2. **Properties** → set **"Assignment required?"** to **Yes** → **Save**
3. **Users and groups** → **Add assignment** → select the security group that should have access (e.g. `SG-LAPS-Self-Service`)

Unassigned users receive `AADSTS50105` from Entra ID during sign-in — the portal and backend code never see the request.

> **Recommendation:** Always assign a security group rather than individual users.
> Group membership can then be managed independently in Entra ID without touching the app.

### �️ Enforcing MFA via Conditional Access

> ⚠️ **MFA cannot be enforced from the application code.**
> MSAL can request a step-up challenge, but this is not a security boundary — a user with a valid token from any other app could call the Function App API directly, bypassing any frontend MFA prompt.
> The only secure way to enforce MFA is via an **Entra ID Conditional Access Policy**.

**Setup (Azure Portal):**

1. **Entra ID** → **Security** → **Conditional Access** → **+ New policy**
2. **Users**: assign your LAPS security group (e.g. `SG-LAPS-Self-Service`)
3. **Target resources**: select your App Registration by name (e.g. `laps-prod-laps-portal`)
4. **Grant**: ✔️ **Require multi-factor authentication**
5. **Enable policy**: **On** → **Create**

Entra ID enforces MFA at token issuance — the portal and backend code never see unauthenticated or non-MFA'd requests.

> 💡 Scope the policy to your LAPS group only, not all users, to avoid impact on other apps.

### �💻 Via CLI

```bash
# Enable assignment requirement
OBJECT_ID=$(az ad sp list --display-name "laps-prod-laps-portal" --query '[0].id' -o tsv)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${OBJECT_ID}" \
  --headers "Content-Type=application/json" \
  --body '{"appRoleAssignmentRequired": true}'

# Assign a group (appRoleId 00000000... = default role)
GROUP_ID=$(az ad group show --group "SG-LAPS-Self-Service" --query id -o tsv)
az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${OBJECT_ID}/appRoleAssignedTo" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"${GROUP_ID}\",\"resourceId\":\"${OBJECT_ID}\",\"appRoleId\":\"00000000-0000-0000-0000-000000000000\"}"
```

---

## 🌐 Custom domain

### Prerequisites

Create a CNAME record in your DNS provider **before** enabling the custom domain
in Azure. The CNAME must point to the Static Web App's default hostname:

```
laps.company.com  CNAME  <project>-swa.azurestaticapps.net
```

### 📡 Enable via deployment script

```bash
# Bash
./infra/deploy.sh --project laps-prod \
  --secret "your-existing-secret" \
  --domain laps.company.com

# PowerShell
.\infra\deploy.ps1 -Project laps-prod `
  -Secret "your-existing-secret" `
  -CustomDomain laps.company.com
```

Or set the parameter in `infra/main.parameters.json` and run `az deployment sub create`:

```json
{
  "parameters": {
    "projectName":    { "value": "laps-prod" },
    "customDomain":   { "value": "laps.company.com" },
    "authClientSecret": { "value": "..." }
  }
}
```

### Update App Registration redirect URI

> ⚠️ **Required after enabling a custom domain.**
> Logins will fail with `AADSTS50011` until the custom domain URL is added as a redirect URI
> on the App Registration.

Add the custom domain URL to the App Registration's SPA redirect URIs:

```bash
CLIENT_ID="<your-client-id>"
CUSTOM_URL="https://laps.company.com"

CURRENT_URIS=$(az ad app show --id "$CLIENT_ID" --query "spa.redirectUris" -o json)
az ad app update --id "$CLIENT_ID" \
  --set "spa.redirectUris=$(echo "$CURRENT_URIS" | \
    jq --arg url "$CUSTOM_URL" '. + [$url]')"
```

Also update `authConfig.js` to point to the custom domain if you want it in the
token redirect flow (the `redirectUri` defaults to `window.location.origin`, so
it works automatically without changes to `authConfig.js`).

---

## ✔️ Verify end-to-end

After deployment, confirm everything works:

```bash
# 1. Check Function App is running
az functionapp show \
  --name laps-prod-func \
  --resource-group rg-laps-prod \
  --query "state" -o tsv
# Expected: Running

# 2. List deployed functions
az functionapp function list \
  --name laps-prod-func \
  --resource-group rg-laps-prod \
  --query "[].name" -o tsv
# Expected: my-devices, laps-password

# 3. Check Graph permissions on the Managed Identity
MI_ID=$(az functionapp identity show \
  --name laps-prod-func \
  --resource-group rg-laps-prod \
  --query principalId -o tsv)

az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_ID}/appRoleAssignments" \
  --query "value[].{role:appRoleId}" -o table

# 4. Check today's audit log
STORAGE_ACCOUNT=$(az storage account list \
  --resource-group rg-laps-prod \
  --query "[0].name" -o tsv)

az storage entity query \
  --account-name "$STORAGE_ACCOUNT" \
  --table-name LapsAuditLog \
  --filter "PartitionKey eq '$(date +%Y-%m-%d)'" \
  --auth-mode login
```

---

## 🛠️ Troubleshooting

### 🔁 MSAL sign-in loop (redirect back to login page)

**Cause:** The Static Web App URL is not registered as a redirect URI on the
App Registration.

```bash
# Check current redirect URIs
az ad app show --id "<client-id>" --query "spa.redirectUris" -o json

# Add missing URL
az ad app update --id "<client-id>" \
  --set 'spa.redirectUris=["https://<swa>.azurestaticapps.net","http://localhost:4280"]'
```

---

### 🔴 HTTP 401 from the Function App

**Cause A:** Easy Auth client secret is wrong or missing.

```bash
# Verify Easy Auth is configured
az webapp auth show \
  --name laps-prod-func \
  --resource-group rg-laps-prod \
  --query "{enabled:enabled,action:globalValidation.unauthenticatedClientAction}"
```

Re-run the full deployment with the correct secret if needed.

**Cause B:** Token audience mismatch — the identifier URI (`api://<clientId>`)
is missing from the App Registration.

```bash
az ad app show --id "<client-id>" --query "identifierUris"
# Expected: ["api://<client-id>"]

# Fix:
az ad app update --id "<client-id>" --identifier-uris "api://<client-id>"
```

---

### 🔴 HTTP 403 – "Device not owned"

**Cause:** The device exists in Entra ID but is not in the user's
`registeredDevices` list (i.e. the user is not a registered owner).

Check in Entra ID:

```bash
az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/users/<user-oid>/registeredDevices" \
  --query "value[].displayName"
```

If the device is Autopilot/Intune enrolled but not registered to the user,
verify the primary user assignment in Intune → Devices → [device] → Properties.

---

### 🔴 HTTP 404 – "No LAPS credential"

**Cause:** Windows LAPS is not configured for the device in Intune, or the
policy has not yet applied.

- Verify the device has an Intune configuration profile with LAPS enabled
  (Endpoint Security → Account protection → Windows LAPS)
- Check the device has checked in recently
- Confirm LAPS backup is set to **Azure Active Directory** (not on-premises)

```bash
# Verify the credential exists in Graph
az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/deviceLocalCredentials/<device-id>?select=deviceName" \
  --query "deviceName"
```

---

### 🔴 HTTP 500 – Graph API error

**Cause:** Managed Identity is missing Graph permissions.

```bash
# Check assigned app roles
MI_ID=$(az functionapp identity show \
  --name laps-prod-func \
  --resource-group rg-laps-prod \
  --query principalId -o tsv)

az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_ID}/appRoleAssignments" \
  --query "value[].appRoleId"
```

Re-run the script or Step 3 of the manual guide to assign the missing permissions.

---

### 🔍 No devices shown in the portal

**Cause:** The user has no devices in their `registeredDevices` list.
This list only contains devices where the user is a **registered owner**, which
is set automatically for Entra ID-joined and Hybrid-joined devices during
enrollment, but may not be set for some older or re-enrolled devices.

Verify:

```bash
az rest \
  --method GET \
  --uri "https://graph.microsoft.com/v1.0/users/<user-upn>/registeredDevices" \
  --query "value[].{name:displayName, id:id}"
```

---

### ⚠️ Function App is not starting

Check the Application Insights live logs:

```bash
az monitor app-insights query \
  --apps laps-prod-ai \
  --resource-group rg-laps-prod \
  --analytics-query "traces | where timestamp > ago(10m) | order by timestamp desc | take 50" \
  --query "tables[0].rows"
```

Or stream logs directly:

```bash
func azure functionapp logstream laps-prod-func
```
