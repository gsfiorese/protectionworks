param location string = resourceGroup().location

@description('Lowercase letters & numbers only; 3–22 chars. Used as a prefix for resource names.')
@minLength(3)
@maxLength(22)
param baseName string

// Dev-only; pass a value at deploy time. Leaving empty avoids the linter warning about hardcoded defaults.
@secure()
param sqlAdminPassword string = ''

var sqlAdminUser = 'sqladmin'

// ---------- Storage ----------
resource sa 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: '${baseName}sa'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobC 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: '${sa.name}/default/docs'
  properties: {
    publicAccess: 'None'
  }
}

// ---------- Application Insights ----------
resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name: '${baseName}-appi'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// ---------- Key Vault ----------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: '${baseName}-kv'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enablePurgeProtection: true
    accessPolicies: [] // we’ll grant the API MI below
  }
}

// ---------- App Service Plan (Linux) ----------
resource plan 'Microsoft.Web/serverfarms@2022-09-01' = {
  name: '${baseName}-plan'
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  } // use S1 for prod
  properties: {
    reserved: true // required for Linux
  }
}

// ---------- API App (Linux, .NET 8) ----------
resource api 'Microsoft.Web/sites@2022-09-01' = {
  name: '${baseName}-api'
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: plan.id
    siteConfig: {
      linuxFxVersion: 'DOTNET|8.0'
      appSettings: [
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appi.properties.ConnectionString
        }
      ]
    }
  }
}

// ---------- SQL Server + DB ----------
resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: '${baseName}-sql'
  location: location
  properties: {
    administratorLogin: sqlAdminUser
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource db 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  name: '${baseName}-db'
  parent: sqlServer
  location: location
  sku: {
    name: 'Basic'
    tier: 'Basic'
  } // dev tier
}

// Allow Azure services (incl. App Service) to reach SQL during dev
resource sqlAllowAzure 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = {
  name: 'AllowAllWindowsAzureIps'
  parent: sqlServer
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ---------- Static Web App (Free) ----------
@description('Static Web Apps supported regions are limited; eastus2 is safe. Adjust if you prefer.')
param swaLocation string = 'eastus2'

resource swa 'Microsoft.Web/staticSites@2022-09-01' = {
  name: '${baseName}-swa'
  location: swaLocation
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    buildProperties: {}
  }
}

// ---------- KV Secrets (dev bootstrap) ----------
resource kvc1 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'SqlConnection'
  parent: kv
  properties: {
    // Linter notes hardcoded env URL; acceptable for AzureCloud.
    value: 'Server=tcp:${sqlServer.name}.database.windows.net,1433;Database=${db.name};User ID=${sqlAdminUser};Password=${sqlAdminPassword};Encrypt=true;'
  }
}

resource kvc2 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  name: 'StorageAccountKey'
  parent: kv
  properties: {
    value: sa.listKeys().keys[0].value
  }
}

// ---------- Give API (managed identity) read access to KV secrets ----------
resource kvAccess 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: 'add'
  parent: kv
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: api.identity.principalId
        permissions: {
          secrets: [
            'get'
            'list'
          ]
        }
      }
    ]
  }
}

// ---------- Outputs ----------
output apiName string = api.name
output kvName string = kv.name
output storageName string = sa.name
output swaName string = swa.name
