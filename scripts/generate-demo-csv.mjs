/**
 * Generates demo-data/FinTech_Summit_2026_Attendees.csv — an attendee list aligned
 * with scripts/seed-demo-data.apex so the import wizard shows all five R4
 * classifications:
 *   - MATCHED_CONTACT (Emily, Robert, Laura, Anna, James — tagged, nothing else touched)
 *   - MATCHED_LEAD    (Hélène, Anke, Tomas, Priya — the seeded conference guests)
 *   - AMBIGUOUS       (two Sophie Laurents at Globex, no email to separate them)
 *   - NEW_LEAD        (Zoë Müller-Sørensen + the generated attendees)
 *   - SKIPPED         (1 missing last name, 1 missing event)
 *   plus 1 in-file duplicate (same person, same event — collapses)
 *   and 1 stale-company row (Sophie moved) proving an empty narrowing step is skipped
 *
 * Every row carries an Event column: that is what the import records, and a row
 * without one has nothing to tag.
 *
 * Written UTF-8 with a BOM and CRLF line endings. The Zoë Müller-Sørensen and
 * Hélène Dubois rows are deliberately non-ASCII so the demo exercises the wizard's
 * UTF-8 decoding.
 *
 * Run:  node scripts/generate-demo-csv.mjs
 */
import { mkdirSync, writeFileSync } from 'fs';

const EVENT = 'FinTech Summit 2026';

const rows = [
    ['First Name', 'Last Name', 'Email', 'Title', 'Company', 'Mobile', 'Event'],
    // MATCHED_CONTACT on name alone — the title and company in this file are ignored,
    // which is the point: nothing on a Contact is ever written.
    ['Emily', 'Carter', 'emily.carter@acmecorp.example', 'Senior Manager', 'Acme Corp', '', EVENT],
    ['James', 'Mueller', 'j.mueller@nordbank.example', 'Director', 'Nordbank AG', '', EVENT],
    ['Robert', 'Kim', 'robert.kim@acmecorp.example', 'SVP, Operations', 'Acme Corp', '', EVENT],
    ['Laura', 'Chen', 'laura.chen@acmeins.example', 'VP, Finance', 'Acme Insurance', '', EVENT],
    ['Anna', 'Kowalski', 'a.kowalski@nordbank.example', 'Associate', 'Nordbank AG', '', EVENT],
    // Stale company: Sophie is seeded at Globex, the file says Acme Corp. The narrowing
    // step finds nobody, is skipped, and she still matches on name — Open Question 10.
    ['Sophie', 'Laurent', 'sophie.laurent@globex.example', 'CMO', 'Acme Corp', '', EVENT],
    // MATCHED_LEAD: the seeded conference guests, who have no Account and never will.
    ['Hélène', 'Dubois', 'h.dubois@unige.example', 'Professor', 'Université de Genève', '', EVENT],
    ['Anke', 'Weber', 'a.weber@tuberlin.example', 'Professor', 'TU Berlin', '', EVENT],
    [
        'Tomas',
        'Lindqvist',
        't.lindqvist@kth.example',
        'Senior Researcher',
        'KTH Royal Institute',
        '',
        EVENT
    ],
    ['Priya', 'Raman', 'p.raman@techpress.example', 'Editor', 'TechPress Media', '', EVENT],
    // SKIPPED: no last name, so there is nothing to match on
    ['Solo', '', 'solo@startup.example', 'Founder', 'Startup GmbH', '', EVENT],
    // SKIPPED: no event, so there is nothing to tag this person with
    ['Ben', 'Noevent', 'ben@acmecorp.example', 'Analyst', 'Acme Corp', '', ''],
    // In-file duplicate: same person, same event — collapses to one tag
    ['Dana', 'Duplicate', 'dana@dupe.example', 'Analyst', 'Acme Corp', '', EVENT],
    ['Dana', 'Duplicate', 'dana@dupe.example', 'Analyst', 'Acme Corp', '', EVENT],
    // NEW_LEAD with non-ASCII name — proves the file is read as UTF-8 end to end
    [
        'Zoë',
        'Müller-Sørensen',
        'z.muller@newcolabs.example',
        'Head of Analytics',
        'NewCo Labs',
        '',
        EVENT
    ]
];

const first = [
    'David',
    'Nina',
    'Oscar',
    'Priya',
    'Lukas',
    'Maya',
    'Ethan',
    'Clara',
    'Hugo',
    'Ines',
    'Felix',
    'Zoe',
    'Adam',
    'Lena',
    'Marco',
    'Julia',
    'Tom',
    'Elsa',
    'Noah',
    'Vera',
    'Leo',
    'Ida',
    'Max',
    'Ruth',
    'Sam',
    'Eva',
    'Karl',
    'Amy',
    'Paul',
    'Mia',
    'Erik',
    'Sara',
    'Ivan',
    'Lucy',
    'Owen',
    'Rosa',
    'Nils',
    'Faye'
];
const companies = [
    'NewCo Labs',
    'Vertex Capital',
    'Bluepeak Bank',
    'Helios Insurance',
    'Quantumsoft',
    'Northwind Systems'
];
for (let i = 0; i < 33; i++) {
    const f = first[i];
    rows.push([
        f,
        'Attendee' + (i + 1),
        `${f.toLowerCase()}.a${i + 1}@prospect.example`,
        i % 3 === 0 ? 'Director' : 'Manager',
        companies[i % companies.length],
        '',
        EVENT
    ]);
}

// AMBIGUOUS: the seed puts two Marie Duponts under Acme Corp. With no email in this
// row the cascade runs out of criteria and writes nothing — see seed-demo-data.apex.
rows.push(['Marie', 'Dupont', '', 'Analyst', 'Acme Corp', '', EVENT]);

function csvCell(value) {
    const text = String(value);
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

const csv = rows.map((row) => row.map(csvCell).join(',')).join('\r\n');

mkdirSync('demo-data', { recursive: true });
writeFileSync('demo-data/FinTech_Summit_2026_Attendees.csv', '\uFEFF' + csv, 'utf8');
console.log(`Wrote demo-data/FinTech_Summit_2026_Attendees.csv (${rows.length - 1} data rows)`);
