package com.retail.agent;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import javax.net.ssl.HttpsURLConnection;
import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

public class RetailLLMAnswerGenerator {

    private static final String OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
    private static final String MODEL = "gpt-4.1-mini";

    private static final Set<String> ANSWER_SOURCES = new HashSet<String>(Arrays.asList(
            "approval",
            "approval_blocked",
            "domain_tool",
            "rag",
            "fallback"
    ));

    private final ObjectMapper mapper = new ObjectMapper();

    public String generate(
            String question,
            String plannerJson,
            String policyRagJson,
            String toolCallsJson,
            String pendingApprovalJson,
            String approvalBlockedJson
    ) throws Exception {
        JsonNode planner = parseJsonOrEmpty(plannerJson);
        JsonNode policyRag = parseJsonOrEmpty(policyRagJson);
        JsonNode toolCalls = parseJsonArrayOrEmpty(toolCallsJson);
        JsonNode pendingApproval = parseNullableJson(pendingApprovalJson);
        JsonNode approvalBlocked = parseNullableJson(approvalBlockedJson);

        String apiKey = System.getenv("OPENAI_API_KEY");

        if (apiKey == null || apiKey.trim().isEmpty()) {
            return mapper.writeValueAsString(
                    fallbackAnswer(question, planner, policyRag, toolCalls, pendingApproval, approvalBlocked)
            );
        }

        try {
            ObjectNode request = buildOpenAiRequest(
                    question,
                    planner,
                    policyRag,
                    toolCalls,
                    pendingApproval,
                    approvalBlocked
            );

            JsonNode response = postJson(OPENAI_RESPONSES_URL, apiKey, request);
            JsonNode generated = extractStructuredOutput(response);

            ObjectNode sanitized = sanitizeAnswer(
                    generated,
                    question,
                    planner,
                    policyRag,
                    toolCalls,
                    pendingApproval,
                    approvalBlocked
            );

            return mapper.writeValueAsString(sanitized);
        } catch (Exception e) {
            /*return mapper.writeValueAsString(
                    fallbackAnswer(question, planner, policyRag, toolCalls, pendingApproval, approvalBlocked)
            );*/
        	throw new RuntimeException("OpenAI answer generation failed", e);
        }
    }

    private ObjectNode buildOpenAiRequest(
            String question,
            JsonNode planner,
            JsonNode policyRag,
            JsonNode toolCalls,
            JsonNode pendingApproval,
            JsonNode approvalBlocked
    ) {
        ObjectNode request = mapper.createObjectNode();
        request.put("model", MODEL);
        request.put("temperature", 0);

        ArrayNode input = request.putArray("input");

        ObjectNode system = mapper.createObjectNode();
        system.put("role", "system");
        system.put("content", systemPrompt());
        input.add(system);

        ObjectNode payload = mapper.createObjectNode();
        payload.put("question", defaultString(question, ""));
        payload.set("planner", planner);
        payload.set("policyRag", policyRag);
        payload.set("toolCalls", toolCalls);
        payload.set("pendingApproval", pendingApproval == null ? mapper.nullNode() : pendingApproval);
        payload.set("approvalBlocked", approvalBlocked == null ? mapper.nullNode() : approvalBlocked);

        ObjectNode user = mapper.createObjectNode();
        user.put("role", "user");
        user.put("content", payload.toString());
        input.add(user);

        ObjectNode text = request.putObject("text");
        ObjectNode format = text.putObject("format");
        format.put("type", "json_schema");
        format.put("name", "retail_answer_output");
        format.put("strict", true);
        format.set("schema", answerSchema());

        return request;
    }

