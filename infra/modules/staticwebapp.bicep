@description('Project name used as prefix for resource names')
param projectName string

@description('Azure region')
param location string

@description('Optional custom domain (leave empty to skip custom domain resource)')
param customDomain string = ''

@description('Resource tags')
param tags object

// ── Azure Static Web App (Frontend) ──────────────────────────────────────────

resource staticWebApp 'Microsoft.Web/staticSites@2023-01-01' = {
  name: '${projectName}-swa'
  location: location
  tags: tags
  sku: {
    // Standard tier required for custom domains and private endpoints
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    stagingEnvironmentPolicy: 'Disabled'
    allowConfigFileUpdates: true
    enterpriseGradeCdnStatus: 'Disabled'
  }
}

// ── Custom Domain (optional) ──────────────────────────────────────────────────
// The CNAME record must exist in your DNS provider before this resource is deployed.

resource customDomainResource 'Microsoft.Web/staticSites/customDomains@2023-01-01' = if (!empty(customDomain)) {
  parent: staticWebApp
  name: customDomain
  properties: {}
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Full HTTPS URL of the Static Web App default hostname')
output defaultHostname string = 'https://${staticWebApp.properties.defaultHostname}'

output staticWebAppName string = staticWebApp.name
output staticWebAppId string = staticWebApp.id
