#!/usr/bin/env bash
# =============================================================================
# deploy.sh – LAPS Self-Service Portal – Full Deployment Script
# =============================================================================
#
# Deploys the complete portal in a single run:
#   1.  Prerequisite + login check
#   2.  Bicep infrastructure (initial pass, no Easy Auth secret)
#   3.  Entra ID App Registration post-config (identifier URI)
#   4.  Client secret generation
#   5.  Bicep re-deploy with Easy Auth secret
#   6.  Microsoft Graph permissions for the Managed Identity
#   7.  Backend deployment (Azure Functions)
#   8.  Frontend configuration generation (authConfig.js)
#   9.  Frontend deployment (Azure Static Web Apps)
#  10.  Deployment summary
#
# Usage
# ─────
#   First deployment:
#     ./infra/deploy.sh --project laps-prod
#
#   Re-deploy / update (existing secret – avoids regenerating):
#     ./infra/deploy.sh --project laps-prod --secret "existing-client-secret"
#
#   Infrastructure only (skip code deploys):
#     ./infra/deploy.sh --project laps-prod --skip-backend --skip-frontend
#
#   Code only (skip Bicep):
#     ./infra/deploy.sh --project laps-prod --skip-infra
#
# Requirements
# ────────────
#   az    Azure CLI >= 2.50             https://aka.ms/installazurecli
#   swa   Static Web Apps CLI           npm install -g @azure/static-web-apps-cli
#   node  Node.js >= 24                 https://nodejs.org
#
# =============================================================================

set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FRONTEND_DIR="$REPO_ROOT/frontend"
BACKEND_DIR="$REPO_ROOT/backend"

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31]'
YELLOW='\033[1;33]'
GREEN='\033[0;32]'
CYAN='\033[0;36]'
BOLD='\033[1m'
NC='\033[0m'

print_header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $*${NC}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; }
print_step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
print_success() { echo -e "${GREEN}  ✓ $*${NC}"; }
print_warn()    { echo -e "${YELLOW}  ⚠ $*${NC}"; }
print_error()   { echo -e "${RED}  ✗ $*${NC}" >&2; }
die()           { print_error "$*"; exit 1; }

# ── Argument parsing ──────────────────────────────────────────────────────────

PROJECT_NAME=""
LOCATION=""
SWA_LOCATION=""
RESOURCE_GROUP=""
CUSTOM_DOMAIN=""
EXISTING_SECRET=""
SKIP_INFRA=false
SKIP_BACKEND=false
SKIP_FRONTEND=false

usage() {
  echo -e "
${BOLD}Usage:${NC}
  $0 --project <name> [options]

${BOLD}Required:${NC}
  --project <name>     Project name prefix (e.g. laps-prod). Used for all resource names.

${BOLD}Options:${NC}
  --location <region>      Azure region (default: germanywestcentral)
  --swa-location <region>  Azure region for the Static Web App (default: westeurope)
                           Allowed: westus2, centralus, eastus2, westeurope, eastasia
  --resource-group <name>  Resource group name (default: rg-<project>)
  --domain <fqdn>      Custom domain for the Static Web App (optional)
  --secret <secret>    Existing Easy Auth client secret – skips secret generation
                       Use this for re-deployments to avoid rotating the secret
  --skip-infra         Skip Bicep deployment (code-only update)
  --skip-backend       Skip Azure Functions deployment
  --skip-frontend      Skip Static Web App deployment
  -h, --help           Show this help

${BOLD}Examples:${NC}
  $0 --project laps-prod
  $0 --project laps-prod --location westeurope
  $0 --project laps-prod --secret 'my-existing-secret'
  $0 --project laps-prod --skip-infra
"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT_NAME="$2";     shift 2 ;;
    --location)       LOCATION="$2";         shift 2 ;;
    --swa-location)   SWA_LOCATION="$2";     shift 2 ;;
    --resource-group) RESOURCE_GROUP="$2";   shift 2 ;;
    --domain)         CUSTOM_DOMAIN="$2";    shift 2 ;;
    --secret)         EXISTING_SECRET="$2";  shift 2 ;;
    --skip-infra)     SKIP_INFRA=true;       shift   ;;
    --skip-backend)   SKIP_BACKEND=true;     shift   ;;
    --skip-frontend)  SKIP_FRONTEND=true;    shift   ;;
    -h|--help)        usage ;;
    *) die "Unknown argument: $1. Run '$0 --help' for usage." ;;
  esac