    private String systemPrompt() {
        return "You are a retail copilot answer generator.\n"
                + "Generate a concise customer-facing answer from the planner result, RAG result, MCP tool results, and approval state.\n"
                + "Rules:\n"
                + "- Prefer approval state over everything else.\n"
                + "- If pendingApproval exists, explain that approval is required and do not claim the action completed.\n"
                + "- If approvalBlocked exists, explain why the action cannot proceed.\n"
                + "- If MCP tool results answer the question, use them as the primary source.\n"
                + "- Use RAG answer and citations for policy, warranty, FAQ, and promotion-policy questions.\n"
                + "- Do not show citations for live operational answers unless the final answer uses RAG.\n"
                + "- Never invent inventory quantities, prices, return eligibility, promotions, approval IDs, or order details.\n"
                + "- Keep answer under 120 words.\n"
                + "- Return only the structured JSON object matching the schema.";
    }

    private ObjectNode answerSchema() {
        ObjectNode schema = mapper.createObjectNode();
        schema.put("type", "object");
        schema.put("additionalProperties", false);

        ObjectNode properties = schema.putObject("properties");

        properties.putObject("answer").put("type", "string");

        ObjectNode answerSource = properties.putObject("answerSource");
        answerSource.put("type", "string");
        ArrayNode sourceEnum = answerSource.putArray("enum");
        sourceEnum.add("approval");
        sourceEnum.add("approval_blocked");
        sourceEnum.add("domain_tool");
        sourceEnum.add("rag");
        sourceEnum.add("fallback");

        properties.putObject("citationsUsed").put("type", "boolean");

        ObjectNode citationIds = properties.putObject("citationIds");
        citationIds.put("type", "array");
        citationIds.putObject("items").put("type", "string");

        properties.putObject("reasoningSummary").put("type", "string");

        ObjectNode confidence = properties.putObject("confidence");
        confidence.put("type", "string");
        ArrayNode confidenceEnum = confidence.putArray("enum");
        confidenceEnum.add("high");
        confidenceEnum.add("medium");
        confidenceEnum.add("low");

        ArrayNode required = schema.putArray("required");
        required.add("answer");
        required.add("answerSource");
        required.add("citationsUsed");
        required.add("citationIds");
        required.add("reasoningSummary");
        required.add("confidence");

        return schema;
    }

    private ObjectNode sanitizeAnswer(
            JsonNode generated,
            String question,
            JsonNode planner,
            JsonNode policyRag,
            JsonNode toolCalls,
            JsonNode pendingApproval,
            JsonNode approvalBlocked
    ) {
        ObjectNode fallback = fallbackAnswer(question, planner, policyRag, toolCalls, pendingApproval, approvalBlocked);

        String source = generated.path("answerSource").asText(fallback.path("answerSource").asText("fallback"));

        if (!ANSWER_SOURCES.contains(source)) {
            source = fallback.path("answerSource").asText("fallback");
        }

        if (hasRealPendingApproval(pendingApproval)) {
            source = "approval";
        } else if (hasApprovalBlocked(approvalBlocked)) {
            source = "approval_blocked";
        } else if (hasUsefulDomainToolResult(toolCalls)) {
            source = "domain_tool";
        } else if (!policyRag.path("answer").asText("").trim().isEmpty()) {
            source = "rag";
        } else {
            source = "fallback";
        }

        String answer = generated.path("answer").asText("");
        if (answer.trim().isEmpty()) {
            answer = fallback.path("answer").asText("I could not generate an answer from the available context.");
        }

        if ("approval".equals(source)
                || "approval_blocked".equals(source)
                || "domain_tool".equals(source)
                || "fallback".equals(source)) {
            answer = fallback.path("answer").asText(answer);
        }

        boolean citationsUsed = "rag".equals(source) && generated.path("citationsUsed").asBoolean(false);

        if ("rag".equals(source) && !policyRag.path("answer").asText("").trim().isEmpty()) {
            citationsUsed = true;
        }

        ObjectNode sanitized = mapper.createObjectNode();
        sanitized.put("answer", answer);
        sanitized.put("answerSource", source);
        sanitized.put("citationsUsed", citationsUsed);

        ArrayNode citationIds = sanitized.putArray("citationIds");
        if (citationsUsed) {
            JsonNode generatedCitationIds = generated.path("citationIds");

            if (generatedCitationIds.isArray() && generatedCitationIds.size() > 0) {
                for (JsonNode id : generatedCitationIds) {
                    String value = id.asText("");
                    if (!value.trim().isEmpty()) {
                        citationIds.add(value);
                    }
                }
            } else {
                JsonNode citations = policyRag.path("citations");
                if (citations.isArray()) {
                    for (JsonNode citation : citations) {
                        String id = citation.path("id").asText("");
                        if (!id.trim().isEmpty()) {
                            citationIds.add(id);
                        }
                    }
                }
            }
        }

        sanitized.put("reasoningSummary", generated.path("reasoningSummary").asText(
                fallback.path("reasoningSummary").asText("Generated from available retail context.")
        ));

        if ("approval".equals(source)) {
            sanitized.put("reasoningSummary", "Pending approval was present.");
        } else if ("approval_blocked".equals(source)) {
            sanitized.put("reasoningSummary", "Approval action was blocked.");
        } else if ("domain_tool".equals(source)) {
            sanitized.put("reasoningSummary", fallback.path("reasoningSummary").asText("Used MCP domain tool result."));
        } else if ("rag".equals(source)) {
            sanitized.put("reasoningSummary", "Used Policy RAG answer.");
        }

        sanitized.put("confidence", generated.path("confidence").asText(
                fallback.path("confidence").asText("medium")
        ));

        if ("approval".equals(source)
                || "approval_blocked".equals(source)
                || "domain_tool".equals(source)) {
            sanitized.put("confidence", "high");
        } else if ("fallback".equals(source)) {
            sanitized.put("confidence", "low");
        }

        return sanitized;
    }

