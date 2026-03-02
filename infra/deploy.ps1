#Requires -Version 7
<#
.SYNOPSIS
    LAPS Self-Service Portal – Full Deployment Script (PowerShell)

.DESCRIPTION
    Deploys the complete portal in a single run:
      1.  Prerequisite + login check
      2.  Bicep infrastructure (initial pass, no Easy Auth secret)
      3.  Entra ID App Registration post-config (identifier URI)
      4.  Client secret generation
      5.  Bicep re-deploy with Easy Auth secret
      6.  Microsoft Graph permissions for the Managed Identity
      7.  Backend deployment (Azure Functions)
      8.  Frontend configuration generation (authConfig.js)
      9.  Frontend deployment (Azure Static Web Apps)
     10.  Deployment summary

.PARAMETER Project
    Project name prefix used for all Azure resource names (e.g. laps-prod).
    Required.

.PARAMETER Location
    Azure region for all resources. Default: germanywestcentral

.PARAMETER SwaLocation
    Azure region for the Static Web App. Default: westeurope
    Allowed values: westus2, centralus, eastus2, westeurope, eastasia

.PARAMETER CustomDomain
    Optional custom domain (FQDN) for the Static Web App.

.PARAMETER Secret
    Existing Easy Auth client secret. Provide this on re-deployments to skip
    secret regeneration. If omitted, a new secret is generated.

.PARAMETER SkipInfra
    Skip the Bicep deployment. Reads values from the existing deployment.
    Useful for code-only updates.

.PARAMETER SkipBackend
    Skip the Azure Functions deployment.

.PARAMETER SkipFrontend
    Skip the Static Web App deployment.

.EXAMPLE
    # First deployment
    .\infra\deploy.ps1 -Project laps-prod

.EXAMPLE
    # Re-deploy with existing secret
    .\infra\deploy.ps1 -Project laps-prod -Secret 'existing-client-secret'

.EXAMPLE
    # Infrastructure only
    .\infra\deploy.ps1 -Project laps-prod -SkipBackend -SkipFrontend

.EXAMPLE
    # Code-only update
    .\infra\deploy.ps1 -Project laps-prod -SkipInfra
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $Project,

    [string] $Location      = '',
    [string] $SwaLocation   = '',
    [string] $ResourceGroup = '',
    [string] $CustomDomain  = '',
    [string] $Secret        = '',

    [switch] $SkipInfra,
    [switch] $SkipBackend,
    [switch] $SkipFrontend
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Paths ──────────────────────────────────────────────────────────────────────

$ScriptDir   = $PSScriptRoot
$RepoRoot    = Split-Path $ScriptDir -Parent
$FrontendDir = Join-Path $RepoRoot 'frontend'
$BackendDir  = Join-Path $RepoRoot 'backend'

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "══════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Step([string]$Text) {
    Write-Host ""
    Write-Host "▶ $Text" -ForegroundColor Cyan
}

function Write-Ok([string]$Text)   { Write-Host "  ✓ $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  ⚠ $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "  ✗ $Text" -ForegroundColor Red }

function Assert-Command([string]$Cmd, [string]$Label, [string]$InstallHint) {
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Fail "$Label not found."
        Write-Host "  Install: $InstallHint"
        exit 1
    }
    $ver = & $Cmd --version 2>&1 | Select-Object -First 1
    Write-Ok "$Label found  ($ver)"
}

function Invoke-Az {
    <# Wrapper: runs az CLI, throws on non-zero exit code, returns stdout. #>
    $result = az @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($args -join ' ') failed: $result"
    }
    return $result
}