done

# Prompt for project name if not provided
if [[ -z "$PROJECT_NAME" ]]; then
  echo -e "${YELLOW}No --project specified.${NC}"
  read -rp "  Enter project name (e.g. laps-prod): " PROJECT_NAME
  [[ -z "$PROJECT_NAME" ]] && die "Project name is required."
fi

# Validate project name length (Azure SWA name limit: projectName + '-swa' ≤ 40)
if [[ ${#PROJECT_NAME} -lt 3 ]]; then
  die "Project name '${PROJECT_NAME}' is too short (${#PROJECT_NAME} chars, minimum 3)."
fi
if [[ ${#PROJECT_NAME} -gt 36 ]]; then
  die "Project name '${PROJECT_NAME}' is too long (${#PROJECT_NAME} chars, maximum 36)."
fi

# Prompt for location if not provided
if [[ -z "$LOCATION" ]]; then
  echo "  Tip: run 'az account list-locations -o table' to list all available regions."
  read -rp "  Enter Azure region (e.g. westeurope) [germanywestcentral]: " LOCATION_INPUT
  LOCATION="${LOCATION_INPUT:-germanywestcentral}"
fi

# Prompt for SWA location if not provided
if [[ -z "$SWA_LOCATION" ]]; then
  echo "  Static Web Apps are only available in: westus2, centralus, eastus2, westeurope, eastasia"
  read -rp "  Enter SWA region [westeurope]: " SWA_LOC_INPUT
  SWA_LOCATION="${SWA_LOC_INPUT:-westeurope}"
fi

# Prompt for resource group if not provided
if [[ -z "$RESOURCE_GROUP" ]]; then
  read -rp "  Enter resource group name [rg-${PROJECT_NAME}]: " RG_INPUT
  RESOURCE_GROUP="${RG_INPUT:-rg-${PROJECT_NAME}}"
fi
FUNC_APP_NAME="${PROJECT_NAME}-func"
SWA_NAME="${PROJECT_NAME}-swa"
DEPLOY_NAME="laps-${PROJECT_NAME}"

print_header "LAPS Self-Service Portal – Deployment"
echo "  Project    : $PROJECT_NAME"
echo "  Location   : $LOCATION"
echo "  SWA region : $SWA_LOCATION"
echo "  Resource group: $RESOURCE_GROUP"
[[ -n "$CUSTOM_DOMAIN" ]] && echo "  Custom domain : $CUSTOM_DOMAIN"
echo ""

# ── Step 1: Prerequisite checks ───────────────────────────────────────────────

print_step "Step 1/9 – Checking prerequisites"

check_command() {
  local cmd="$1" label="$2" install_hint="$3"
  if ! command -v "$cmd" &>/dev/null; then
    print_error "$label not found."
    echo "  Install: $install_hint"
    exit 1
  fi
  local version
  version=$("$cmd" --version 2>&1 | head -1)
  print_success "$label found  ($version)"
}

check_command az   "Azure CLI"           "https://aka.ms/installazurecli"
check_command swa  "Static Web Apps CLI" "npm install -g @azure/static-web-apps-cli"
check_command node "Node.js"             "https://nodejs.org"
check_command npm  "npm"                 "https://nodejs.org"

# ── Step 2: Azure login check ─────────────────────────────────────────────────

print_step "Step 2/9 – Verifying Azure CLI login"

if ! az account show &>/dev/null; then
  echo "  Not logged in. Launching az login..."
  az login
fi

TENANT_ID=$(az account show --query tenantId -o tsv)
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_NAME=$(az account show --query name -o tsv)

print_success "Logged in"
echo "  Tenant:       $TENANT_ID"
echo "  Subscription: $SUBSCRIPTION_NAME ($SUBSCRIPTION_ID)"

# Confirm subscription before making changes
echo ""
read -rp "  Deploy to this subscription? [Y/n] " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')" != "y" ]] && { echo "Aborted."; exit 0; }

# ── Step 3: App Registration (CLI) + Bicep infrastructure ────────────────────

CLIENT_ID=""
CLIENT_SECRET=""
BACKEND_URL=""
FRONTEND_URL=""
MI_PRINCIPAL_ID=""
DEPLOYMENT_TOKEN=""

APP_DISPLAY_NAME="${PROJECT_NAME}-laps-portal"

if [[ "$SKIP_INFRA" == false ]]; then

  print_step "Step 3/9 – App Registration + Bicep infrastructure"

  # ── App Registration via CLI ────────────────────────────────────────────────
  echo "  Looking up App Registration '${APP_DISPLAY_NAME}'..."
  CLIENT_ID=$(az ad app list \
    --display-name "$APP_DISPLAY_NAME" \
    --query "[0].appId" -o tsv 2>/dev/null || true)

  if [[ -z "$CLIENT_ID" ]]; then
    echo "  Creating App Registration..."
    CLIENT_ID=$(az ad app create \
      --display-name "$APP_DISPLAY_NAME" \
      --sign-in-audience AzureADMyOrg \
      --query appId -o tsv)
    print_success "App Registration created"

    echo "  Creating service principal..."
    az ad sp create --id "$CLIENT_ID" --output none
    print_success "Service principal created"
  else
    print_success "App Registration found (clientId: $CLIENT_ID)"
  fi

  # Set identifier URI (required for api:// audience in Easy Auth)
  echo "  Setting identifier URI (api://$CLIENT_ID)..."
  az ad app update \
    --id "$CLIENT_ID" \
    --identifier-uris "api://$CLIENT_ID" \
    2>/dev/null || print_warn "Identifier URI may already be set – continuing"
  print_success "Identifier URI set"

  # Ensure access_as_user OAuth2 scope is defined (required for acquireTokenSilent)
  echo "  Ensuring 'access_as_user' scope is defined..."
  APP_OBJECT_ID=$(az ad app show --id "$CLIENT_ID" --query id -o tsv)
  SCOPE_EXISTS=$(az ad app show --id "$CLIENT_ID" \
    --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv 2>/dev/null || true)
  if [[ -n "$SCOPE_EXISTS" ]]; then
    print_success "'access_as_user' scope already defined"
  else
    SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null \
      || uuidgen 2>/dev/null \
      || cat /proc/sys/kernel/random/uuid)
    SCOPE_FILE=$(mktemp)
    cat > "$SCOPE_FILE" << SCOPE_JSON
{
  "api": {
    "oauth2PermissionScopes": [{
      "adminConsentDescription": "Allow the app to access LAPS Self-Service on behalf of the signed-in user",
      "adminConsentDisplayName": "Access LAPS Self-Service",
      "id": "${SCOPE_ID}",
      "isEnabled": true,
      "type": "User",
      "userConsentDescription": "Allow the app to access LAPS Self-Service on your behalf",
      "userConsentDisplayName": "Access LAPS Self-Service",
      "value": "access_as_user"
    }]
  }
}
SCOPE_JSON
    az rest \
      --method PATCH \
      --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJECT_ID}" \
      --headers "Content-Type=application/json" \
      --body "@${SCOPE_FILE}" \
      --output none
    rm -f "$SCOPE_FILE"
    print_success "'access_as_user' scope defined"
  fi

  # Client secret
  if [[ -n "$EXISTING_SECRET" ]]; then
    CLIENT_SECRET="$EXISTING_SECRET"
    print_success "Using provided client secret"
  else
    echo "  Generating Easy Auth client secret..."
    set +e
    CRED_OUTPUT=$(az ad app credential reset \
      --id "$CLIENT_ID" --append --years 2 \
      --display-name "LAPS Portal Easy Auth – $(date +%Y-%m-%d)" \
      --query password -o tsv --only-show-errors 2>&1)
    CRED_EXIT=$?
    set -e
    if [[ $CRED_EXIT -ne 0 ]]; then
      if echo "$CRED_OUTPUT" | grep -qi "policy\|Credential type not allowed"; then
        print_error "Could not create client secret – blocked by an Entra ID App Management Policy."
        echo "  → In Azure Portal: Entra ID → Enterprise Applications → Security → App Management Policies"
        echo "    Disable 'Block password credentials for applications' or exempt this app."
        echo ""
        echo "  Once resolved, re-run and pass the manually created secret:"
        echo "  ./infra/deploy.sh --project $PROJECT_NAME --secret '<your-secret>'"
        exit 1
      fi
      die "Failed to create client secret: $CRED_OUTPUT"
    fi
    CLIENT_SECRET="$CRED_OUTPUT"
    print_success "Client secret generated (expires in 2 years)"
  fi

  # ── Bicep deployment (single pass – all params known upfront) ────────────────
  echo "  Deploying Bicep infrastructure..."
  BICEP_PARAMS=(
    "projectName=$PROJECT_NAME"
    "location=$LOCATION"
    "swaLocation=$SWA_LOCATION"
    "resourceGroupName=$RESOURCE_GROUP"
    "authClientId=$CLIENT_ID"
    "authClientSecret=$CLIENT_SECRET"
  )
  [[ -n "$CUSTOM_DOMAIN" ]] && BICEP_PARAMS+=("customDomain=$CUSTOM_DOMAIN")

  az deployment sub create \
    --location "$LOCATION" \
    --template-file "$SCRIPT_DIR/main.bicep" \
    --name "$DEPLOY_NAME" \
    --parameters "${BICEP_PARAMS[@]}" \
    --output none
  print_success "Bicep deployment complete"

  # Collect outputs
  echo "  Reading deployment outputs..."
  BACKEND_URL=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.backendUrl.value" -o tsv)
  FRONTEND_URL=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.frontendUrl.value" -o tsv)
  MI_PRINCIPAL_ID=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.managedIdentityPrincipalId.value" -o tsv)
  DEPLOYMENT_TOKEN=$(az staticwebapp secrets list \
    --name "$SWA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.apiKey" -o tsv)

  print_success "Outputs collected"
  echo "  Client ID   : $CLIENT_ID"
  echo "  Backend URL : $BACKEND_URL"
  echo "  Frontend URL: $FRONTEND_URL"

else
  # --skip-infra: read existing values from CLI / existing resources
  print_step "Step 3/9 – Skipping Bicep deployment (--skip-infra)"

  echo "  Looking up App Registration '${APP_DISPLAY_NAME}'..."
  CLIENT_ID=$(az ad app list \
    --display-name "$APP_DISPLAY_NAME" \
    --query "[0].appId" -o tsv 2>/dev/null || true)
  [[ -z "$CLIENT_ID" ]] && die "App Registration '${APP_DISPLAY_NAME}' not found. Has the project been deployed yet?"

  BACKEND_URL=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.backendUrl.value" -o tsv 2>/dev/null) \
    || die "Could not read deployment outputs. Has '$DEPLOY_NAME' been deployed yet?"
  FRONTEND_URL=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.frontendUrl.value" -o tsv)
  MI_PRINCIPAL_ID=$(az deployment sub show \
    --name "$DEPLOY_NAME" \
    --query "properties.outputs.managedIdentityPrincipalId.value" -o tsv)
  DEPLOYMENT_TOKEN=$(az staticwebapp secrets list \
    --name "$SWA_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "properties.apiKey" -o tsv)

  print_success "Existing deployment values loaded"
fi

# ── Step 4: Microsoft Graph permissions ───────────────────────────────────────

print_step "Step 4/9 – Assigning Microsoft Graph permissions to Managed Identity"

# Object ID of the Microsoft Graph service principal (constant across all tenants)
GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"
GRAPH_SP_OBJECT_ID=$(az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)

assign_graph_role() {
  local role_name="$1"

  local role_id
  role_id=$(az ad sp show \
    --id "$GRAPH_APP_ID" \
    --query "appRoles[?value=='${role_name}'].id | [0]" \
    -o tsv)

  if [[ -z "$role_id" ]]; then
    print_warn "App role '$role_name' not found on Graph SP – skipping"
    return
  fi

  # Check if already assigned
  local already
  already=$(az rest \
    --method GET \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_PRINCIPAL_ID}/appRoleAssignments" \
    --query "value[?appRoleId=='${role_id}'].id | [0]" \
    -o tsv 2>/dev/null || true)

  if [[ -n "$already" ]]; then
    print_success "$role_name  (already assigned)"
    return
  fi

  az rest \
    --method POST \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${MI_PRINCIPAL_ID}/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{
      \"principalId\": \"${MI_PRINCIPAL_ID}\",
      \"resourceId\":  \"${GRAPH_SP_OBJECT_ID}\",
      \"appRoleId\":   \"${role_id}\"
    }" \
    --output none

  print_success "$role_name  (assigned)"
}

assign_graph_role "Device.Read.All"
assign_graph_role "DeviceLocalCredential.Read.All"
assign_graph_role "Directory.Read.All"

# ── Step 5: Backend deployment ────────────────────────────────────────────────

if [[ "$SKIP_BACKEND" == false ]]; then
  print_step "Step 5/9 – Deploying backend (Azure Functions)"

  echo "  Installing npm dependencies..."
  (cd "$BACKEND_DIR" && npm install --omit=dev)
  print_success "npm dependencies installed"

  echo "  Creating deployment package..."
  # Use PID-based name — avoids mktemp suffix limitations on macOS BSD
  ZIP_FILE="/tmp/laps-deploy-$$.zip"
  rm -f "$ZIP_FILE"
  (cd "$BACKEND_DIR" && zip -r "$ZIP_FILE" . -x "*.git*" > /dev/null)
  print_success "Package created ($(du -sh "$ZIP_FILE" | cut -f1))"

  # Upload to blob storage and set WEBSITE_RUN_FROM_PACKAGE.
  # Avoids slow/unreliable Kudu SCM endpoint for Linux Function Apps.
  echo "  Looking up storage account..."
  STORAGE_ACCOUNT=$(az storage account list \
    --resource-group "$RESOURCE_GROUP" \
    --query '[0].name' -o tsv 2>/dev/null)
  STORAGE_KEY=$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[0].value' -o tsv)

  CONTAINER="func-deployments"
  BLOB_NAME="${FUNC_APP_NAME}-$(date +%Y%m%d%H%M%S).zip"
  EXPIRY="$(( $(date +%Y) + 2 ))-$(date +%m-%dT%H:%M:%SZ)"

  az storage container create \
    --name "$CONTAINER" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --output none 2>/dev/null || true

  echo "  Uploading package to blob storage..."
  az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --file "$ZIP_FILE" \
    --overwrite \
    --output none
  rm -f "$ZIP_FILE"
  print_success "Package uploaded to blob storage"

  SAS_URL=$(az storage blob generate-sas \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --container-name "$CONTAINER" \
    --name "$BLOB_NAME" \
    --permissions r \
    --expiry "$EXPIRY" \
    --full-uri \
    -o tsv)

  echo "  Configuring Function App (WEBSITE_RUN_FROM_PACKAGE)..."
  az functionapp config appsettings set \
    --name "$FUNC_APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --settings "WEBSITE_RUN_FROM_PACKAGE=$SAS_URL" \
    --output none
  print_success "Backend deployed to $FUNC_APP_NAME – Function App will restart automatically"
else
  print_step "Step 5/9 – Skipping backend deployment (--skip-backend)"
fi

# ── Step 6: Generate authConfig.js ───────────────────────────────────────────

print_step "Step 6/9 – Generating frontend configuration (authConfig.js)"

cat > "$FRONTEND_DIR/authConfig.js" << AUTHCONFIG
// Generated by deploy.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
// DO NOT commit this file – it is listed in .gitignore.
// Re-run deploy.sh to regenerate, or edit manually for local testing.

window.LAPS_CONFIG = {
  msalClientId: '${CLIENT_ID}',
  tenantId:     '${TENANT_ID}',
  apiBaseUrl:   '${BACKEND_URL}',
  apiScope:     'api://${CLIENT_ID}/access_as_user',
  passwordTimeout:        60,
  justificationMinLength: 10,
};
AUTHCONFIG

print_success "authConfig.js written to $FRONTEND_DIR/authConfig.js"

# ── Step 7: Frontend deployment ───────────────────────────────────────────────

if [[ "$SKIP_FRONTEND" == false ]]; then
  print_step "Step 7/9 – Deploying frontend (Static Web App)"

  echo "  Deploying to $SWA_NAME..."
  swa deploy \
    --app-location "$FRONTEND_DIR" \
    --deployment-token "$DEPLOYMENT_TOKEN" \
    --env production

  print_success "Frontend deployed to $SWA_NAME"
else
  print_step "Step 7/9 – Skipping frontend deployment (--skip-frontend)"
fi

# ── Step 8: Add SWA URL to App Registration redirect URIs ─────────────────────

print_step "Step 8/9 – Updating App Registration redirect URIs"

CURRENT_URIS=$(az ad app show \
  --id "$CLIENT_ID" \
  --query "spa.redirectUris" \
  -o json)

# Only add the SWA URL if it's not already present
if echo "$CURRENT_URIS" | grep -q "$FRONTEND_URL"; then
  print_success "Redirect URI already registered: $FRONTEND_URL"
else
  # Build updated URI list using python3 (available on macOS and Linux by default)
  NEW_URIS=$(python3 -c \
    "import json,sys; uris=json.loads(sys.argv[1]); uris.append(sys.argv[2]); print(json.dumps(uris))" \
    "$CURRENT_URIS" "$FRONTEND_URL")

  APP_OBJ_ID=$(az ad app show --id "$CLIENT_ID" --query id -o tsv)
  az rest --method PATCH \
    --uri "https://graph.microsoft.com/v1.0/applications/${APP_OBJ_ID}" \
    --headers "Content-Type=application/json" \
    --body "{\"spa\":{\"redirectUris\":${NEW_URIS}}}" \
    2>/dev/null \
  && print_success "Redirect URI added: $FRONTEND_URL" \
  || print_warn "Could not update redirect URIs automatically – add $FRONTEND_URL manually in Azure Portal"
fi

# ── Step 9: Grant Admin Consent ───────────────────────────────────────────────

print_step "Step 9/9 – Admin Consent for User.Read delegated permission"

az ad app permission grant \
  --id "$CLIENT_ID" \
  --api "$GRAPH_APP_ID" \
  --scope "User.Read" \
  --output none 2>/dev/null \
&& print_success "Admin consent granted for User.Read" \
|| print_warn "Could not grant admin consent automatically – grant it in Azure Portal → App registrations → API permissions → Grant admin consent"

# ── Deployment summary ────────────────────────────────────────────────────────

print_header "Deployment Complete"

echo -e "
  ${BOLD}Frontend URL  :${NC} ${FRONTEND_URL}
  ${BOLD}Backend URL   :${NC} ${BACKEND_URL}
  ${BOLD}Resource Group:${NC} ${RESOURCE_GROUP}
  ${BOLD}Function App  :${NC} ${FUNC_APP_NAME}
  ${BOLD}Static Web App:${NC} ${SWA_NAME}
  ${BOLD}Client ID     :${NC} ${CLIENT_ID}
  ${BOLD}Tenant ID     :${NC} ${TENANT_ID}
"

if [[ -n "$CLIENT_SECRET" ]]; then
  echo -e "${YELLOW}${BOLD}  ⚠ Save this client secret – it cannot be retrieved again:${NC}"
  echo -e "${YELLOW}    $CLIENT_SECRET${NC}"
  echo ""
fi

echo -e "${GREEN}${BOLD}  Next steps:${NC}"
echo "  1. Open $FRONTEND_URL in a browser"
echo "  2. Sign in with an Entra ID account"
echo "  3. Verify your managed devices appear in the list"
echo "  4. Test LAPS password retrieval"
echo ""
echo -e "  For re-deployments: $0 --project $PROJECT_NAME --secret '<your-secret>'"
echo ""
echo -e "${RED}${BOLD}  🚨 Mandatory Access Controls – do this before going live:${NC}"
echo ""
echo -e "  ${BOLD}1️⃣  Entra ID Assignment Enforcement (who is allowed)${NC}"
echo "     By default, every user in your tenant can sign in."
echo "     Open Entra ID → Enterprise Applications → your portal app"
echo "     Set 'Assignment required?' → Yes"
echo "     Assign a dedicated security group (e.g. SG-LAPS-Self-Service)"
echo "     → Only group members can reach the portal."
echo ""
echo -e "  ${BOLD}2️⃣  Conditional Access (under which conditions)${NC}"
echo "     Create a Conditional Access Policy targeting the same group:"
echo "     🔐 Require Multi-Factor Authentication"
echo "     🖥️  Require a compliant or hybrid-joined device (if applicable)"
echo "     🌍 Restrict by location or country"
echo "     🚫 Block legacy and risky authentication attempts"
echo "     📊 Monitor sign-ins for anomalous activity"
echo ""
echo "     Together these two layers ensure that only authorized, verified,"
echo "     and policy-compliant sessions can request LAPS credentials."
echo ""
