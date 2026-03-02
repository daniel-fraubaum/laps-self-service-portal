/**
 * lib/graph.js – Microsoft Graph API client using DefaultAzureCredential.
 *
 * In production the Function App's system-assigned Managed Identity is used
 * automatically (no secrets required). Locally, DefaultAzureCredential falls
 * back to Azure CLI, VS Code, or environment credentials.
 *
 * Required application permissions on the Managed Identity:
 *   Device.Read.All                  – enumerate user's registered devices
 *   DeviceLocalCredential.Read.All   – read LAPS passwords (beta endpoint)
 *   Directory.Read.All               – device lookup / ownership verification
 *
 * See docs/deployment.md (Step 3) for the az CLI commands to assign these.
 */

'use strict';

const { DefaultAzureCredential }    = require('@azure/identity');
const { Client }                    = require('@microsoft/microsoft-graph-client');
const { TokenCredentialAuthenticationProvider } = require(
  '@microsoft/microsoft-graph-client/authProviders/azureTokenCredentials',
);

const GRAPH_ENDPOINT = process.env.GRAPH_API_ENDPOINT ?? 'https://graph.microsoft.com';

// Singleton credential – reused across warm invocations to avoid redundant
// IMDS/token-endpoint round-trips on every request
let _credential = null;

function getCredential() {
  if (!_credential) _credential = new DefaultAzureCredential();
  return _credential;
}

function getGraphClient() {
  const authProvider = new TokenCredentialAuthenticationProvider(getCredential(), {
    scopes: [`${GRAPH_ENDPOINT}/.default`],
  });
  return Client.initWithMiddleware({ authProvider, baseUrl: GRAPH_ENDPOINT });
}

// ---------------------------------------------------------------------------
// Device list
// ---------------------------------------------------------------------------

/**
 * @typedef {object} DeviceInfo
 * @property {string}  id              - Entra Device Object ID (used for LAPS lookup)
 * @property {string}  name            - Device display name
 * @property {string}  operatingSystem - e.g. "Windows"
 * @property {boolean} isManaged       - Whether the device is Intune-managed
 * @property {string|null} lastSignIn  - ISO 8601 date of last sign-in activity
 */

/**
 * Return all Entra ID registered devices for the given user.
 * Uses GET /v1.0/users/{userId}/registeredDevices (requires Device.Read.All).
 *
 * Note: registeredDevices is a reference/navigation property – Graph does not
 * support $filter on it. We fetch all registered devices and filter client-side.
 *
 * @param {string} userId  Entra Object ID of the authenticated user
 * @returns {Promise<DeviceInfo[]>}
 */
async function getRegisteredDevices(userId) {
  const client = getGraphClient();
  const result = await client
    .api(`/users/${userId}/registeredDevices`)
    .select('id,displayName,operatingSystem,isManaged,approximateLastSignInDateTime')
    .get();

  const SUPPORTED_OS = new Set(['windows', 'macos']);

  return (result?.value ?? [])
    .filter(d => SUPPORTED_OS.has((d.operatingSystem ?? '').toLowerCase()))
    .map(d => ({
      id:              d.id,
      name:            d.displayName ?? '',
      operatingSystem: d.operatingSystem ?? '',
      isManaged:       d.isManaged ?? false,
      lastSignIn:      d.approximateLastSignInDateTime ?? null,
    }));
}

// ---------------------------------------------------------------------------
// Device ownership verification
// ---------------------------------------------------------------------------

/**
 * Verify that a device (by Entra Device ID) is in the user's registered devices.
 * Returns the matching device object if owned, or null if not.
 *
 * @param {string} deviceId  Entra Device Object ID
 * @param {string} userId    Entra Object ID of the authenticated user
 * @returns {Promise<DeviceInfo|null>}
 */
async function findOwnedDevice(deviceId, userId) {
  const devices = await getRegisteredDevices(userId);
  return devices.find(d => d.id === deviceId) ?? null;
}

