/**
 * src/index.js – Function App entry point (Azure Functions v4 programming model).
 *
 * Application Insights is initialized here, before any function handlers are
 * registered, so that all outbound dependencies and exceptions are tracked.
 *
 * Function registration happens through side effects of the require() calls below.
 */

'use strict';

const { initialize } = require('./lib/telemetry');

// Boot Application Insights before importing anything that makes network calls
initialize();

// Register HTTP functions
require('./functions/myDevices');
require('./functions/lapsPassword');