    private ObjectNode fallbackAnswer(
            String question,
            JsonNode planner,
            JsonNode policyRag,
            JsonNode toolCalls,
            JsonNode pendingApproval,
            JsonNode approvalBlocked
    ) {
        ObjectNode output = mapper.createObjectNode();

        if (hasRealPendingApproval(pendingApproval)) {
            output.put("answer", approvalAnswer(pendingApproval));
            output.put("answerSource", "approval");
            output.put("citationsUsed", false);
            output.putArray("citationIds");
            output.put("reasoningSummary", "Pending approval was present.");
            output.put("confidence", "high");
            return output;
        }

        if (hasApprovalBlocked(approvalBlocked)) {
            output.put("answer", approvalBlocked.path("reason").asText("This action cannot proceed."));
            output.put("answerSource", "approval_blocked");
            output.put("citationsUsed", false);
            output.putArray("citationIds");
            output.put("reasoningSummary", "Approval action was blocked.");
            output.put("confidence", "high");
            return output;
        }

        JsonNode inventory = findToolCall(toolCalls, "check_inventory");
        if (inventory != null && !isSkipped(inventory)) {
            output.put("answer", inventoryAnswer(inventory, findToolCall(toolCalls, "get_product")));
            output.put("answerSource", "domain_tool");
            output.put("citationsUsed", false);
            output.putArray("citationIds");
            output.put("reasoningSummary", "Used check_inventory MCP tool result.");
            output.put("confidence", "high");
            return output;
        }

        JsonNode eligibility = findToolCall(toolCalls, "check_return_eligibility");
        if (eligibility != null && !isSkipped(eligibility)) {
            output.put("answer", returnEligibilityAnswer(eligibility));
            output.put("answerSource", "domain_tool");
            output.put("citationsUsed", false);
            output.putArray("citationIds");
            output.put("reasoningSummary", "Used check_return_eligibility MCP tool result.");
            output.put("confidence", "high");
            return output;
        }

        String ragAnswer = policyRag.path("answer").asText("");
        if (!ragAnswer.trim().isEmpty()) {
            output.put("answer", ragAnswer);
            output.put("answerSource", "rag");
            output.put("citationsUsed", true);

            ArrayNode citationIds = output.putArray("citationIds");
            JsonNode citations = policyRag.path("citations");
            if (citations.isArray()) {
                for (JsonNode citation : citations) {
                    String id = citation.path("id").asText("");
                    if (!id.trim().isEmpty()) {
                        citationIds.add(id);
                    }
                }
            }

            output.put("reasoningSummary", "Used Policy RAG answer.");
            output.put("confidence", "medium");
            return output;
        }

        output.put("answer", "I could not find enough information to answer that request.");
        output.put("answerSource", "fallback");
        output.put("citationsUsed", false);
        output.putArray("citationIds");
        output.put("reasoningSummary", "No approval, domain tool, or RAG answer was available.");
        output.put("confidence", "low");
        return output;
    }

