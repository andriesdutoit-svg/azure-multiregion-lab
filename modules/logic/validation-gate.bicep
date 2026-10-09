targetScope = 'subscription'

param shouldBlockDeployment bool
param deploymentBlockMessage string

output gatePassed bool = shouldBlockDeployment
  ? fail(deploymentBlockMessage)
  : true
