@description('Project name used as prefix for resource names')
param projectName string

@description('Azure region')
param location string

@description('Resource ID of the App Service Plan (Linux B1)')
param appServicePlanId string

@description('Name of the Storage Account used for AzureWebJobsStorage and audit logging')
param storageAccountName string

@description('Name of the Azure Table used for audit logging')
param auditTableName string

@description('Application Insights connection string')
param appInsightsConnectionString string

@description('Entra ID Tenant ID (written to TENANT_ID app setting)')
param tenantId string

@description('Client ID of the App Registration (for Easy Auth audience validation)')
param authClientId string

@description('Client secret for Easy Auth. Written to MICROSOFT_PROVIDER_AUTHENTICATION_SECRET.')
@secure()
param authClientSecret string

@description('Allowed CORS origins – typically the Static Web App URL')
param allowedOrigins array

@description('Resource tags')
param tags object

// ── Existing Storage Account reference ───────────────────────────────────────
// Connection string is constructed here to avoid exposing secrets in module outputs.

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' existing = {
  name: storageAccountName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${az.environment().suffixes.storage}'

// ── Function App ──────────────────────────────────────────────────────────────

resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${projectName}-func'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    // System-assigned Managed Identity – used to call Microsoft Graph without stored secrets
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlanId
    reserved: true      // Required for Linux
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|24'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        allowedOrigins: allowedOrigins
        supportCredentials: true
      }
      appSettings: [
        // ── Azure Functions runtime ─────────────────────────────────────────
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~24'
        }

        // ── Monitoring ──────────────────────────────────────────────────────
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }

        // ── Easy Auth – Entra ID client secret ──────────────────────────────
        // Referenced by authsettingsV2 clientSecretSettingName below.
        // Set this after obtaining the secret from the App Registration.
        {
          name: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
          value: authClientSecret
        }

        // ── Application settings ────────────────────────────────────────────
        {
          name: 'TENANT_ID'
          value: tenantId
        }
        {
          // Used by lib/auth.js for local JWT verification (jwks-rsa audience check)
          name: 'AUTH_CLIENT_ID'
          value: authClientId
        }
        {
          name: 'AUDIT_STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        {
          name: 'AUDIT_TABLE_NAME'
          value: auditTableName
        }
        {
          name: 'GRAPH_API_ENDPOINT'
          value: 'https://graph.microsoft.com'
        }
        {
          name: 'JUSTIFICATION_MIN_LENGTH'
          value: '10'
        }
        {
          name: 'PASSWORD_DISPLAY_SECONDS'
          value: '60'
        }
      ]
    }
  }
}

// ── Easy Auth (Entra ID built-in authentication) ──────────────────────────────
// Validates JWT tokens before requests reach the function code.
// Unauthenticated requests return HTTP 401 without reaching any function code.

resource authSettings 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          // Reference the secret from the app setting – never hardcode secrets here
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
          openIdIssuer: 'https://sts.windows.net/${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${authClientId}'
            authClientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        // Do not persist tokens server-side – stateless auth
        enabled: false
      }
    }
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id

@description('HTTPS URL of the Function App (base URL for all API calls)')
output url string = 'https://${functionApp.properties.defaultHostName}'

@description('Object ID of the system-assigned Managed Identity – assign Graph permissions to this ID')
output principalId string = functionApp.identity.principalId
