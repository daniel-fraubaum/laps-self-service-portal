@description('Project name used as prefix for resource names')
param projectName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

// Storage account names must be lowercase, alphanumeric, 3–24 characters.
// Strip hyphens from projectName, take at most 9 chars, append a unique suffix.
var storageAccountName = '${take(toLower(replace(projectName, '-', '')), 9)}${uniqueString(resourceGroup().id)}'

// ── Storage Account ───────────────────────────────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-04-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    // Shared key access required by the Azure Functions runtime (AzureWebJobsStorage)
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      // All traffic allowed – required when running on App Service Plan without VNet integration
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ── Blob Service ──────────────────────────────────────────────────────────────

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// ── Table Service + Audit Log Table ───────────────────────────────────────────

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-04-01' = {
  parent: storageAccount
  name: 'default'
}

resource auditTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-04-01' = {
  parent: tableService
  name: 'LapsAuditLog'
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output auditTableName string = auditTable.name
