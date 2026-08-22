/**
 * ★R12 The only trigger in this project, and it does one thing: hand an attendee edit to
 * EventAttendeeSync so invitees still awaiting a decision pick the change up.
 *
 * after update only. There is nothing to sync on insert — an attendee cannot have
 * invitees yet — and a delete cannot reach the invitees either way, because
 * Event_Invitee__c.Event_Attendee__c is what would have to cascade and that is the
 * platform's job, not this trigger's.
 *
 * Logic lives in the handler rather than here so it can be called directly from a test
 * and read without trigger context in the way.
 */
trigger EventAttendeeTrigger on Event_Attendee__c(after update) {
    EventAttendeeSync.onAfterUpdate(Trigger.new, Trigger.oldMap);
}
