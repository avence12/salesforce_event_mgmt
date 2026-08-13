/**
 * R6 migration — run ONCE, against an org that already has R5 or earlier, BEFORE
 * deploying the R6 source.
 *
 *   sf apex run --file scripts/r6-pre-deploy.apex -o poc-sandbox
 *
 * Why it has to run first: `Marketing_Event__c.Event_Type__c` is a **restricted**
 * picklist, and R6 replaces its values. A restricted picklist cannot lose a value
 * that records still hold, so the deploy fails outright while any event is still
 * a Webinar, a Roadshow or a Dinner / Gala. Same trap R3 hit with the `Exported`
 * status, and it fails the same way: loudly, before anything changes.
 *
 *   old value        →  new value
 *   Conference       →  Conference     (survives untouched)
 *   Webinar          →  ??             ← you must decide
 *   Roadshow         →  ??             ← you must decide
 *   Dinner / Gala    →  ??             ← you must decide
 *
 * THE SCRIPT REFUSES TO RUN UNTIL YOU FILL THE MAP IN. That is deliberate. The
 * new taxonomy — Symposium / OIP / Conference — is not a renaming of the old one,
 * and no mapping I could pick would be more than a guess: "OIP" is the business's
 * term, not a Salesforce one, and guessing it wrong writes a wrong event type onto
 * historical records that the R6 recommendation work then reads as truth. Blanking
 * them is an allowed answer — set the value to '' and the type is cleared, which
 * is honest about not knowing. Silently guessing is not.
 */

// ---- FILL THIS IN. Valid new values: 'Symposium', 'OIP', 'Conference', or '' to clear. ----
Map<String, String> REMAP = new Map<String, String>{
    'Webinar' => null,
    'Roadshow' => null,
    'Dinner / Gala' => null
};

Set<String> ALLOWED = new Set<String>{ 'Symposium', 'OIP', 'Conference', '' };

// ---- What is actually out there ----
Map<String, Integer> counts = new Map<String, Integer>();
for (AggregateResult ar : [
    SELECT Event_Type__c t, COUNT(Id) n
    FROM Marketing_Event__c
    WHERE Event_Type__c IN :REMAP.keySet()
    GROUP BY Event_Type__c
]) {
    counts.put((String) ar.get('t'), (Integer) ar.get('n'));
}

if (counts.isEmpty()) {
    System.debug('Nothing to remap — no event holds a retired Event_Type__c value. Safe to deploy R6.');
} else {
    // Refuse before writing anything if the decision has not been made.
    List<String> undecided = new List<String>();
    List<String> invalid = new List<String>();
    for (String oldValue : counts.keySet()) {
        String target = REMAP.get(oldValue);
        if (target == null) {
            undecided.add(oldValue + ' (' + counts.get(oldValue) + ' event(s))');
        } else if (!ALLOWED.contains(target)) {
            invalid.add(oldValue + ' → "' + target + '"');
        }
    }
    if (!undecided.isEmpty() || !invalid.isEmpty()) {
        String msg = 'R6 migration refused — nothing was changed.\n';
        if (!undecided.isEmpty()) {
            msg += 'No mapping decided for: ' + String.join(undecided, ', ') + '\n';
        }
        if (!invalid.isEmpty()) {
            msg +=
                'Not a valid R6 value: ' +
                String.join(invalid, ', ') +
                '. Allowed: Symposium, OIP, Conference, or empty to clear.\n';
        }
        msg += 'Edit the REMAP map at the top of scripts/r6-pre-deploy.apex and run it again.';
        throw new IllegalArgumentException(msg);
    }

    List<Marketing_Event__c> toUpdate = new List<Marketing_Event__c>();
    for (Marketing_Event__c e : [
        SELECT Id, Event_Type__c
        FROM Marketing_Event__c
        WHERE Event_Type__c IN :REMAP.keySet()
    ]) {
        String target = REMAP.get(e.Event_Type__c);
        e.Event_Type__c = String.isBlank(target) ? null : target;
        toUpdate.add(e);
    }
    update toUpdate;
    System.debug('Remapped ' + toUpdate.size() + ' event(s): ' + counts);
}

System.debug(
    'Events still holding a retired value (must be zero before deploying R6): ' +
    Database.countQuery(
        'SELECT COUNT() FROM Marketing_Event__c WHERE Event_Type__c IN (\'Webinar\', \'Roadshow\', \'Dinner / Gala\')'
    )
);
System.debug('Reminder: Topic__c ships with placeholder values. Replace them and back-fill past events,');
System.debug('or every historical event looks equally similar to every new one and recommendations are noise.');
