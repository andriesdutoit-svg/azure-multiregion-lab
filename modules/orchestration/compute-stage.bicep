targetScope = 'subscription'

// ========================================
// COMPUTE STAGE ORCHESTRATION
// ========================================

param regionKeys array

param subnetMap array

// subnetMap contract:
//
// [
//   {
//     regionKey: 'westeurope'
//     dcSubnetId: '...'
//     jumpboxSubnetId: '...'
//     serverSubnetId: '...'
//     clientSubnetId: '...'
//   }
// ]
