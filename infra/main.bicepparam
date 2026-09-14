using './main.bicep'

param location = readEnvironmentVariable('AZURE_LOCATION', '<location>')
param containerAppName = readEnvironmentVariable('CONTAINER_APP_NAME', '<container-app-name>')
param containerAppEnvironmentName = readEnvironmentVariable('CONTAINER_APP_ENVIRONMENT_NAME', '<environment-name>')
param reuseContainerAppEnvironment = bool(readEnvironmentVariable('REUSE_CONTAINER_APP_ENVIRONMENT', 'false'))
param logAnalyticsWorkspaceName = readEnvironmentVariable('LOG_ANALYTICS_WORKSPACE_NAME', '')
param logAnalyticsResourceGroup = readEnvironmentVariable('LOG_ANALYTICS_RESOURCE_GROUP', readEnvironmentVariable('AZURE_RESOURCE_GROUP', '<resource-group>'))
param reuseLogAnalyticsWorkspace = bool(readEnvironmentVariable('REUSE_LOG_ANALYTICS_WORKSPACE', 'false'))
param allowedIpCidrs = json(readEnvironmentVariable('ALLOWED_IP_CIDRS', '["<public-ip>/32"]'))
param applicationInsightsConnectionString = readEnvironmentVariable('APPLICATIONINSIGHTS_CONNECTION_STRING', '<runtime-connection-string>')
param revisionSuffix = readEnvironmentVariable('REVISION_SUFFIX', '<revision-suffix>')
param repository = readEnvironmentVariable('GITHUB_REPOSITORY', '<owner>/<repository>')
