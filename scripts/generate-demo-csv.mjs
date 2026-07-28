/**
 * Generates demo-data/FinTech_Summit_2026_Attendees.csv — a 48-row attendee
 * list aligned with scripts/seed-demo-data.apex so the import wizard shows all
 * five classifications:
 *   - UPDATE          (Emily: new title; James: new mobile)
 *   - UNCHANGED       (Robert, Laura, Anna)
 *   - COMPANY_CHANGE  (Sophie: Globex → Acme Corp)
 *   - NEW             (Zoë Müller-Sørensen + 37 generated attendees)
 *   - SKIPPED         (1 missing email, 1 missing last name)
 *   plus 1 in-file duplicate email (deduped client-side, last wins)
 *
 * Written UTF-8 with a BOM and CRLF line endings. The Zoë Müller-Sørensen row is
 * deliberately non-ASCII so the demo exercises the wizard's UTF-8 decoding.
 *
 * Run:  node scripts/generate-demo-csv.mjs
 */
import { mkdirSync, writeFileSync } from 'fs';

const rows = [
    ['First Name', 'Last Name', 'Email', 'Title', 'Company', 'Mobile'],
    // UPDATE: title changed vs seed (Manager → Senior Manager)
    ['Emily', 'Carter', 'emily.carter@acmecorp.example', 'Senior Manager', 'Acme Corp', ''],
    // UPDATE: mobile added
    ['James', 'Mueller', 'j.mueller@nordbank.example', 'Director', 'Nordbank AG', '+49 151 2345 678'],
    // UNCHANGED
    ['Robert', 'Kim', 'robert.kim@acmecorp.example', 'SVP, Operations', 'Acme Corp', ''],
    ['Laura', 'Chen', 'laura.chen@acmeins.example', 'VP, Finance', 'Acme Insurance', ''],
    ['Anna', 'Kowalski', 'a.kowalski@nordbank.example', 'Associate', 'Nordbank AG', ''],
    // COMPANY_CHANGE: seed has Sophie at Globex
    ['Sophie', 'Laurent', 'sophie.laurent@globex.example', 'CMO', 'Acme Corp', ''],
    // SKIPPED: missing email
    ['Ben', 'Nomail', '', 'Analyst', 'Acme Corp', ''],
    // SKIPPED: new contact without last name
    ['Solo', '', 'solo@startup.example', 'Founder', 'Startup GmbH', ''],
    // In-file duplicate: first occurrence is superseded by the next row (last wins)
    ['Dana', 'Duplicate', 'dana@dupe.example', 'Old Title', 'Acme Corp', ''],
    ['Dana', 'Duplicate', 'dana@dupe.example', 'New Title', 'Acme Corp', ''],
    // NEW with non-ASCII name — proves the file is read as UTF-8 end to end
    ['Zoë', 'Müller-Sørensen', 'z.muller@newcolabs.example', 'Head of Analytics', 'NewCo Labs', '']
];

const first = ['David', 'Nina', 'Oscar', 'Priya', 'Lukas', 'Maya', 'Ethan', 'Clara', 'Hugo', 'Ines',
    'Felix', 'Zoe', 'Adam', 'Lena', 'Marco', 'Julia', 'Tom', 'Elsa', 'Noah', 'Vera',
    'Leo', 'Ida', 'Max', 'Ruth', 'Sam', 'Eva', 'Karl', 'Amy', 'Paul', 'Mia',
    'Erik', 'Sara', 'Ivan', 'Lucy', 'Owen', 'Rosa', 'Nils', 'Faye'];
const companies = ['NewCo Labs', 'Vertex Capital', 'Bluepeak Bank', 'Helios Insurance', 'Quantumsoft', 'PoC Unmatched Ltd'];
for (let i = 0; i < 37; i++) {
    const f = first[i];
    rows.push([f, 'Attendee' + (i + 1), `${f.toLowerCase()}.a${i + 1}@prospect.example`,
        i % 3 === 0 ? 'Director' : 'Manager', companies[i % companies.length], '']);
}

function csvCell(value) {
    const text = String(value);
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

const csv = rows.map((row) => row.map(csvCell).join(',')).join('\r\n');

mkdirSync('demo-data', { recursive: true });
writeFileSync('demo-data/FinTech_Summit_2026_Attendees.csv', '\uFEFF' + csv, 'utf8');
console.log(`Wrote demo-data/FinTech_Summit_2026_Attendees.csv (${rows.length - 1} data rows)`);