// ---------------------------------------------------------------------------
// LAPS password retrieval
// ---------------------------------------------------------------------------

/**
 * @typedef {object} LapsCredential
 * @property {string}      deviceName   - Display name of the device
 * @property {string}      accountName  - Local administrator account name
 * @property {string}      password     - Plaintext local administrator password
 * @property {string|null} expiresAt    - ISO 8601 expiry date, or null if not set
 */

/**
 * Retrieve the LAPS credential for the given device.
 * Uses a two-step approach:
 *   1. GET /v1.0/directory/deviceLocalCredentials?$select=id,deviceName
 *      to find the deviceLocalCredentialInfo id matching the device display name.
 *   2. GET /v1.0/directory/deviceLocalCredentials/{credInfoId}?$select=credentials,deviceName
 *      to fetch the actual credential.
 *
 * The deviceLocalCredentialInfo id is NOT necessarily the Entra Device Object ID —
 * it is a separate identifier that must be obtained from the listing endpoint.
 * We use native fetch (Node 18+) instead of the Graph SDK client to avoid
 * the SDK's version-override mechanism conflicting with a custom baseUrl.
 *
 * Requires: DeviceLocalCredential.Read.All
 *
 * @param {string} deviceName  Display name of the device (from registeredDevices)
 * @returns {Promise<LapsCredential>}
 * @throws {Error} err.code === 'NOT_FOUND' if no credential is stored
 */
async function getLapsPassword(deviceName) {
  const tokenResponse = await getCredential().getToken(`${GRAPH_ENDPOINT}/.default`);
  const authHeader = { Authorization: `Bearer ${tokenResponse.token}` };

  // ── Step 1: find the deviceLocalCredentialInfo id by device display name ──
  const listUrl = `${GRAPH_ENDPOINT}/v1.0/directory/deviceLocalCredentials?$select=id,deviceName`;
  const listRes = await fetch(listUrl, { headers: authHeader });
  let listResult;
  try   { listResult = await listRes.json(); }
  catch { listResult = {}; }

  if (!listRes.ok) {
    const msg = listResult?.error?.message ?? `HTTP ${listRes.status}`;
    throw new Error(`Failed to list deviceLocalCredentials: ${msg}`);
  }

  const credInfo = (listResult?.value ?? []).find(
    c => c.deviceName?.toLowerCase() === deviceName?.toLowerCase()
  );

  if (!credInfo) {
    const notFound = new Error(`No LAPS credential found for device "${deviceName}".`);
    notFound.code = 'NOT_FOUND';
    throw notFound;
  }

  // ── Step 2: fetch the full credential using the deviceLocalCredentialInfo id ─
  const url = `${GRAPH_ENDPOINT}/v1.0/directory/deviceLocalCredentials/${credInfo.id}?$select=credentials,deviceName`;
  const res = await fetch(url, { headers: authHeader });

  let result;
  try {
    result = await res.json();
  } catch {
    result = {};
  }

  if (res.status === 404) {
    const notFound = new Error('No LAPS credential found for this device.');
    notFound.code = 'NOT_FOUND';
    throw notFound;
  }

  if (!res.ok) {
    const msg = result?.error?.message ?? `HTTP ${res.status}`;
    const err = new Error(msg);
    err.statusCode = res.status;
    throw err;
  }

  const credential = result?.credentials?.[0];
  if (!credential) {
    const notFound = new Error('No LAPS credential found for this device.');
    notFound.code = 'NOT_FOUND';
    throw notFound;
  }

  // The password is returned base64-encoded; decode to plaintext
  const password = credential.passwordBase64
    ? Buffer.from(credential.passwordBase64, 'base64').toString('utf8')
    : (credential.password ?? '');

  return {
    deviceName:  result.deviceName ?? '',
    accountName: credential.accountName ?? '',
    password,
    expiresAt:  credential.passwordExpirationDateTime
              ?? credential.backupDateTime
              ?? null,
  };
}

module.exports = { getRegisteredDevices, findOwnedDevice, getLapsPassword };
