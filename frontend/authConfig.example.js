// =============================================================================
// LAPS Self-Service Portal – Deployment Configuration Template
// =============================================================================
//
// 1. Copy this file to authConfig.js  (same directory)
// 2. Fill in the values from your Bicep deployment outputs
// 3. authConfig.js is gitignored – never commit it with real values
//
// See docs/CONFIGURATION.md for detailed instructions.
// =============================================================================

window.LAPS_CONFIG = {

  // ── Required ────────────────────────────────────────────────────────────────

  // App Registration (client) ID  [CLI: az ad app list --filter "displayName eq '{app-name}'" --query "[0].appId" -o tsv]
  msalClientId: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',

  // Entra ID Tenant ID
  tenantId: 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx',

  // Backend Function App base URL – no trailing slash  [Bicep output: backendUrl]
  apiBaseUrl: 'https://<project-name>-func.azurewebsites.net',

  // OAuth 2.0 scope  →  api://{msalClientId}/access_as_user
  apiScope: 'api://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/access_as_user',

  // ── Optional (defaults shown) ───────────────────────────────────────────────

  passwordTimeout:        60,   // seconds the password stays visible
  justificationMinLength: 10,   // minimum characters in the justification field

};
