/**
 * jsdom ships TextDecoder but not TextEncoder. importWizard decodes uploaded
 * bytes itself (TextDecoder with fatal:true) rather than using readAsText, so
 * specs need TextEncoder to build the fixture bytes in the first place.
 */
const { TextEncoder, TextDecoder } = require('util');

if (typeof global.TextEncoder === 'undefined') {
    global.TextEncoder = TextEncoder;
}
if (typeof global.TextDecoder === 'undefined') {
    global.TextDecoder = TextDecoder;
}
