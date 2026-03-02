/**
 * lib/auth.js – Caller identity extraction and JWT validation.
 *
 * Two authentication paths:
 *
 *  1. Easy Auth (production)
 *     The Function App's built-in authentication (configured in Bicep) validates
 *     the Bearer token before the request reaches function code. The verified
 *     claims are forwarded as the base64-encoded X-MS-CLIENT-PRINCIPAL header.
 *     This path decodes that header – no additional crypto needed.
 *
 *  2. Direct Bearer token (local development)
 *     When Easy Auth is not present, the Bearer token from the Authorization
 *     header is cryptographically verified against Entra ID's public JWKS.
 *     Requires TENANT_ID and AUTH_CLIENT_ID environment variables.
 */

'use strict';

const jwt      = require('jsonwebtoken');
const jwksRsa  = require('jwks-rsa');

const TENANT_ID = process.env.TENANT_ID;
const CLIENT_ID = process.env.AUTH_CLIENT_ID;

// JWKS client – caches public keys for 10 minutes to avoid repeated HTTP calls
const jwksClient = jwksRsa({
  jwksUri:       `https://login.microsoftonline.com/${TENANT_ID}/discovery/v2.0/keys`,
  cache:         true,
  cacheMaxEntries: 5,
  cacheMaxAge:   10 * 60 * 1000,
  rateLimit:     true,
});

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * @typedef {object} CallerIdentity
 * @property {string} oid  - Entra ID Object ID (stable, use for Graph calls and audit)
 * @property {string} upn  - User Principal Name (human-readable, use for logging)
 */

/**
 * Extract the verified caller identity from the incoming request.
 *
 * @param {import('@azure/functions').HttpRequest} request
 * @returns {Promise<CallerIdentity>}
 * @throws {AuthError}
 */
async function getCallerIdentity(request) {
  // Path 1: Easy Auth header injected by the Function App infrastructure
  const easyAuthHeader = request.headers.get('x-ms-client-principal');
  if (easyAuthHeader) {
    return decodeEasyAuthPrincipal(easyAuthHeader);
  }

  // Path 2: Raw Bearer token (local development / non-Easy-Auth environments)
  const authHeader = request.headers.get('authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    throw new AuthError(401, 'Missing or invalid Authorization header.');
  }

  return verifyBearerToken(authHeader.slice(7));
}

// ---------------------------------------------------------------------------
// Path 1 – Easy Auth
// ---------------------------------------------------------------------------

function decodeEasyAuthPrincipal(headerValue) {
  let principal;
  try {
    principal = JSON.parse(Buffer.from(headerValue, 'base64').toString('utf8'));
  } catch {
    throw new AuthError(401, 'Failed to decode X-MS-CLIENT-PRINCIPAL header.');
  }

  const claims = principal.claims ?? [];

  /** Find the first non-empty value among the given claim type URIs. */
  const getClaim = (...types) => {
    for (const type of types) {
      const match = claims.find(c => c.typ === type);
      if (match?.val) return match.val;
    }
    return null;
  };

  const oid = getClaim(
    'http://schemas.microsoft.com/identity/claims/objectidentifier',
    'oid',
  );
  const upn = getClaim(
    'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn',
    'upn',
    'preferred_username',
  );

  if (!oid) throw new AuthError(401, 'OID claim missing from token.');

  return { oid, upn: upn ?? '' };
}

// ---------------------------------------------------------------------------
// Path 2 – Direct JWT verification
// ---------------------------------------------------------------------------

async function verifyBearerToken(token) {
  if (!TENANT_ID || !CLIENT_ID) {
    throw new AuthError(500, 'TENANT_ID and AUTH_CLIENT_ID must be set for local JWT validation.');
  }

  // Decode header to extract the key ID (kid) without verifying
  const unverified = jwt.decode(token, { complete: true });
  if (!unverified?.header?.kid) {
    throw new AuthError(401, 'Invalid JWT: missing kid header.');
  }

  // Fetch the matching public key from Entra ID's JWKS endpoint
  let signingKey;
  try {
    const key = await jwksClient.getSigningKey(unverified.header.kid);
    signingKey = key.getPublicKey();
  } catch {
    throw new AuthError(401, 'Failed to retrieve token signing key.');
  }

  // Verify signature, audience, and issuer
  let payload;
  try {
    payload = jwt.verify(token, signingKey, {
      // Accept both the raw client ID and the api:// prefixed audience
      audience: [CLIENT_ID, `api://${CLIENT_ID}`],
      issuer:   `https://sts.windows.net/${TENANT_ID}/`,
    });
  } catch (err) {
    throw new AuthError(401, `Token verification failed: ${err.message}`);
  }

  const oid = payload.oid;
  const upn = payload.preferred_username ?? payload.upn ?? '';

  if (!oid) throw new AuthError(401, 'OID claim missing from token.');

  return { oid, upn };
}

// ---------------------------------------------------------------------------
// AuthError
// ---------------------------------------------------------------------------

class AuthError extends Error {
  /**
   * @param {number} status  HTTP status code (401 or 403)
   * @param {string} message Human-readable error message
   */
  constructor(status, message) {
    super(message);
    this.name = 'AuthError';
    this.status = status;
  }
}

module.exports = { getCallerIdentity, AuthError };
