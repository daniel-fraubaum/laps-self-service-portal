/**
 * lib/telemetry.js – Application Insights custom event tracking.
 *
 * Call initialize() once at startup (src/index.js) to boot the SDK.
 * After that, trackPasswordAccess() and trackDeviceListAccess() can be called
 * from any function handler.
 *
 * Custom event schema
 * ───────────────────
 * LapsPasswordAccess
 *   userId            Entra Object ID of the requesting user
 *   userPrincipalName UPN of the requesting user
 *   deviceId          Entra Device Object ID
 *   deviceName        Device display name (empty string on failure)
 *   justification     User-provided reason for the access
 *   success           'true' | 'false'
 *   failReason        Why the access failed (empty string on success)
 *   timestamp         ISO 8601 UTC
 *
 * LapsDeviceListAccess
 *   userId            Entra Object ID
 *   userPrincipalName UPN
 *   deviceCount       Number of devices returned
 *   timestamp         ISO 8601 UTC
 */

'use strict';

const appInsights = require('applicationinsights');

let _initialized = false;

/**
 * Initialize the Application Insights SDK.
 * Safe to call multiple times – only initializes once.
 * No-op if APPLICATIONINSIGHTS_CONNECTION_STRING is not set (local dev without AI).
 */
function initialize() {
  if (_initialized) return;
  const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;
  if (!connectionString) {
    console.warn('[telemetry] APPLICATIONINSIGHTS_CONNECTION_STRING not set – custom events disabled.');
    return;
  }

  appInsights
    .setup(connectionString)
    .setAutoDependencyCorrelation(true)
    .setAutoCollectRequests(true)
    .setAutoCollectPerformance(true, true)
    .setAutoCollectExceptions(true)
    .setAutoCollectDependencies(true)
    .setAutoCollectConsole(false)
    .setUseDiskRetryCaching(true)
    .setSendLiveMetrics(false)
    .start();

  _initialized = true;
}

/** @returns {import('applicationinsights').TelemetryClient | null} */
function getClient() {
  return _initialized ? appInsights.defaultClient : null;
}

// ---------------------------------------------------------------------------
// Typed tracking helpers
// ---------------------------------------------------------------------------

/**
 * Track a LAPS password retrieval attempt (success or failure).
 *
 * @param {object} params
 * @param {string}  params.oid           Entra Object ID
 * @param {string}  params.upn           User Principal Name
 * @param {string}  params.deviceId      Entra Device Object ID
 * @param {string}  [params.deviceName]  Device display name
 * @param {string}  params.justification User-provided reason
 * @param {boolean} params.success       Whether the password was returned
 * @param {string}  [params.failReason]  Failure reason code
 */
function trackPasswordAccess({ oid, upn, deviceId, deviceName, justification, success, failReason }) {
  const client = getClient();
  if (!client) return;

  client.trackEvent({
    name: 'LapsPasswordAccess',
    properties: {
      userId:            oid,
      userPrincipalName: upn,
      deviceId,
      deviceName:        deviceName ?? '',
      justification,
      success:           String(success),
      failReason:        failReason ?? '',
      timestamp:         new Date().toISOString(),
    },
  });
}

/**
 * Track a device list retrieval.
 *
 * @param {object} params
 * @param {string} params.oid         Entra Object ID
 * @param {string} params.upn         User Principal Name
 * @param {number} params.deviceCount Number of devices returned
 */
function trackDeviceListAccess({ oid, upn, deviceCount }) {
  const client = getClient();
  if (!client) return;

  client.trackEvent({
    name: 'LapsDeviceListAccess',
    properties: {
      userId:            oid,
      userPrincipalName: upn,
      deviceCount:       String(deviceCount),
      timestamp:         new Date().toISOString(),
    },
  });
}

module.exports = { initialize, trackPasswordAccess, trackDeviceListAccess };
