/**
 * Inbound callback from the corporate (on-prem) approval system, called by the
 * integration middleware over ordinary outbound HTTPS with an OAuth-authenticated
 * integration user (Event_Approval_Integration permission set).
 *
 *   POST /services/apexrest/event-approval/v1/decisions
 *   {
 *     "acknowledgements": ["<correlationId>", ...],            // optional: ticket created
 *     "decisions": [                                            // optional: sign-offs
 *       { "correlationId": "...", "approve": true,
 *         "approverId": "EMP1234", "comment": "ok" }
 *     ]
 *   }
 *
 * Always 200 with per-item statuses (APPLIED / ALREADY_APPLIED / NOT_FOUND /
 * CONFLICT / INVALID) so the middleware can retry blindly — replays are idempotent.
 * 400 only for a body that cannot be parsed or contains neither list.
 *
 * `without sharing` on purpose: the integration user holds no event ownership; the
 * correlation ID (unique, unguessable UUID) is what authorizes touching a row.
 */
@RestResource(urlMapping='/event-approval/v1/decisions')
global without sharing class ExternalApprovalRestService {

    global class DecisionItem {
        global String correlationId;
        global Boolean approve;
        global String approverId;
        global String comment;
    }

    global class RequestPayload {
        global List<String> acknowledgements;
        global List<DecisionItem> decisions;
    }

    global class ItemResult {
        global String correlationId;
        global String status;
        global String message;
    }

    global class ResponsePayload {
        global Integer acknowledged = 0;
        global List<ItemResult> results = new List<ItemResult>();
    }

    @HttpPost
    global static void applyDecisions() {
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        RequestPayload payload;
        try {
            String body = RestContext.request.requestBody == null ? '' : RestContext.request.requestBody.toString();
            payload = (RequestPayload) JSON.deserialize(body, RequestPayload.class);
        } catch (Exception e) {
            badRequest(res, 'Malformed request body: ' + e.getMessage());
            return;
        }
        if (payload == null || (payload.acknowledgements == null && payload.decisions == null)) {
            badRequest(res, 'Provide "acknowledgements" and/or "decisions".');
            return;
        }

        ResponsePayload outp = new ResponsePayload();
        if (payload.acknowledgements != null) {
            outp.acknowledged = ApprovalDecisionService.acknowledge(payload.acknowledgements);
        }
        if (payload.decisions != null) {
            List<ApprovalDecisionService.ExternalDecision> ds = new List<ApprovalDecisionService.ExternalDecision>();
            for (DecisionItem item : payload.decisions) {
                ApprovalDecisionService.ExternalDecision d = new ApprovalDecisionService.ExternalDecision();
                if (item != null) {
                    d.correlationId = item.correlationId;
                    d.approve = item.approve;
                    d.approverRef = item.approverId;
                    d.comment = item.comment;
                }
                ds.add(d);
            }
            for (ApprovalDecisionService.ExternalResult r : ApprovalDecisionService.applyExternalDecisions(ds)) {
                ItemResult ir = new ItemResult();
                ir.correlationId = r.correlationId;
                ir.status = r.status;
                ir.message = r.message;
                outp.results.add(ir);
            }
        }

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(outp));
    }

    private static void badRequest(RestResponse res, String message) {
        res.statusCode = 400;
        res.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'error' => message }));
    }
}
