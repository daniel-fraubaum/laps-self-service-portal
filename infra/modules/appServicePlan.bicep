@description('Project name used as prefix for resource names')
param projectName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

// ── App Service Plan (Linux, B1) ──────────────────────────────────────────────
// B1 Basic tier on Linux – shared across the Function App.
// Upgrade to P1v3 or higher for production workloads with consistent traffic.

resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${projectName}-plan'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true  // Required for Linux
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the App Service Plan')
output planId string = appServicePlan.id

@description('Name of the App Service Plan')
output planName string = appServicePlan.name
