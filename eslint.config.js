'use strict';

const { readFileSync } = require('fs');
const { join } = require('path');

const lwcConfig = require('@salesforce/eslint-config-lwc/recommended');

// The LWC config keys its rules off the API version the org will compile against,
// so it stays in sync with sfdx-project.json instead of drifting on its own.
const { sourceApiVersion } = JSON.parse(
    readFileSync(join(__dirname, 'sfdx-project.json'), 'utf8')
);

module.exports = [
    {
        ignores: ['node_modules/**', '.sfdx/**', '.sf/**', 'coverage/**']
    },
    ...lwcConfig,
    {
        files: ['force-app/main/default/lwc/**/*.js'],
        languageOptions: {
            sourceType: 'module',
            parserOptions: {
                requireConfigFile: false,
                ecmaVersion: 'latest'
            }
        },
        settings: {
            lwc: { apiVersion: Number(sourceApiVersion) }
        }
    },
    {
        // Jest specs live beside the component under __tests__ and need the globals.
        files: ['force-app/main/default/lwc/**/__tests__/**/*.js'],
        languageOptions: {
            globals: {
                describe: 'readonly',
                it: 'readonly',
                test: 'readonly',
                expect: 'readonly',
                beforeEach: 'readonly',
                afterEach: 'readonly',
                beforeAll: 'readonly',
                afterAll: 'readonly',
                jest: 'readonly'
            }
        },
        rules: {
            // Specs legitimately reach into internals to assert on them.
            '@lwc/lwc/no-unexpected-wire-adapter-usages': 'off',
            // The rules below guard *component* code. A spec is not a component:
            // it drives the real document, and its flush helper must await a
            // timer per tick — that sequencing is the point, not a smell.
            '@lwc/lwc/no-async-operation': 'off',
            '@lwc/lwc/no-document-query': 'off',
            '@lwc/lwc/no-inner-html': 'off',
            'no-await-in-loop': 'off'
        }
    }
];
