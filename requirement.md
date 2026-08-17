# Event Contact Management — Business Requirement

## Background

Marketing/sales staff within the company upload an attendee list collected from other systems into Salesforce, with the goal of selecting the people suitable for attending an Event and routing their invitations through an approval process.

## Actors / Terms

- **BD**: Marketing/sales staff responsible for maintaining the list, creating the Event, selecting Event Attendees, submitting for approval, and exporting the approved list.
- **Account Owner (Level 1 Approver)**: A role defined in Salesforce, typically the BD's account for the customer, and the first approver in the Approval Chain for an Event Invitee whose Event Attendee is linked (via **Contact**) to that account. An Event Attendee with no such Contact link has no Account Owner and cannot be routed for approval.
- **Approver**: A generic term for any role in the Approval Chain — the Account Owner or one of the managers above them.
- **Level 2 / Level 3 Approver**: The Account Owner's manager, and that manager's manager, resolved by walking up `User.ManagerId` (the Salesforce role/reporting hierarchy). The chain includes at most these two additional levels above the Account Owner.
- **Regional Head**: A user in the reporting hierarchy holding the Regional Head title. If the Approval Chain reaches a Regional Head before exhausting the 2-level cap, the chain ends at that Regional Head's approval — it does not continue further up, and does not require filling out the remaining levels.
- **Approval Chain**: The ordered sequence of Approvers for an Event Invitee, starting at the Account Owner and walking up `User.ManagerId` for at most 2 additional levels, terminating early if a Regional Head is reached.
- **Contact**: A Salesforce standard object. The import never touches it; it is used only to resolve an Event Attendee's Account Owner, via a separate reconciliation step that links an Event Attendee to a matching Contact.
- **Event Attendee**: A custom object owned by this project, holding one row per imported person. It is not a Contact, Lead or Account — the import never creates, reads, updates or deletes any of those three standard objects.
- **Event Invitee**: A custom object owned by this project, representing one Event Attendee's invitation to one specific Marketing Event. This is the record the Approval Chain and the export operate on — an Event Attendee added to two Events produces two Event Invitees.
- **Marketing Event**: An object to be created, representing a marketing event that holds a set of Event Invitees.

## Requirements

1. **Import attendee list**
   The BD uploads an attendee list exported from an external system; the system matches each row against existing **Event Attendee** records — this project's own object — never against Salesforce Contacts, Leads or Accounts, which the import does not read or write at all. Matching is by a normalised key (last name, first name, company, email). If a row's key matches an existing Event Attendee, that record's title, mobile number and source file are refreshed; nothing on a Contact is ever touched.
   Definition of done: each record in the list results in one of three outcomes — "added as a new Event Attendee," "existing Event Attendee updated with the changed fields," or "no last name to key on — skipped, nothing written."

2. **Create Event & select attendees**
   The BD can create an Event and select Event Attendees to add to that Event, creating an Event Invitee for each. Selection is not scoped by Account ownership: Event Attendees are a shared pool, and any BD may add any Event Attendee to an Event.

3. **Submit for approval**
   The BD can submit their own added Event Invitees for approval; the system routes each one through the Approval Chain, starting with the Account Owner. An Event Invitee whose Event Attendee has no Account Owner (see **Account Owner**) cannot be submitted, and a batch containing one is refused in full, with nothing submitted, until it is removed or reconciled. A notification email is sent to the current Approver each time the request reaches their level. Each Approver can, via the Salesforce Web or the Salesforce Mobile App, approve or reject each Event Invitee individually, with a "select all" button available for batch processing. Once the current Approver finishes, the request advances to the next level in the Approval Chain (unless the chain has ended — see **Approval Chain**), until final approval is reached.

4. **Export approved invitees**
   Once the Approval Chain completes for an Event Invitee, the BD who added it receives a notification email sent by Salesforce; the BD can then export the approved invitees from that Event.

## Implementation Details

The matching logic, import file format, Event state machine, and other implementation decisions are documented in `design.md` (the PoC has implemented Option B per this requirement: custom object + LWC implementation).