    private String approvalAnswer(JsonNode pendingApproval) {
        String toolName = pendingApproval.path("toolName").asText("");
        String summary = pendingApproval.path("summary").asText("");

        if (!summary.trim().isEmpty()) {
            return summary;
        }

        if ("reserve_inventory".equals(toolName)) {
            return "This reservation requires manager or admin approval before inventory is changed.";
        }

        if ("create_return_authorization".equals(toolName)) {
            return "This return authorization requires manager or admin approval before it is created.";
        }

        if ("apply_promotion".equals(toolName)) {
            return "Applying this promotion requires manager or admin approval.";
        }

        return "This action requires manager or admin approval before it can be completed.";
    }

    private String inventoryAnswer(JsonNode inventoryTool, JsonNode productTool) {
        JsonNode result = inventoryTool.path("result");

        String sku = result.path("sku").asText(inventoryTool.path("arguments").path("sku").asText(""));
        String storeId = result.path("storeId").asText(inventoryTool.path("arguments").path("storeId").asText(""));
        String productName = result.path("productName").asText("");

        if (productName.trim().isEmpty() && productTool != null) {
            productName = productTool.path("result").path("name").asText("");
        }

        if (productName.trim().isEmpty()) {
            productName = sku;
        }

        int quantity = result.path("quantity").asInt(0);
        String aisle = result.path("aisle").asText("");
        String status = result.path("status").asText("");

        if (quantity > 0 || "in_stock".equalsIgnoreCase(status)) {
            String answer = "Yes. " + sku + ", the " + productName + ", is available at " + storeId
                    + " with " + quantity + " units in stock.";
            if (!aisle.trim().isEmpty()) {
                answer += " It is located in aisle " + aisle + ".";
            }
            return answer;
        }

        if ("out_of_stock".equalsIgnoreCase(status) || quantity == 0) {
            return "No. " + sku + ", the " + productName + ", is currently out of stock at " + storeId + ".";
        }

        return "I could not confirm current availability for " + sku + " at " + storeId + ".";
    }

    private String returnEligibilityAnswer(JsonNode eligibilityTool) {
        JsonNode result = eligibilityTool.path("result");

        String orderId = result.path("orderId").asText(
                eligibilityTool.path("arguments").path("orderId").asText("")
        );

        boolean eligible = result.path("eligible").asBoolean(false);
        String reason = result.path("reason").asText("");

        if (eligible) {
            return "Order " + orderId + " is eligible for return."
                    + (reason.trim().isEmpty() ? "" : " " + reason);
        }

        return "Order " + orderId + " is not eligible for return."
                + (reason.trim().isEmpty() ? "" : " " + reason);
    }

    private JsonNode findToolCall(JsonNode toolCalls, String name) {
        if (!toolCalls.isArray()) return null;

        for (JsonNode toolCall : toolCalls) {
            if (name.equals(toolCall.path("name").asText())) {
                return toolCall;
            }
        }

        return null;
    }

    private boolean hasUsefulDomainToolResult(JsonNode toolCalls) {
        if (!toolCalls.isArray()) return false;

        for (JsonNode toolCall : toolCalls) {
            String name = toolCall.path("name").asText("");
            if (isSkipped(toolCall)) continue;

            if ("check_inventory".equals(name)
                    || "check_return_eligibility".equals(name)
                    || "lookup_order".equals(name)
                    || "find_promotions".equals(name)) {
                return true;
            }
        }

        return false;
    }

