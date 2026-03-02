/**
 * lib/audit.js – Persistent audit log in Azure Table Storage.
 *
 * Complements Application Insights (real-time monitoring) with a durable,
 * queryable record of every LAPS access attempt.
 *
 * Table : LapsAuditLog  (configurable via AUDIT_TABLE_NAME env var)
 * PartitionKey : YYYY-MM-DD UTC date of the event
 * RowKey       : UUID v4 (unique event ID, returned as auditId)
 *
 * Failures are swallowed and logged to stderr so that an audit storage
 * outage never blocks a legitimate password retrieval.
 */

'use strict';

const { TableClient } = require('@azure/data-tables');
const { v4: uuidv4 }  = require('uuid');

const CONNECTION_STRING = process.env.AUDIT_STORAGE_CONNECTION_STRING;
const TABLE_NAME        = process.env.AUDIT_TABLE_NAME ?? 'LapsAuditLog';

let _client = null;

function getTableClient() {
  if (!_client) {
    _client = TableClient.fromConnectionString(CONNECTION_STRING, TABLE_NAME);
  }
  return _client;
}

/**
 * @typedef {object} AuditEntry
 * @property {string}  oid           Entra Object ID of the requesting user
 * @property {string}  upn           User Principal Name
 * @property {string}  deviceId      Entra Device Object ID
 * @property {string}  [deviceName]  Device display name
 * @property {string}  justification User-provided reason
 * @property {'SUCCESS'|'DENIED'|'ERROR'} action
 * @property {string}  [denialReason]
 * @property {string}  [clientIp]
 * @property {string}  [userAgent]
 */

/**
 * Write an audit record to Azure Table Storage.
 * Returns the generated audit ID (UUID v4) for inclusion in API responses.
 *
 * @param {AuditEntry} entry
 * @returns {Promise<string>} auditId
 */
async function writeAuditLog(entry) {
  const now          = new Date();
  const partitionKey = now.toISOString().slice(0, 10);  // YYYY-MM-DD
  const rowKey       = uuidv4();

  const entity = {
    partitionKey,
    rowKey,
    Timestamp:         now.toISOString(),
    UserId:            entry.oid           ?? '',
    UserPrincipalName: entry.upn           ?? '',
    DeviceId:          entry.deviceId      ?? '',
    DeviceName:        entry.deviceName    ?? '',
    Justification:     entry.justification ?? '',
    Action:            entry.action        ?? 'UNKNOWN',
    DenialReason:      entry.denialReason  ?? '',
    ClientIp:          entry.clientIp      ?? '',
    UserAgent:         entry.userAgent     ?? '',
  };

  try {
    await getTableClient().createEntity(entity);
  } catch (err) {
    // Non-fatal: audit failure must not affect the API response
    console.error('[audit] Failed to write audit log entry:', err.message, { partitionKey, rowKey });
  }

  return rowKey;
}

module.exports = { writeAuditLog };
