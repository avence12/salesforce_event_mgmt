# Event Contact Management — Business Requirement

## Background

Marketing/sales staff within the company upload a contact list collected from other systems into Salesforce, with the goal of selecting the Contacts suitable for attending an Event and routing them through an approval process.

## Actors / Terms

- **BD**: Marketing/sales staff responsible for maintaining the list, creating the Event, selecting Contacts, submitting for approval, and exporting the approved list.
- **Account Owner (Level 1 Approver)**: A role defined in Salesforce, typically the BD's account for the customer, and the first approver in the Approval Chain for that account's Contacts.
- **Approver**: A generic term for any role in the Approval Chain — the Account Owner or one of the managers above them.
- **Level 2 / Level 3 Approver**: The Account Owner's manager, and that manager's manager, resolved by walking up `User.ManagerId` (the Salesforce role/reporting hierarchy). The chain includes at most these two additional levels above the Account Owner.
- **Regional Head**: A user in the reporting hierarchy holding the Regional Head title. If the Approval Chain reaches a Regional Head before exhausting the 2-level cap, the chain ends at that Regional Head's approval — it does not continue further up, and does not require filling out the remaining levels.
- **Approval Chain**: The ordered sequence of Approvers for an Event's Contacts, starting at the Account Owner and walking up `User.ManagerId` for at most 2 additional levels, terminating early if a Regional Head is reached.
- **Contact**: A Salesforce standard object.
- **Event Attendee**: A custom object owned by this project, holding one row per imported person. It is not a Contact, Lead or Account — the import never creates, reads, updates or deletes any of those three standard objects.
- **Marketing Event**: An object to be created, representing a marketing event that holds a set of candidate Event Attendees.

## Requirements

1. **Import attendee list**
   The BD uploads an attendee list exported from an external system; the system matches each row against existing **Event Attendee** records — this project's own object — never against Salesforce Contacts, Leads or Accounts, which the import does not read or write at all. Matching is by a normalised key (last name, first name, company, email). If a row's key matches an existing Event Attendee, that record's title, mobile number and source file are refreshed; nothing on a Contact is ever touched.
   Definition of done: each record in the list results in one of three outcomes — "added as a new Event Attendee," "existing Event Attendee updated with the changed fields," or "no last name to key on — skipped, nothing written."

2. **Create Event & select contacts**
   The BD can create an Event and select Contacts from the Accounts they own to add to that Event.

3. **Submit for approval**
   The BD can submit the Event's contact list for approval; the system routes it through the Approval Chain, starting with the Account Owner. A notification email is sent to the current Approver each time the request reaches their level. Each Approver can, via the Salesforce Web or iOS App, approve or reject each contact individually, with a "select all" button available for batch processing. Once the current Approver finishes, the request advances to the next level in the Approval Chain (unless the chain has ended — see **Approval Chain**), until final approval is reached.

4. **Export approved contacts**
   Once the Approval Chain completes, the BD receives a notification email sent by Salesforce; the BD can then export the approved contacts from that Event.

## Implementation Details

The matching logic, import file format, Event state machine, and other implementation decisions are documented in `design.md` (the PoC has implemented Option B per this requirement: custom object + LWC implementation).
