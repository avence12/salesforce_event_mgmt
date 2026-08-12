/**
 * Generates demo-data/FinTech_Summit_2026_Attendees.csv — an attendee list that
 * exercises every R5 classification in the import wizard:
 *   - NEW_ATTENDEE      (everyone, on a first run against a clean org)
 *   - EXISTING_ATTENDEE (seen on a second run, and on the rows scripts/seed-demo-data.apex pre-creates)
 *   - SKIPPED           (2 rows with no last name)
 *   plus an in-file duplicate that collapses (same name, company and email),
 *   a same-name pair that stays two people because their emails differ,
 *   a same-name pair that collapses because neither row has an email,
 *   one row whose Email column is junk rather than an address,
 *   and one row repeated at a second company, which is deliberately two attendees.
 *
 * There is no Event column: R5 imports people, and which event they attend is
 * decided later on the event itself. A file that still has one imports fine — the
 * column is simply ignored.
 *
 * Written UTF-8 with a BOM and CRLF line endings. The Zoë Müller-Sørensen and
 * Hélène Dubois rows are deliberately non-ASCII so the demo exercises the wizard's
 * UTF-8 decoding.
 *
 * Run:  node scripts/generate-demo-csv.mjs
 */
import { mkdirSync, writeFileSync } from 'fs';

const rows = [
    ['First Name', 'Last Name', 'Email', 'Title', 'Company', 'Mobile'],
    // Ordinary attendees from customer organisations. Nothing about "customer"
    // exists in the data any more — Acme Corp is a string, not an Account.
    ['Emily', 'Carter', 'emily.carter@acmecorp.example', 'Senior Manager', 'Acme Corp', ''],
    ['James', 'Mueller', 'j.mueller@nordbank.example', 'Director', 'Nordbank AG', ''],
    ['Robert', 'Kim', 'robert.kim@acmecorp.example', 'SVP, Operations', 'Acme Corp', ''],
    ['Laura', 'Chen', 'laura.chen@acmeins.example', 'VP, Finance', 'Acme Insurance', ''],
    ['Anna', 'Kowalski', 'a.kowalski@nordbank.example', 'Associate', 'Nordbank AG', ''],
    // Conference guests. In R4 these had to be Leads to exist at all; now they are
    // attendees on exactly the same terms as everybody above.
    ['Hélène', 'Dubois', 'h.dubois@unige.example', 'Professor', 'Université de Genève', ''],
    ['Anke', 'Weber', 'a.weber@tuberlin.example', 'Professor', 'TU Berlin', ''],
    [
        'Tomas',
        'Lindqvist',
        't.lindqvist@kth.example',
        'Senior Researcher',
        'KTH Royal Institute',
        ''
    ],
    ['Priya', 'Raman', 'p.raman@techpress.example', 'Editor', 'TechPress Media', ''],
    // SKIPPED: no last name, so there is no identity to key on
    ['Solo', '', 'solo@startup.example', 'Founder', 'Startup GmbH', ''],
    ['', '', 'anonymous@startup.example', '', 'Startup GmbH', ''],
    // In-file duplicate: same name, company and email — one attendee, not two
    ['Dana', 'Duplicate', 'dana@dupe.example', 'Analyst', 'Acme Corp', ''],
    ['Dana', 'Duplicate', 'dana@dupe.example', 'Analyst', 'Acme Corp', ''],
    // Two Marie Duponts at one company, told apart by their emails: two attendees.
    ['Marie', 'Dupont', 'm.dupont@acmecorp.example', 'Analyst', 'Acme Corp', ''],
    ['Marie', 'Dupont', 'marie.dupont@acmecorp.example', 'Senior Analyst', 'Acme Corp', ''],
    // Two Sophie Laurents at one company with no email at all. R4 called this
    // Ambiguous and wrote nothing; R5 has no matching to be ambiguous about, so
    // they collapse into one attendee. Shown in the demo precisely because it is
    // the cost of the change, not a bug.
    ['Sophie', 'Laurent', '', 'CMO', 'Globex', ''],
    ['Sophie', 'Laurent', '', 'Head of Brand', 'Globex', ''],
    // The same person listed at two companies: two attendees, because company is
    // part of who an attendee is.
    ['Marco', 'Rossi', 'm.rossi@vertex.example', 'Partner', 'Vertex Capital', ''],
    ['Marco', 'Rossi', 'm.rossi@vertex.example', 'Advisor', 'Bluepeak Bank', ''],
    // Junk in the Email column. The person is imported; the address is not stored,
    // and the preview says so on that row.
    ['Ben', 'Nomail', 'n/a', 'Analyst', 'Acme Corp', ''],
    // Non-ASCII name — proves the file is read as UTF-8 end to end
    ['Zoë', 'Müller-Sørensen', 'z.muller@newcolabs.example', 'Head of Analytics', 'NewCo Labs', '']
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
for (let i = 0; i < 28; i++) {
    const f = first[i];
    rows.push([
        f,
        'Attendee' + (i + 1),
        `${f.toLowerCase()}.a${i + 1}@prospect.example`,
        i % 3 === 0 ? 'Director' : 'Manager',
        companies[i % companies.length],
        ''
    ]);
}

function csvCell(value) {
    const text = String(value);
    return /[",\r\n]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

const csv = rows.map((row) => row.map(csvCell).join(',')).join('\r\n');

mkdirSync('demo-data', { recursive: true });
writeFileSync('demo-data/FinTech_Summit_2026_Attendees.csv', '\uFEFF' + csv, 'utf8');
console.log(`Wrote demo-data/FinTech_Summit_2026_Attendees.csv (${rows.length - 1} data rows)`);
