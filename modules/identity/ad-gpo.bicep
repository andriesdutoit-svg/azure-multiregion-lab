targetScope = 'resourceGroup'

param dcVmName string
param domainName string
param directoryModel string

param reconciliationToken string

var serverAdministrationBackupXml = loadTextContent('./templates/gpo/{B2F4D556-0972-4279-A56B-72971037BEEB}/Backup.xml')

var serverAdministrationReportXml = loadTextContent('./templates/gpo/{B2F4D556-0972-4279-A56B-72971037BEEB}/gpreport.xml')

var serverAdministrationGroupsXml = loadTextContent('./templates/gpo/{B2F4D556-0972-4279-A56B-72971037BEEB}/DomainSysvol/GPO/Machine/Preferences/Groups/Groups.xml')

var clientAdministrationBackupXml = loadTextContent('./templates/gpo/{BAE14512-0FC9-4990-90C1-58FB81F7D4E7}/Backup.xml')

var clientAdministrationReportXml = loadTextContent('./templates/gpo/{BAE14512-0FC9-4990-90C1-58FB81F7D4E7}/gpreport.xml')

var clientAdministrationGroupsXml = loadTextContent('./templates/gpo/{BAE14512-0FC9-4990-90C1-58FB81F7D4E7}/DomainSysvol/GPO/Machine/Preferences/Groups/Groups.xml')

var importGpoTemplateScript = loadTextContent('./scripts/Import-GPO-Templates.ps1')

resource dcVm 'Microsoft.Compute/virtualMachines@2022-08-01' existing = {
  name: dcVmName
}

resource configureGpo 'Microsoft.Compute/virtualMachines/runCommands@2023-09-01' = {
  parent: dcVm
  name: 'configure-gpo'

  location: resourceGroup().location

  properties: {
    treatFailureAsDeploymentFailure: true

    source: {
      script: importGpoTemplateScript
    }

    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'DirectoryModel'
        value: directoryModel
      }
      {
        name: 'ReconciliationToken'
        value: reconciliationToken
      }
      {
        name: 'ServerAdministrationBackupXml'
        value: serverAdministrationBackupXml
      }
      {
        name: 'ServerAdministrationReportXml'
        value: serverAdministrationReportXml
      }
      {
        name: 'ServerAdministrationGroupsXml'
        value: serverAdministrationGroupsXml
      }
      {
        name: 'ClientAdministrationBackupXml'
        value: clientAdministrationBackupXml
      }
      {
        name: 'ClientAdministrationReportXml'
        value: clientAdministrationReportXml
      }
      {
        name: 'ClientAdministrationGroupsXml'
        value: clientAdministrationGroupsXml
      }
    ]
  }
}
