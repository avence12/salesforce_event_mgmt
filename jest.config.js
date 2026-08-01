'use strict';

const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    setupFiles: ['<rootDir>/force-app/test/jest-setup.js'],
    // Deliberately no moduleNameMapper for `@salesforce/*`: @lwc/jest-transformer
    // already rewrites those imports, giving each Apex method its own jest.fn().
    // Mapping them all to one shared stub module made every Apex method in a
    // component the *same* mock, so stubbing one silently rebound the others.
    // Specs opt in per method with jest.mock(path, factory, { virtual: true }).
    collectCoverageFrom: [
        'force-app/main/default/lwc/**/*.js',
        '!force-app/main/default/lwc/**/__tests__/**'
    ],
    coverageReporters: ['text', 'text-summary', 'lcov', 'json-summary'],
    // The bar the gauntlet enforces for the JS side, set just under what the
    // suite currently achieves so a regression fails the build rather than
    // quietly eroding. Apex coverage is a separate, org-side number measured by
    // `sf apex run test --code-coverage`.
    coverageThreshold: {
        global: {
            statements: 99,
            branches: 97,
            functions: 98,
            lines: 99
        }
    }
};
