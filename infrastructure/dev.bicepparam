
using './main.bicep'

param storageAccountName = 'scanlyavdija2026'
param acrName = 'scanlyavdijaacr2026'
param documentIntelligenceEndpoint = 'https://cloud25ai-di-4d98c.cognitiveservices.azure.com/'

param containerAppName = 'scanly-api'
param containerAppsEnvironmentName = 'scanly-env'

param minReplicas = 2
param maxReplicas = 3

param acrSku = 'Basic'
param storageSku = 'Standard_LRS'

param imageTag = 'e7de126'

param documentIntelligenceKey = readEnvironmentVariable('SCANLY_DI_KEY')

// documentIntelligenceKey is supplied securely during deployment.
// Never store the API key in this file.
