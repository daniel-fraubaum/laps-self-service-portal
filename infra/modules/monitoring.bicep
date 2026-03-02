@description('Project name used as prefix for resource names')
param projectName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

// ── Log Analytics Workspace ───────────────────────────────────────────────────

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${projectName}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// ── Application Insights (linked to Log Analytics) ────────────────────────────

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${projectName}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    RetentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Application Insights connection string (use as APPLICATIONINSIGHTS_CONNECTION_STRING)')
output connectionString string = appInsights.properties.ConnectionString

@description('Application Insights instrumentation key (legacy, prefer connectionString)')
output instrumentationKey string = appInsights.properties.InstrumentationKey

@description('Log Analytics Workspace resource ID')
output workspaceId string = logAnalyticsWorkspace.id
