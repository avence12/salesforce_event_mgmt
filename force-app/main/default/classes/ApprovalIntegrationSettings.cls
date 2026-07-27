/**
 * Accessor for the Approval_Integration_Setting__mdt "Default" record.
 * The @TestVisible overrides exist because custom metadata cannot be inserted
 * from tests; production code must always come through these getters.
 */
public with sharing class ApprovalIntegrationSettings {

    @TestVisible private static Boolean externalEnabledOverride;
    @TestVisible private static Integer resendAfterHoursOverride;
    @TestVisible private static Integer failAfterHoursOverride;

    /** When true, sign-off happens in the corporate approval system, not in Salesforce. */
    public static Boolean externalEnabled() {
        if (externalEnabledOverride != null) { return externalEnabledOverride; }
        Approval_Integration_Setting__mdt s = record();
        return s != null && s.External_Approval_Enabled__c == true;
    }

    public static Integer resendAfterHours() {
        if (resendAfterHoursOverride != null) { return resendAfterHoursOverride; }
        Approval_Integration_Setting__mdt s = record();
        return s != null && s.Resend_After_Hours__c != null ? s.Resend_After_Hours__c.intValue() : 24;
    }

    public static Integer failAfterHours() {
        if (failAfterHoursOverride != null) { return failAfterHoursOverride; }
        Approval_Integration_Setting__mdt s = record();
        return s != null && s.Fail_After_Hours__c != null ? s.Fail_After_Hours__c.intValue() : 72;
    }

    private static Approval_Integration_Setting__mdt record() {
        return Approval_Integration_Setting__mdt.getInstance('Default');
    }
}
