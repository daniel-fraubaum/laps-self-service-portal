/**
 * POST /api/laps-password
 *
 * Retrieves the LAPS (local administrator) password for a device after:
 *   1. Authenticating the caller via JWT / Easy Auth
 *   2. Validating the request body (deviceId + justification)
 *   3. Verifying the device is owned by the authenticated user (Graph API)
 *   4. Fetching the LAPS credential from Microsoft Graph
 *
 * Every attempt (success or failure) is:
 *   - Tracked as a custom event in Application Insights
 *   - Written to Azure Table Storage (persistent audit log)
 *
 * The password is NEVER persisted anywhere – it only exists in the response body.
 *
 * Request body:
 *   { "deviceId": "<entra-device-object-id>", "justification": "..." }
 *
 * Response 200:
 *   { "deviceName": "LAPTOP-ABC", "password": "...", "expiresAt": "...", "auditId": "..." }
 *
 * Response 400: Missing or invalid body
 * Response 401: Not authenticated
 * Response 403: Device not owned by the requesting user
 * Response 404: No LAPS password stored for this device
 * Response 500: Graph API error
 */

'use strict';

const { app }                          = require('@azure/functions');
const { getCallerIdentity, AuthError } = require('../lib/auth');
const { findOwnedDevice, getLapsPassword } = require('../lib/graph');
const { trackPasswordAccess }          = require('../lib/telemetry');
const { writeAuditLog }                = require('../lib/audit');

const MIN_JUSTIFICATION = parseInt(process.env.JUSTIFICATION_MIN_LENGTH ?? '10', 10);

app.http('laps-password', {
  methods:   ['POST'],
  route:     'laps-password',
  authLevel: 'anonymous',  // Token validation handled by lib/auth.js (Easy Auth or JWKS)

  handler: async (request, context) => {
    context.log('POST /api/laps-password');

    const clientIp  = request.headers.get('x-forwarded-for') ?? '';
    const userAgent = request.headers.get('user-agent') ?? '';

    // ── 1. Authenticate ────────────────────────────────────────────────────
    let caller;
    try {
      caller = await getCallerIdentity(request);
    } catch (err) {
      const status = err instanceof AuthError ? err.status : 401;
      return {
        status,
        jsonBody: { error: 'UNAUTHORIZED', message: err.message ?? 'Authentication required.' },
      };
    }

    // ── 2. Validate request body ────────────────────────────────────────────
    let body;
    try {
      body = await request.json();
    } catch {
      return {
        status:   400,
        jsonBody: { error: 'INVALID_BODY', message: 'Request body must be valid JSON.' },
      };
    }

    const { deviceId, justification } = body ?? {};

    if (!deviceId || typeof deviceId !== 'string') {
      return {
        status:   400,
        jsonBody: { error: 'MISSING_DEVICE_ID', message: 'deviceId is required.' },
      };
    }

    const trimmedJustification = typeof justification === 'string' ? justification.trim() : '';

    if (trimmedJustification.length < MIN_JUSTIFICATION) {
      return {
        status:   400,
        jsonBody: {
          error:   'JUSTIFICATION_TOO_SHORT',
          message: `Justification must be at least ${MIN_JUSTIFICATION} characters.`,
        },
      };
    }

    context.log(`User ${caller.upn} requesting LAPS for device ${deviceId}`);

    // ── 3. Verify device ownership (backend-enforced "only my device" rule) ──
    let device;
    try {
      device = await findOwnedDevice(deviceId, caller.oid);
    } catch (err) {
      context.log('Graph API error during ownership check:', err.message);
      trackPasswordAccess({
        oid: caller.oid, upn: caller.upn, deviceId,
        justification: trimmedJustification, success: false, failReason: 'OWNERSHIP_CHECK_ERROR',
      });
      return {
        status:   500,
        jsonBody: { error: 'GRAPH_ERROR', message: 'Failed to verify device ownership.' },
      };
    }

    if (!device) {
      context.log(`Device ${deviceId} not found in registered devices of ${caller.upn}`);
      trackPasswordAccess({
        oid: caller.oid, upn: caller.upn, deviceId,
        justification: trimmedJustification, success: false, failReason: 'DEVICE_NOT_OWNED',
      });
      await writeAuditLog({
        oid: caller.oid, upn: caller.upn, deviceId, deviceName: '',
        justification: trimmedJustification, action: 'DENIED',
        denialReason: 'DEVICE_NOT_OWNED', clientIp, userAgent,
      });
      return {
        status:   403,
        jsonBody: { error: 'DEVICE_NOT_OWNED', message: 'This device is not registered to your account.' },
      };
    }

    // ── 4. Retrieve LAPS password from Microsoft Graph ─────────────────────
    let lapsResult;
    try {
      lapsResult = await getLapsPassword(device.name);
    } catch (err) {
      if (err.code === 'NOT_FOUND') {
        trackPasswordAccess({
          oid: caller.oid, upn: caller.upn, deviceId, deviceName: device.name,
          justification: trimmedJustification, success: false, failReason: 'NO_LAPS_CREDENTIAL',
        });
        await writeAuditLog({
          oid: caller.oid, upn: caller.upn, deviceId, deviceName: device.name,
          justification: trimmedJustification, action: 'DENIED',
          denialReason: 'NO_LAPS_CREDENTIAL', clientIp, userAgent,
        });
        return {
          status:   404,
          jsonBody: { error: 'NO_LAPS_CREDENTIAL', message: 'No LAPS password is stored for this device.' },
        };
      }

      context.log('Graph API error retrieving LAPS password:', err.message);
      trackPasswordAccess({
        oid: caller.oid, upn: caller.upn, deviceId, deviceName: device.name,
        justification: trimmedJustification, success: false, failReason: 'LAPS_API_ERROR',
      });
      return {
        status:   500,
        jsonBody: { error: 'GRAPH_ERROR', message: 'Failed to retrieve LAPS password.' },
      };
    }

    // ── 5. Log success ──────────────────────────────────────────────────────
    trackPasswordAccess({
      oid: caller.oid, upn: caller.upn, deviceId,
      deviceName:    lapsResult.deviceName,
      justification: trimmedJustification,
      success:       true,
    });

    const auditId = await writeAuditLog({
      oid: caller.oid, upn: caller.upn, deviceId,
      deviceName:    lapsResult.deviceName,
      justification: trimmedJustification,
      action:        'SUCCESS',
      clientIp,
      userAgent,
    });

    context.log(`Password delivered for ${lapsResult.deviceName} (audit: ${auditId})`);

    // ── 6. Return – password is never persisted beyond this response ────────
    return {
      status: 200,
      jsonBody: {
        deviceName:  lapsResult.deviceName,
        accountName: lapsResult.accountName,  // local admin username
        password:    lapsResult.password,      // plaintext, never logged or stored
        expiresAt:   lapsResult.expiresAt,
        auditId,
      },
    };
  },
});
