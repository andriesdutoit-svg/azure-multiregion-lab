targetScope = 'subscription'

// Converts the validation engine's enforcement decision into a dependency gate.
// No resources are deployed; fail(...) stops dependent stages when blocking is requested.

// 1. Enforcement decision and diagnostic message
param shouldBlockDeployment bool
param deploymentBlockMessage string

// 2. Gate result
// A non-blocking decision succeeds even when the engine reports advisory findings.
output gatePassed bool = shouldBlockDeployment
  ? fail(deploymentBlockMessage)
  : true
