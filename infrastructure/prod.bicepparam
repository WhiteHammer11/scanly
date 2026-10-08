
using './main.bicep'

param storageAccountName = 'scanlyavdija2026prod'
param acrName = 'scanlyavdijaacr2026prod'
param documentIntelligenceEndpoint = 'https://cloud25ai-di-4d98c.cognitiveservices.azure.com/'

param containerAppName = 'scanly-api-prod'
param containerAppsEnvironmentName = 'scanly-env-prod'

param minReplicas = 2
param maxReplicas = 5

param acrSku = 'Standard'
param storageSku = 'Standard_GRS'

param imageTag = '3c119ad'

param documentIntelligenceKey = readEnvironmentVariable('SCANLY_DI_KEY')
