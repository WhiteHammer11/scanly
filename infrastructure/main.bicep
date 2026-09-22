
param storageAccountName string
param acrName string

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: resourceGroup().location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
  }
}

resource invoicesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: '${storageAccount.name}/default/invoices'
  properties: {
    publicAccess: 'None'
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: resourceGroup().location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'scanly-env'
  location: resourceGroup().location
  properties: {}
}

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'scanly-api'
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
    }

    template: {
      containers: [
        {
          name: 'scanly-api'
          image: '${acr.name}.azurecr.io/scanly-api:latest'
          resources: {
            cpu: 1
            memory: '2Gi'
          }
        }
      ]

      scale: {
        minReplicas: 2
        maxReplicas: 5

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

resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, containerApp.id, 'AcrPull')
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

resource storageBlobDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, containerApp.id, 'StorageBlobDataContributor')
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

output storageUrl string = 'https://${storageAccount.name}.${environment().suffixes.storage}/'
