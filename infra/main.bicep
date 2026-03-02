targetScope = 'subscription'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Project name used as prefix for all resource names (e.g. laps-prod)')
@minLength(3)
@maxLength(36)
param projectName string

@description('Azure region for all resources')
param location string = 'germanywestcentral'

@description('Azure region for the Static Web App. Available regions: westus2, centralus, eastus2, westeurope, eastasia')
@allowed(['westus2', 'centralus', 'eastus2', 'westeurope', 'eastasia'])
param swaLocation string = 'westeurope'

@description('Resource group name (default: rg-<projectName>)')
param resourceGroupName string = 'rg-${projectName}'

@description('Optional custom domain for the frontend Static Web App (leave empty to skip)')
param customDomain string = ''

@description('Client ID of the Entra ID App Registration – created by deploy.sh before this Bicep runs')
param authClientId string

@secure()
@description('Client secret for the Entra ID App Registration – used by Easy Auth on the Function App')
param authClientSecret string = ''

// ── Variables ─────────────────────────────────────────────────────────────────

var tenantId = subscription().tenantId

var tags = {
  project: projectName
}

// ── Resource Group ────────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ── Module: Monitoring (Log Analytics + Application Insights) ─────────────────

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    projectName: projectName
    location: location
    tags: tags
  }
}

// ── Module: Storage Account (Function App runtime + Audit log table) ──────────

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    projectName: projectName
    location: location
    tags: tags
  }
}

// ── Module: App Service Plan (Linux, B1) ──────────────────────────────────────

module appServicePlan 'modules/appServicePlan.bicep' = {
  name: 'appServicePlan'
  scope: rg
  params: {
    projectName: projectName
    location: location
    tags: tags
  }
}

// ── Module: Frontend Static Web App ──────────────────────────────────────────

module staticWebApp 'modules/staticwebapp.bicep' = {
  name: 'staticWebApp'
  scope: rg
  params: {
    projectName: projectName
    location: swaLocation
    customDomain: customDomain
    tags: tags
  }
}

// ── Module: Backend Function App ──────────────────────────────────────────────
// authClientId is created by deploy.sh via CLI before this Bicep deployment runs.

module functionApp 'modules/functionapp.bicep' = {
  name: 'functionApp'
  scope: rg
  params: {
    projectName: projectName
    location: location
    appServicePlanId: appServicePlan.outputs.planId
    storageAccountName: storage.outputs.storageAccountName
    auditTableName: storage.outputs.auditTableName
    appInsightsConnectionString: monitoring.outputs.connectionString
    tenantId: tenantId
    authClientId: authClientId
    authClientSecret: authClientSecret
    allowedOrigins: [staticWebApp.outputs.defaultHostname]
    tags: tags
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('HTTPS URL of the backend Function App')
output backendUrl string = functionApp.outputs.url

@description('HTTPS URL of the frontend Static Web App')
output frontendUrl string = staticWebApp.outputs.defaultHostname

@description('Object ID of the Function App system-assigned Managed Identity')
output managedIdentityPrincipalId string = functionApp.outputs.principalId