    private boolean isSkipped(JsonNode toolCall) {
        return toolCall.path("result").path("skipped").asBoolean(false);
    }

    private boolean hasRealPendingApproval(JsonNode pendingApproval) {
        if (pendingApproval == null || pendingApproval.isNull() || !pendingApproval.isObject()) {
            return false;
        }

        String approvalId = pendingApproval.path("approvalId").asText("");
        String status = pendingApproval.path("status").asText("");

        return !approvalId.trim().isEmpty() && "pending".equalsIgnoreCase(status);
    }

    private boolean hasApprovalBlocked(JsonNode approvalBlocked) {
        if (approvalBlocked == null || approvalBlocked.isNull() || !approvalBlocked.isObject()) {
            return false;
        }

        return !approvalBlocked.path("reason").asText("").trim().isEmpty();
    }

    private JsonNode postJson(String endpoint, String apiKey, JsonNode payload) throws Exception {
        URL url = new URL(endpoint);
        HttpsURLConnection connection = (HttpsURLConnection) url.openConnection();
        connection.setRequestMethod("POST");
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(30000);
        connection.setDoOutput(true);
        connection.setRequestProperty("Authorization", "Bearer " + apiKey);
        connection.setRequestProperty("Content-Type", "application/json");

        byte[] body = mapper.writeValueAsBytes(payload);
        try (OutputStream outputStream = connection.getOutputStream()) {
            outputStream.write(body);
        }

        int status = connection.getResponseCode();
        InputStream stream = status >= 200 && status < 300
                ? connection.getInputStream()
                : connection.getErrorStream();

        String responseBody = readAll(stream);

        if (status < 200 || status >= 300) {
            throw new RuntimeException("OpenAI answer request failed with status " + status + ": " + responseBody);
        }

        return mapper.readTree(responseBody);
    }

    private JsonNode extractStructuredOutput(JsonNode response) throws Exception {
        JsonNode output = response.path("output");

        if (output.isArray()) {
            for (JsonNode item : output) {
                JsonNode content = item.path("content");
                if (!content.isArray()) continue;

                for (JsonNode contentItem : content) {
                    if (contentItem.has("text")) {
                        return mapper.readTree(contentItem.path("text").asText());
                    }
                }
            }
        }

        if (response.has("output_text")) {
            return mapper.readTree(response.path("output_text").asText());
        }

        throw new IllegalStateException("No structured answer output found in OpenAI response.");
    }

    private JsonNode parseJsonOrEmpty(String json) {
        if (json == null || json.trim().isEmpty()) {
            return mapper.createObjectNode();
        }

        try {
            return mapper.readTree(json);
        } catch (Exception ignored) {
            return mapper.createObjectNode();
        }
    }

    private JsonNode parseJsonArrayOrEmpty(String json) {
        if (json == null || json.trim().isEmpty()) {
            return mapper.createArrayNode();
        }

        try {
            JsonNode node = mapper.readTree(json);
            return node.isArray() ? node : mapper.createArrayNode();
        } catch (Exception ignored) {
            return mapper.createArrayNode();
        }
    }

    private JsonNode parseNullableJson(String json) {
        if (json == null || json.trim().isEmpty() || "null".equalsIgnoreCase(json.trim())) {
            return mapper.nullNode();
        }

        try {
            return mapper.readTree(json);
        } catch (Exception ignored) {
            return mapper.nullNode();
        }
    }

    private String readAll(InputStream stream) throws Exception {
        if (stream == null) return "";

        StringBuilder builder = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                builder.append(line);
            }
        }

        return builder.toString();
    }

    private String defaultString(String value, String fallback) {
        return value == null || value.trim().isEmpty() ? fallback : value;
    }
}