function Get-DeploymentOutput([string]$DeployName, [string]$OutputName) {
    return (Invoke-Az deployment sub show `
        --name $DeployName `
        --query "properties.outputs.$OutputName.value" `
        -o tsv)
}

# ── Interactive project name ───────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = Read-Host '  Enter project name (e.g. laps-prod)'
    if ([string]::IsNullOrWhiteSpace($Project)) {
        Write-Fail 'Project name is required.'
        exit 1
    }
}

# Validate project name length (Azure SWA name limit: projectName + '-swa' <= 40)
if ($Project.Length -lt 3) {
    Write-Fail "Project name '$Project' is too short ($($Project.Length) chars, minimum 3)."
    exit 1
}
if ($Project.Length -gt 36) {
    Write-Fail "Project name '$Project' is too long ($($Project.Length) chars, maximum 36)."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Location)) {
    Write-Host "  Tip: run 'az account list-locations -o table' to list all available regions."
    $LocationInput = Read-Host '  Enter Azure region (e.g. westeurope) [germanywestcentral]'
    $Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { 'germanywestcentral' } else { $LocationInput }
}

if ([string]::IsNullOrWhiteSpace($SwaLocation)) {
    Write-Host '  Static Web Apps are only available in: westus2, centralus, eastus2, westeurope, eastasia'
    $SwaInput = Read-Host '  Enter SWA region [westeurope]'
    $SwaLocation = if ([string]::IsNullOrWhiteSpace($SwaInput)) { 'westeurope' } else { $SwaInput }
}

if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
    $RgInput = Read-Host "  Enter resource group name [rg-$Project]"
    $ResourceGroup = if ([string]::IsNullOrWhiteSpace($RgInput)) { "rg-$Project" } else { $RgInput }
}
$FuncAppName   = "$Project-func"
$SwaName       = "$Project-swa"
$DeployName    = "laps-$Project"

Write-Header 'LAPS Self-Service Portal – Deployment'
Write-Host "  Project       : $Project"
Write-Host "  Location      : $Location"
Write-Host "  SWA region    : $SwaLocation"
Write-Host "  Resource group: $ResourceGroup"
if ($CustomDomain) { Write-Host "  Custom domain : $CustomDomain" }
Write-Host ""

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

Write-Step 'Step 1/9 – Checking prerequisites'

Assert-Command 'az'   'Azure CLI'                  'https://aka.ms/installazurecli'
Assert-Command 'func' 'Azure Functions Core Tools' 'npm install -g azure-functions-core-tools@4'
Assert-Command 'swa'  'Static Web Apps CLI'        'npm install -g @azure/static-web-apps-cli'
Assert-Command 'node' 'Node.js'                    'https://nodejs.org'
Assert-Command 'npm'  'npm'                        'https://nodejs.org'

# ── Step 2: Azure login ───────────────────────────────────────────────────────

Write-Step 'Step 2/9 – Verifying Azure CLI login'

$accountJson = az account show 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host '  Not logged in. Launching az login…'
    az login
}

$TenantId          = (Invoke-Az account show --query tenantId -o tsv)
$SubscriptionId    = (Invoke-Az account show --query id -o tsv)
$SubscriptionName  = (Invoke-Az account show --query name -o tsv)

Write-Ok 'Logged in'
Write-Host "  Tenant:       $TenantId"
Write-Host "  Subscription: $SubscriptionName ($SubscriptionId)"

$confirm = Read-Host '  Deploy to this subscription? [Y/n]'
if ($confirm -ne '' -and $confirm.ToLower() -ne 'y') {
    Write-Host 'Aborted.'
    exit 0
}

# ── Step 3: App Registration (CLI) + Bicep infrastructure ────────────────────

$ClientId        = ''
$ClientSecret    = ''
$BackendUrl      = ''
$FrontendUrl     = ''
$MiPrincipalId   = ''
$DeploymentToken = ''

$AppDisplayName = "$Project-laps-portal"

if (-not $SkipInfra) {

    Write-Step 'Step 3/9 – App Registration + Bicep infrastructure'

    # ── App Registration via CLI ───────────────────────────────────────────────
    Write-Host "  Looking up App Registration '$AppDisplayName'…"
    $ClientId = (az ad app list --display-name $AppDisplayName --query '[0].appId' -o tsv 2>$null)

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Host '  Creating App Registration…'
        $ClientId = (Invoke-Az ad app create `
            --display-name $AppDisplayName `
            --sign-in-audience AzureADMyOrg `
            --query appId -o tsv)
        Write-Ok 'App Registration created'

        Write-Host '  Creating service principal…'
        Invoke-Az ad sp create --id $ClientId --output none | Out-Null
        Write-Ok 'Service principal created'
    } else {
        Write-Ok "App Registration found (clientId: $ClientId)"
    }

    # Set identifier URI
    Write-Host "  Setting identifier URI (api://$ClientId)…"
    try {
        Invoke-Az ad app update --id $ClientId --identifier-uris "api://$ClientId" | Out-Null
        Write-Ok 'Identifier URI set'
    } catch {
        Write-Warn 'Identifier URI may already be set – continuing'
    }

    # Ensure access_as_user OAuth2 scope is defined (required for acquireTokenSilent)
    Write-Host "  Ensuring 'access_as_user' scope is defined…"
    $AppObjectId = (az ad app show --id $ClientId --query id -o tsv 2>$null)
    $ScopeExists = (az ad app show --id $ClientId `
        --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" `
        -o tsv 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($ScopeExists)) {
        Write-Ok "'access_as_user' scope already defined"
    } else {
        $ScopeId   = [System.Guid]::NewGuid().ToString()
        $scopeBody = @{
            api = @{
                oauth2PermissionScopes = @(@{
                    adminConsentDescription = 'Allow the app to access LAPS Self-Service on behalf of the signed-in user'
                    adminConsentDisplayName = 'Access LAPS Self-Service'
                    id          = $ScopeId
                    isEnabled   = $true
                    type        = 'User'
                    userConsentDescription  = 'Allow the app to access LAPS Self-Service on your behalf'
                    userConsentDisplayName  = 'Access LAPS Self-Service'
                    value       = 'access_as_user'
                })
            }
        } | ConvertTo-Json -Depth 5 -Compress
        $scopeFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content $scopeFile -Value $scopeBody -Encoding utf8 -NoNewline
            az rest --method PATCH `
                --uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId" `
                --headers 'Content-Type=application/json' `
                --body "@$scopeFile" `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "PATCH failed" }
            Write-Ok "'access_as_user' scope defined"
        } finally {
            Remove-Item $scopeFile -ErrorAction SilentlyContinue
        }
    }

    # Client secret
    if ($Secret) {
        $ClientSecret = $Secret
        Write-Ok 'Using provided client secret'
    } else {
        Write-Host '  Generating Easy Auth client secret…'
        $secretDate = (Get-Date -Format 'yyyy-MM-dd')
        try {
            $ClientSecret = (Invoke-Az ad app credential reset `
                --id $ClientId `
                --append `
                --years 2 `
                --display-name "LAPS Portal Easy Auth – $secretDate" `
                --query password `
                -o tsv `
                --only-show-errors)
            Write-Ok 'Client secret generated (valid 2 years)'
        } catch {
            if ($_ -match 'policy' -or $_ -match 'Credential type not allowed') {
                Write-Fail 'Could not create client secret – blocked by an Entra ID App Management Policy.'
                Write-Host '  → In Azure Portal: Entra ID → Enterprise Applications → Security → App Management Policies'
                Write-Host '    Disable "Block password credentials for applications" or exempt this app.'
                Write-Host ''
                Write-Host '  Once resolved, re-run and pass the manually created secret:'
                Write-Host "  .\infra\deploy.ps1 -Project $Project -Secret '<your-secret>'"
                exit 1
            }
            throw
        }
    }

    # ── Bicep deployment (single pass – all params known upfront) ──────────────
    Write-Host '  Deploying Bicep infrastructure…'
    $BicepParams = @(
        "projectName=$Project",
        "location=$Location",
        "swaLocation=$SwaLocation",
        "resourceGroupName=$ResourceGroup",
        "authClientId=$ClientId",
        "authClientSecret=$ClientSecret"
    )
    if ($CustomDomain) { $BicepParams += "customDomain=$CustomDomain" }

    $BicepArgs = @(
        'deployment', 'sub', 'create',
        '--location', $Location,
        '--template-file', "$ScriptDir/main.bicep",
        '--name', $DeployName,
        '--output', 'none'
    )
    Invoke-Az @BicepArgs --parameters @BicepParams
    Write-Ok 'Bicep deployment complete'

    # Collect outputs
    Write-Host '  Reading deployment outputs…'
    $BackendUrl      = Get-DeploymentOutput $DeployName 'backendUrl'
    $FrontendUrl     = Get-DeploymentOutput $DeployName 'frontendUrl'
    $MiPrincipalId   = Get-DeploymentOutput $DeployName 'managedIdentityPrincipalId'
    $DeploymentToken = (Invoke-Az staticwebapp secrets list `
        --name $SwaName `
        --resource-group $ResourceGroup `
        --query 'properties.apiKey' -o tsv)

    Write-Ok 'Outputs collected'
    Write-Host "  Client ID   : $ClientId"
    Write-Host "  Backend URL : $BackendUrl"
    Write-Host "  Frontend URL: $FrontendUrl"

} else {
    Write-Step 'Step 3/9 – Skipping Bicep deployment (–SkipInfra)'

    Write-Host "  Looking up App Registration '$AppDisplayName'…"
    $ClientId = (az ad app list --display-name $AppDisplayName --query '[0].appId' -o tsv 2>$null)
    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        Write-Fail "App Registration '$AppDisplayName' not found. Has the project been deployed yet?"
        exit 1
    }

    try {
        $BackendUrl      = Get-DeploymentOutput $DeployName 'backendUrl'
        $FrontendUrl     = Get-DeploymentOutput $DeployName 'frontendUrl'
        $MiPrincipalId   = Get-DeploymentOutput $DeployName 'managedIdentityPrincipalId'
        $DeploymentToken = (Invoke-Az staticwebapp secrets list `
            --name $SwaName `
            --resource-group $ResourceGroup `
            --query 'properties.apiKey' -o tsv)
        Write-Ok 'Existing deployment values loaded'
    } catch {
        Write-Fail "Could not read deployment outputs. Has '$DeployName' been deployed yet?"
        exit 1
    }
}

# ── Step 4: Microsoft Graph permissions ───────────────────────────────────────

Write-Step 'Step 4/9 – Assigning Microsoft Graph permissions to Managed Identity'

if ([string]::IsNullOrWhiteSpace($MiPrincipalId)) {
    Write-Fail 'Managed Identity principal ID is empty – cannot assign Graph permissions.'
    Write-Fail 'Check that the Function App has a system-assigned Managed Identity and the Bicep output managedIdentityPrincipalId is set.'
    exit 1
}

$GraphAppId       = '00000003-0000-0000-c000-000000000000'
$GraphSpObjectId  = (Invoke-Az ad sp show --id $GraphAppId --query id -o tsv)

function Set-GraphRole([string]$RoleName) {
    $roleId = (Invoke-Az ad sp show `
        --id $GraphAppId `
        --query "appRoles[?value=='$RoleName'].id | [0]" `
        -o tsv)

    if (-not $roleId) {
        Write-Warn "App role '$RoleName' not found – skipping"
        return
    }

    # Check if already assigned
    $existing = az rest `
        --method GET `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MiPrincipalId/appRoleAssignments" `
        --query "value[?appRoleId=='$roleId'].id | [0]" `
        -o tsv 2>$null

    if ($existing) {
        Write-Ok "$RoleName  (already assigned)"
        return
    }

    # Write body to temp file to avoid PowerShell quoting issues with --body
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        @{
            principalId = $MiPrincipalId
            resourceId  = $GraphSpObjectId
            appRoleId   = $roleId
        } | ConvertTo-Json -Compress | Set-Content $bodyFile -Encoding utf8 -NoNewline

        az rest `
            --method POST `
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MiPrincipalId/appRoleAssignments" `
            --headers 'Content-Type=application/json' `
            --body "@$bodyFile" `
            --output none

        if ($LASTEXITCODE -ne 0) { throw "Failed to assign Graph role $RoleName" }
        Write-Ok "$RoleName  (assigned)"
    } finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

Set-GraphRole 'Device.Read.All'
Set-GraphRole 'DeviceLocalCredential.Read.All'
Set-GraphRole 'Directory.Read.All'

# ── Step 5: Backend deployment ────────────────────────────────────────────────

if (-not $SkipBackend) {
    Write-Step 'Step 5/9 – Deploying backend (Azure Functions)'

    Write-Host '  Installing npm dependencies…'
    Push-Location $BackendDir
    try {
        npm install --omit=dev
        if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
        Write-Ok 'npm dependencies installed'
    } finally {
        Pop-Location
    }

    Write-Host '  Creating deployment package…'
    $zipFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "$FuncAppName-deploy.zip")
    if (Test-Path $zipFile) { Remove-Item $zipFile -Force }
    Compress-Archive -Path "$BackendDir\*" -DestinationPath $zipFile
    $sizeMb = [Math]::Round((Get-Item $zipFile).Length / 1MB, 1)
    Write-Ok "Package created ($sizeMb MB)"

    # Upload to blob storage and set WEBSITE_RUN_FROM_PACKAGE.
    # Avoids slow/unreliable Kudu SCM endpoint for Linux Function Apps.
    Write-Host '  Looking up storage account…'
    $StorageAccountName = (az storage account list `
        --resource-group $ResourceGroup `
        --query '[0].name' -o tsv 2>$null)
    $StorageKey = (az storage account keys list `
        --account-name $StorageAccountName `
        --resource-group $ResourceGroup `
        --query '[0].value' -o tsv)

    $containerName = 'func-deployments'
    $blobName      = "$FuncAppName-$(Get-Date -Format 'yyyyMMddHHmmss').zip"
    $expiry        = (Get-Date).AddYears(2).ToString('yyyy-MM-ddTHH:mm:ssZ')

    az storage container create `
        --name $containerName `
        --account-name $StorageAccountName `
        --account-key $StorageKey `
        --output none 2>$null

    Write-Host "  Uploading package to blob storage ($sizeMb MB)…"
    Invoke-Az storage blob upload `
        --account-name $StorageAccountName `
        --account-key $StorageKey `
        --container-name $containerName `
        --name $blobName `
        --file $zipFile `
        --overwrite `
        --output none
    Remove-Item $zipFile -ErrorAction SilentlyContinue
    Write-Ok 'Package uploaded to blob storage'

    $sasUrl = (Invoke-Az storage blob generate-sas `
        --account-name $StorageAccountName `
        --account-key $StorageKey `
        --container-name $containerName `
        --name $blobName `
        --permissions r `
        --expiry $expiry `
        --full-uri `
        -o tsv)

    Write-Host '  Configuring Function App (WEBSITE_RUN_FROM_PACKAGE)…'
    # Use Invoke-RestMethod instead of az CLI so the SAS URL (which contains '&')
    # is passed as a PowerShell string and never interpreted by cmd.exe.
    $armBase    = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FuncAppName"
    $apiVer     = '2022-03-01'
    $armToken   = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
    $armHeaders = @{ Authorization = "Bearer $armToken"; 'Content-Type' = 'application/json' }

    # GET existing settings (POST to /list returns unmasked values)
    $currentProps = (Invoke-RestMethod -Method POST `
        -Uri "${armBase}/config/appsettings/list?api-version=$apiVer" `
        -Headers $armHeaders).properties

    # Merge WEBSITE_RUN_FROM_PACKAGE in, preserving all existing settings
    $settingsHash = [ordered]@{}
    if ($currentProps) {
        $currentProps.PSObject.Properties | ForEach-Object { $settingsHash[$_.Name] = $_.Value }
    }
    $settingsHash['WEBSITE_RUN_FROM_PACKAGE'] = $sasUrl

    # PUT – the SAS URL is in the request body, never on the command line
    Invoke-RestMethod -Method PUT `
        -Uri "${armBase}/config/appsettings?api-version=$apiVer" `
        -Headers $armHeaders `
        -Body (@{ properties = $settingsHash } | ConvertTo-Json -Depth 5) | Out-Null

    Write-Ok "Backend deployed to $FuncAppName – Function App will restart automatically"
} else {
    Write-Step 'Step 5/9 – Skipping backend deployment (–SkipBackend)'
}

# ── Step 6: Generate authConfig.js ───────────────────────────────────────────

Write-Step 'Step 6/9 – Generating frontend configuration (authConfig.js)'

$authConfigPath    = Join-Path $FrontendDir 'authConfig.js'
$generatedComment  = "// Generated by deploy.ps1 on $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)"

$authConfigContent = @"
$generatedComment
// DO NOT commit this file – it is listed in .gitignore.
// Re-run deploy.ps1 to regenerate, or edit manually for local testing.

window.LAPS_CONFIG = {
  msalClientId: '$ClientId',
  tenantId:     '$TenantId',
  apiBaseUrl:   '$BackendUrl',
  apiScope:     'api://$ClientId/access_as_user',
  passwordTimeout:        60,
  justificationMinLength: 10,
};
"@

Set-Content -Path $authConfigPath -Value $authConfigContent -Encoding utf8
Write-Ok "authConfig.js written to $authConfigPath"

# ── Step 7: Frontend deployment ───────────────────────────────────────────────

if (-not $SkipFrontend) {
    Write-Step 'Step 7/9 – Deploying frontend (Static Web App)'

    Write-Host "  Deploying to $SwaName…"
    swa deploy `
        --app-location $FrontendDir `
        --deployment-token $DeploymentToken `
        --env production

    Write-Ok "Frontend deployed to $SwaName"
} else {
    Write-Step 'Step 7/9 – Skipping frontend deployment (–SkipFrontend)'
}

# ── Step 8: Update App Registration redirect URIs ─────────────────────────────

Write-Step 'Step 8/9 – Updating App Registration redirect URIs'

$currentUrisJson = (az ad app show --id $ClientId --query 'spa.redirectUris' -o json 2>$null)
$currentUris     = if ($currentUrisJson) { $currentUrisJson | ConvertFrom-Json } else { @() }

if ($currentUris -contains $FrontendUrl) {
    Write-Ok "Redirect URI already registered: $FrontendUrl"
} else {
    # Use az rest PATCH with a temp file to avoid PowerShell quoting issues
    $AppObjectId = (az ad app show --id $ClientId --query id -o tsv 2>$null)
    $newUriList  = @($currentUris) + @($FrontendUrl)
    $patchFile   = [System.IO.Path]::GetTempFileName()
    try {
        @{ spa = @{ redirectUris = $newUriList } } |
            ConvertTo-Json -Compress |
            Set-Content $patchFile -Encoding utf8 -NoNewline

        az rest --method PATCH `
            --uri "https://graph.microsoft.com/v1.0/applications/$AppObjectId" `
            --headers 'Content-Type=application/json' `
            --body "@$patchFile" `
            --output none

        if ($LASTEXITCODE -ne 0) { throw 'PATCH failed' }
        Write-Ok "Redirect URI added: $FrontendUrl"
    } catch {
        Write-Warn "Could not update redirect URIs automatically – add $FrontendUrl manually in Azure Portal"
    } finally {
        Remove-Item $patchFile -ErrorAction SilentlyContinue
    }
}

# ── Step 9: Admin Consent ─────────────────────────────────────────────────────

Write-Step 'Step 9/9 – Admin Consent for User.Read delegated permission'

try {
    Invoke-Az ad app permission grant `
        --id $ClientId `
        --api $GraphAppId `
        --scope 'User.Read' `
        --output none | Out-Null
    Write-Ok 'Admin consent granted for User.Read'
} catch {
    Write-Warn 'Could not grant admin consent automatically – grant it in Azure Portal → App registrations → API permissions → Grant admin consent'
}

# ── Deployment summary ────────────────────────────────────────────────────────

Write-Header 'Deployment Complete'

Write-Host ""
Write-Host "  Frontend URL  : $FrontendUrl"  -ForegroundColor White
Write-Host "  Backend URL   : $BackendUrl"   -ForegroundColor White
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor White
Write-Host "  Function App  : $FuncAppName"  -ForegroundColor White
Write-Host "  Static Web App: $SwaName"      -ForegroundColor White
Write-Host "  Client ID     : $ClientId"     -ForegroundColor White
Write-Host "  Tenant ID     : $TenantId"     -ForegroundColor White
Write-Host ""

if ($ClientSecret) {
    Write-Host '  ⚠ Save this client secret – it cannot be retrieved again:' -ForegroundColor Yellow
    Write-Host "    $ClientSecret"                                             -ForegroundColor Yellow
    Write-Host ""
}

Write-Host '  Next steps:'                                                              -ForegroundColor Green
Write-Host "  1. Open $FrontendUrl in a browser"
Write-Host '  2. Sign in with an Entra ID account'
Write-Host '  3. Verify your managed devices appear in the list'
Write-Host '  4. Test LAPS password retrieval'
Write-Host ""
Write-Host "  For re-deployments: .\infra\deploy.ps1 -Project $Project -Secret '<your-secret>'"
Write-Host ""
Write-Host '  🚨 Mandatory Access Controls – do this before going live:' -ForegroundColor Red
Write-Host ""
Write-Host '  1️⃣  Entra ID Assignment Enforcement (who is allowed)'      -ForegroundColor White
Write-Host '     By default, every user in your tenant can sign in.'
Write-Host '     Open Entra ID → Enterprise Applications → your portal app'
Write-Host "     Set 'Assignment required?' → Yes"
Write-Host '     Assign a dedicated security group (e.g. SG-LAPS-Self-Service)'
Write-Host '     → Only group members can reach the portal.'
Write-Host ""
Write-Host '  2️⃣  Conditional Access (under which conditions)'           -ForegroundColor White
Write-Host '     Create a Conditional Access Policy targeting the same group:'
Write-Host '     🔐 Require Multi-Factor Authentication'
Write-Host '     🖥️  Require a compliant or hybrid-joined device (if applicable)'
Write-Host '     🌍 Restrict by location or country'
Write-Host '     🚫 Block legacy and risky authentication attempts'
Write-Host '     📊 Monitor sign-ins for anomalous activity'
Write-Host ""
Write-Host '     Together these two layers ensure that only authorized, verified,'
Write-Host '     and policy-compliant sessions can request LAPS credentials.'
Write-Host ""
