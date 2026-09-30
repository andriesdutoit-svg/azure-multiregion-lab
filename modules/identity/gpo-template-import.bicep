targetScope = 'resourceGroup'

param dcVmName string
param domainName string
param directoryModel string
param reconciliationToken string

var serverAdministrationBackupXml =
  loadTextContent('./templates/gpo/server-administration/backup/Backup.xml')

var serverAdministrationReportXml =
  loadTextContent('./templates/gpo/server-administration/backup/gpreport.xml')

var serverAdministrationGroupsXml =
  loadTextContent('./templates/gpo/server-administration/backup/DomainSysvol/GPO/Machine/Preferences/Groups/Groups.xml')

var clientAdministrationBackupXml =
  loadTextContent('./templates/gpo/client-administration/backup/Backup.xml')

var clientAdministrationReportXml =
  loadTextContent('./templates/gpo/client-administration/backup/gpreport.xml')

var clientAdministrationGroupsXml =
  loadTextContent('./templates/gpo/client-administration/backup/DomainSysvol/GPO/Machine/Preferences/Groups/Groups.xml')

var importGpoTemplatesScript =
    loadTextContent('./scripts/Import-GPO-Templates.ps1')

var gpoTemplatePackage = {
  serverAdministration: {
    backupXml: serverAdministrationBackupXml
    reportXml: serverAdministrationReportXml
    groupsXml: serverAdministrationGroupsXml
  }

  clientAdministration: {
    backupXml: clientAdministrationBackupXml
    reportXml: clientAdministrationReportXml
    groupsXml: clientAdministrationGroupsXml
  }
}
