// ESLint flat config (ESLint 9+)
// Run: npm run lint

'use strict';

const js = require('@eslint/js');

/** @type {import('eslint').Linter.Config[]} */
module.exports = [
  // Base recommended ruleset
  js.configs.recommended,

  // Project-wide settings
  {
    files: ['src/**/*.js'],
    languageOptions: {
      ecmaVersion: 2022,
      sourceType: 'commonjs',
      globals: {
        // Node.js globals
        require:   'readonly',
        module:    'readonly',
        exports:   'readonly',
        __dirname: 'readonly',
        __filename:'readonly',
        process:   'readonly',
        console:   'readonly',
        Buffer:    'readonly',
        setTimeout:'readonly',
        clearTimeout: 'readonly',
        setInterval:  'readonly',
        clearInterval:'readonly',
      },
    },
    rules: {
      // ── Code quality ────────────────────────────────────────────────────
      'no-unused-vars':        ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      'no-console':            'off',      // console.log is used intentionally for Function App logs
      'no-var':                'error',
      'prefer-const':          'error',
      'eqeqeq':                ['error', 'always'],
      'curly':                 ['error', 'all'],
      'no-throw-literal':      'error',
      'no-return-await':       'error',

      // ── Style (light-touch, not enforcing formatting) ────────────────────
      'semi':                  ['error', 'always'],
      'quotes':                ['error', 'single', { avoidEscape: true }],
      'no-trailing-spaces':    'error',
      'eol-last':              'error',
    },
  },

  // Ignore non-source files
  {
    ignores: ['node_modules/**', 'dist/**'],
  },
];
