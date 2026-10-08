
@description('Name of the Azure Storage Account')
param storageAccountName string

@description('Name of the Azure Container Registry')
param acrName string

@description('Document Intelligence endpoint')
param documentIntelligenceEndpoint string

@description('Container App name')
param containerAppName string

@description('Container Apps Environment name')
param containerAppsEnvironmentName string

@description('Minimum number of replicas')
@minValue(1)
param minReplicas int

@description('Maximum number of replicas')
@minValue(1)
param maxReplicas int

@description('Azure Container Registry SKU')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param acrSku string

@description('Storage Account SKU')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_ZRS'
])
param storageSku string

@description('Document Intelligence API key. Supply securely at deployment time.')
@secure()
param documentIntelligenceKey string

@description('Container image tag')
param imageTag string = 'latest'

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: storageSku
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
  }
}

// Private Blob container
resource invoicesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storageAccount.name}/default/invoices'
  properties: {
    publicAccess: 'None'
  }
}

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: resourceGroup().location
  sku: {
    name: acrSku
  }
  properties: {
    adminUserEnabled: false
  }
}

// Container Apps Environment
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: resourceGroup().location
  properties: {}
}

// Scanly API
resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: resourceGroup().location

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    managedEnvironmentId: containerAppsEnvironment.id

    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }

      registries: [
        {
          server: '${acr.name}.azurecr.io'
          identity: 'system'
        }
      ]

      secrets: [
        {
          name: 'azure-di-key'
          value: documentIntelligenceKey
        }
      ]
    }

    template: {
      containers: [
        {
          name: 'scanly-api'
          image: '${acr.name}.azurecr.io/scanly-api:${imageTag}'

          env: [
            {
              name: 'AZURE_DI_ENDPOINT'
              value: documentIntelligenceEndpoint
            }
            {
              name: 'AZURE_DI_KEY'
              secretRef: 'azure-di-key'
            }
            {
              name: 'AZURE_STORAGE_URL'
              value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}/'
            }
          ]

          resources: {
            cpu: 1
            memory: '2Gi'
          }

          probes: [
            {
              type: 'Liveness'
              tcpSocket: {
                port: 8080
              }
              initialDelaySeconds: 0
              periodSeconds: 10
              timeoutSeconds: 5
              failureThreshold: 3
              successThreshold: 1
            }
            {
              type: 'Readiness'
              tcpSocket: {
                port: 8080
              }
              initialDelaySeconds: 0
              periodSeconds: 5
              timeoutSeconds: 5
              failureThreshold: 48
              successThreshold: 1
            }
            {
              type: 'Startup'
              tcpSocket: {
                port: 8080
              }
              initialDelaySeconds: 1
              periodSeconds: 1
              timeoutSeconds: 3
              failureThreshold: 240
              successThreshold: 1
            }
          ]
        }
      ]

      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas

        rules: [
          {
            name: 'http-scaling'
            http: {
              metadata: {
                concurrentRequests: '10'
              }
            }
          }
        ]
      }
    }
  }
}

// ACR Pull permission

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: containerAppName == 'scanly-api'
    ? '1488a37c-20b3-4412-a7b6-b4a5b8937e7a'
    : guid(acr.id, containerAppName, 'AcrPull')

  scope: acr

  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    )
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Blob Storage permission

resource storageBlobDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: containerAppName == 'scanly-api'
    ? '5d91956d-b5fd-46d8-95fc-9a4410c2373f'
    : guid(storageAccount.id, containerAppName, 'StorageBlobDataContributor')

  scope: storageAccount

  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: containerApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}



// Outputs
output storageUrl string = 'https://${storageAccount.name}.blob.${environment().suffixes.storage}/'
output containerAppNameOutput string = containerApp.name
