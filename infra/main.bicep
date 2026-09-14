targetScope = 'resourceGroup'

@minLength(1)
param location string

@minLength(2)
@maxLength(32)
param containerAppName string

@minLength(2)
@maxLength(60)
param containerAppEnvironmentName string

param reuseContainerAppEnvironment bool = false
param logAnalyticsWorkspaceName string = ''
param logAnalyticsResourceGroup string = resourceGroup().name
param reuseLogAnalyticsWorkspace bool = false

@minLength(1)
param allowedIpCidrs string[]

@secure()
@minLength(1)
param applicationInsightsConnectionString string

@minLength(1)
@maxLength(30)
param revisionSuffix string

@minLength(1)
param repository string

var collectorImage = loadYamlContent('../docker-compose.yml').services.otelcol.image
var collectorConfig = loadTextContent('../otel-collector-config.yaml')
var tags = {
	'managed-by': 'github-actions'
	repository: repository
}

resource existingWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
	scope: resourceGroup(logAnalyticsResourceGroup)
	name: logAnalyticsWorkspaceName
}

resource workspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' = if (!reuseContainerAppEnvironment && !reuseLogAnalyticsWorkspace) {
	name: logAnalyticsWorkspaceName
	location: location
	tags: tags
	properties: {
		sku: {
			name: 'PerGB2018'
		}
		retentionInDays: 30
		features: {
			enableLogAccessUsingOnlyResourcePermissions: true
		}
	}
}

resource existingEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' existing = {
	name: containerAppEnvironmentName
}

resource environment 'Microsoft.App/managedEnvironments@2025-01-01' = if (!reuseContainerAppEnvironment) {
	name: containerAppEnvironmentName
	location: location
	tags: tags
	properties: {
		appLogsConfiguration: {
			destination: 'log-analytics'
			logAnalyticsConfiguration: {
				customerId: reuseLogAnalyticsWorkspace ? existingWorkspace.properties.customerId : workspace!.properties.customerId
				sharedKey: reuseLogAnalyticsWorkspace ? existingWorkspace.listKeys().primarySharedKey : workspace!.listKeys().primarySharedKey
			}
		}
		workloadProfiles: [
			{
				name: 'Consumption'
				workloadProfileType: 'Consumption'
			}
		]
	}
}

resource collector 'Microsoft.App/containerApps@2025-01-01' = {
	name: containerAppName
	location: location
	tags: tags
	properties: {
		environmentId: reuseContainerAppEnvironment ? existingEnvironment.id : environment!.id
		workloadProfileName: 'Consumption'
		configuration: {
			activeRevisionsMode: 'Single'
			ingress: {
				external: true
				targetPort: 4318
				transport: 'http'
				allowInsecure: false
				ipSecurityRestrictions: [for (cidr, index) in allowedIpCidrs: {
					name: 'client-${index}'
					action: 'Allow'
					ipAddressRange: cidr
				}]
			}
			secrets: [
				{
					name: 'appinsights-connection-string'
					value: applicationInsightsConnectionString
				}
			]
		}
		template: {
			revisionSuffix: revisionSuffix
			terminationGracePeriodSeconds: 60
			containers: [
				{
					name: 'otelcol'
					image: collectorImage
					args: [
						'--config=env:OTELCOL_CONFIG'
					]
					env: [
						{
							name: 'OTELCOL_CONFIG'
							value: collectorConfig
						}
						{
							name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
							secretRef: 'appinsights-connection-string'
						}
					]
					resources: {
						cpu: json('0.25')
						memory: '0.5Gi'
					}
					probes: [
						{
							type: 'Startup'
							tcpSocket: {
								port: 4318
							}
							periodSeconds: 10
							timeoutSeconds: 2
							failureThreshold: 30
						}
						{
							type: 'Readiness'
							tcpSocket: {
								port: 4318
							}
							periodSeconds: 10
							timeoutSeconds: 2
							failureThreshold: 3
						}
						{
							type: 'Liveness'
							tcpSocket: {
								port: 4318
							}
							periodSeconds: 30
							timeoutSeconds: 2
							failureThreshold: 3
						}
					]
				}
			]
			scale: {
				minReplicas: 1
				maxReplicas: 1
			}
		}
	}
}

output endpoint string = 'https://${collector.properties.configuration.ingress!.fqdn}'
output image string = collectorImage
output revision string = '${containerAppName}--${revisionSuffix}'
