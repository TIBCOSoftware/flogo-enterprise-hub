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
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class RetailLLMPlanner {

    private static final String OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
    private static final String DEFAULT_MODEL = "gpt-4.1-mini";

    private static final Pattern SKU_PATTERN =
            Pattern.compile("[A-Z]{3,5}-[A-Z0-9]{3,8}-[0-9]{3}", Pattern.CASE_INSENSITIVE);

    private static final Pattern ORDER_ID_PATTERN =
            Pattern.compile("ORD-[0-9]{4,}", Pattern.CASE_INSENSITIVE);

    private static final Set<String> ALLOWED_INTENTS = Set.of(
            "knowledge_answer",
            "inventory_lookup",
            "reserve_inventory",
            "return_flow",
            "recommend",
            "recommend_and_promote"
    );

    private static final Set<String> READ_TOOLS = Set.of(
            "get_product",
            "check_inventory",
            "lookup_order",
            "check_return_eligibility",
            "find_promotions",
            "list_policy_resources",
            "read_policy_resource"
    );

    private static final Set<String> WRITE_TOOLS = Set.of(
            "reserve_inventory",
            "create_return_authorization",
            "apply_promotion"
    );

    private static final Set<String> ALL_TOOLS = Set.of(
            "get_product",
            "check_inventory",
            "reserve_inventory",
            "lookup_order",
            "check_return_eligibility",
            "create_return_authorization",
            "find_promotions",
            "apply_promotion",
            "list_policy_resources",
            "read_policy_resource"
    );

    private final ObjectMapper mapper = new ObjectMapper();
    private final RetailAgentPlanner fallbackPlanner = new RetailAgentPlanner();

    public String plan(String question, String customerId, String storeId, String memoryJson) throws Exception {
        String apiKey = System.getenv("OPENAI_API_KEY");

        if (apiKey == null || apiKey.trim().isEmpty()) {
            return fallbackPlanner.plan(question, customerId, storeId, memoryJson);
        }

        try {
            String safeQuestion = question == null ? "" : question.trim();
            String safeCustomerId = defaultString(customerId, "CUST-001");
            String safeStoreId = defaultString(storeId, "SFO-001");

            JsonNode memory = parseMemory(memoryJson);

            ObjectNode request = buildOpenAiRequest(safeQuestion, safeCustomerId, safeStoreId, memory);
            JsonNode openAiResponse = postJson(OPENAI_RESPONSES_URL, apiKey, request);
            JsonNode plannerJson = extractStructuredOutput(openAiResponse);

            ObjectNode sanitized = sanitizePlanner(plannerJson, safeQuestion, safeCustomerId, safeStoreId, memory);
            return mapper.writeValueAsString(sanitized);
        } catch (Exception e) {
            //return fallbackPlanner.plan(question, customerId, storeId, memoryJson);
        	throw new RuntimeException("OpenAI planner failed", e);
        }
    }

    private ObjectNode buildOpenAiRequest(String question, String customerId, String storeId, JsonNode memory) {
        ObjectNode request = mapper.createObjectNode();
        request.put("model", DEFAULT_MODEL);
        request.put("temperature", 0);

        ArrayNode input = request.putArray("input");

        ObjectNode system = mapper.createObjectNode();
        system.put("role", "system");
        system.put("content", plannerSystemPrompt());
        input.add(system);

        ObjectNode userPayload = mapper.createObjectNode();
        userPayload.put("question", question);
        userPayload.put("customerId", customerId);
        userPayload.put("storeId", storeId);
        userPayload.set("memory", memory);

        ArrayNode tools = userPayload.putArray("availableTools");
        for (String tool : ALL_TOOLS) {
            tools.add(tool);
        }

        ObjectNode user = mapper.createObjectNode();
        user.put("role", "user");
        user.put("content", userPayload.toString());
        input.add(user);

        ObjectNode text = request.putObject("text");
        ObjectNode format = text.putObject("format");
        format.put("type", "json_schema");
        format.put("name", "retail_planner_output");
        format.put("strict", true);
        format.set("schema", plannerSchema());

        return request;
    }

    private String plannerSystemPrompt() {
        return "You are a retail AI planning component. Return only a structured planner object matching the supplied schema.\n"
                + "Classify the user request and choose safe tool actions.\n"
                + "Rules:\n"
                + "- Use knowledge_answer for policy, warranty, FAQ, promotion-policy, and general questions.\n"
                + "- Use inventory_lookup for availability, stock, or aisle questions.\n"
                + "- Use reserve_inventory only when the user asks to reserve or hold an item.\n"
                + "- Use return_flow when the user asks about a specific order return, refund, eligibility, or creating a return.\n"
                + "- Use recommend for recommendations without applying a promotion.\n"
                + "- Use recommend_and_promote only when the user asks to apply, use, add, or redeem a promotion, discount, promo, or coupon.\n"
                + "- Warranty, policy, FAQ, return-policy, and promotion-policy questions should normally use knowledge_answer with no domain tool actions.\n"
                + "- Do not call get_product unless the question contains a valid SKU such as RUN-PEG-001.\n"
                + "- Category words like bag, shoe, jacket, electronics, bottle, or mat are not SKUs.\n"
                + "- Never execute write tools directly.\n"
                + "- reserve_inventory, create_return_authorization, and apply_promotion must require approval.\n"
                + "- Read tools do not require approval.\n"
                + "- For return policy questions without an order id, use knowledge_answer, not return_flow.\n"
                + "- Include get_product before check_inventory when a SKU is present.\n"
                + "- Include get_product before find_promotions when a SKU is present and a promotion may be applied.\n"
                + "- Include find_promotions before apply_promotion.\n"
                + "- Include lookup_order before check_return_eligibility when an order id is present.\n"
                + "- Include check_return_eligibility before create_return_authorization.";
    }


    private ObjectNode plannerSchema() {
        ObjectNode schema = mapper.createObjectNode();
        schema.put("type", "object");
        schema.put("additionalProperties", false);

        ObjectNode properties = schema.putObject("properties");

        ObjectNode intent = properties.putObject("intent");
        intent.put("type", "string");
        ArrayNode intentEnum = intent.putArray("enum");
        for (String value : ALLOWED_INTENTS) intentEnum.add(value);

        ObjectNode context = properties.putObject("context");
        context.put("type", "object");
        context.put("additionalProperties", false);
        ObjectNode contextProps = context.putObject("properties");
        contextProps.putObject("customerId").put("type", "string");
        contextProps.putObject("storeId").put("type", "string");
        ArrayNode contextRequired = context.putArray("required");
        contextRequired.add("customerId");
        contextRequired.add("storeId");

        ObjectNode entities = properties.putObject("entities");
        entities.put("type", "object");
        entities.put("additionalProperties", false);
        ObjectNode entityProps = entities.putObject("properties");
        entityProps.putObject("sku").put("type", "string");
        entityProps.putObject("orderId").put("type", "string");
        entityProps.putObject("category").put("type", "string");
        entityProps.putObject("maxPrice").put("type", "integer");
        entityProps.putObject("wantsApprovalAction").put("type", "boolean");
        ArrayNode entityRequired = entities.putArray("required");
        entityRequired.add("sku");
        entityRequired.add("orderId");
        entityRequired.add("category");
        entityRequired.add("maxPrice");
        entityRequired.add("wantsApprovalAction");

        properties.putObject("requiresRetrieval").put("type", "boolean");

        ObjectNode plan = properties.putObject("plan");
        plan.put("type", "array");
        plan.putObject("items").put("type", "string");

        ObjectNode actions = properties.putObject("actions");
        actions.put("type", "array");
        ObjectNode actionItem = actions.putObject("items");
        actionItem.put("type", "object");
        actionItem.put("additionalProperties", false);
        ObjectNode actionProps = actionItem.putObject("properties");

        ObjectNode toolName = actionProps.putObject("toolName");
        toolName.put("type", "string");
        ArrayNode toolEnum = toolName.putArray("enum");
        for (String value : ALL_TOOLS) toolEnum.add(value);

        actionProps.putObject("sku").put("type", "string");
        actionProps.putObject("orderId").put("type", "string");
        actionProps.putObject("storeId").put("type", "string");
        actionProps.putObject("customerId").put("type", "string");
        actionProps.putObject("category").put("type", "string");
        actionProps.putObject("promotionId").put("type", "string");
        actionProps.putObject("requiresApproval").put("type", "boolean");
        actionProps.putObject("rationale").put("type", "string");

        ArrayNode actionRequired = actionItem.putArray("required");
        actionRequired.add("toolName");
        actionRequired.add("sku");
        actionRequired.add("orderId");
        actionRequired.add("storeId");
        actionRequired.add("customerId");
        actionRequired.add("category");
        actionRequired.add("promotionId");
        actionRequired.add("requiresApproval");
        actionRequired.add("rationale");

        properties.putObject("plannerNotes").put("type", "string");

        ObjectNode memoryObj = properties.putObject("memory");
        memoryObj.put("type", "object");
        memoryObj.put("additionalProperties", false);
        ObjectNode memoryProps = memoryObj.putObject("properties");
        memoryProps.putObject("enabled").put("type", "boolean");
        memoryProps.putObject("messageCount").put("type", "integer");
        memoryProps.putObject("includedMessages").put("type", "integer");
        ArrayNode memoryRequired = memoryObj.putArray("required");
        memoryRequired.add("enabled");
        memoryRequired.add("messageCount");
        memoryRequired.add("includedMessages");

        ArrayNode required = schema.putArray("required");
        required.add("intent");
        required.add("context");
        required.add("entities");
        required.add("requiresRetrieval");
        required.add("plan");
        required.add("actions");
        required.add("plannerNotes");
        required.add("memory");

        return schema;
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
            throw new RuntimeException("OpenAI planner request failed with status " + status + ": " + responseBody);
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

        throw new IllegalStateException("No structured planner output found in OpenAI response.");
    }

    private ObjectNode sanitizePlanner(JsonNode planner, String question, String customerId, String storeId, JsonNode memory) {
        ObjectNode sanitized = mapper.createObjectNode();

        String intent = planner.path("intent").asText("knowledge_answer");
        if (!ALLOWED_INTENTS.contains(intent)) {
            intent = "knowledge_answer";
        }

        String extractedSku = firstMatch(SKU_PATTERN, question);
        String extractedOrderId = firstMatch(ORDER_ID_PATTERN, question);

        sanitized.put("intent", intent);

        ObjectNode context = sanitized.putObject("context");
        context.put("customerId", defaultString(planner.path("context").path("customerId").asText(""), customerId));
        context.put("storeId", defaultString(planner.path("context").path("storeId").asText(""), storeId));

        ObjectNode entities = sanitized.putObject("entities");
        String sku = defaultString(planner.path("entities").path("sku").asText(""), extractedSku);
        String orderId = defaultString(planner.path("entities").path("orderId").asText(""), extractedOrderId);

        entities.put("sku", sku);
        entities.put("orderId", orderId);
        entities.put("category", planner.path("entities").path("category").asText(""));
        entities.put("maxPrice", planner.path("entities").path("maxPrice").asInt(0));
        entities.put("wantsApprovalAction", wantsApprovalAction(question));

        sanitized.put("requiresRetrieval", true);

        ArrayNode plan = sanitized.putArray("plan");
        if (planner.path("plan").isArray()) {
            for (JsonNode step : planner.path("plan")) {
                plan.add(step.asText());
            }
        }
        if (plan.isEmpty()) {
            plan.add("Understand the customer goal and extract retail entities.");
            plan.add("Retrieve relevant product, policy, FAQ, and promotion context.");
            plan.add("Synthesize the final answer with citations and observations.");
        }

        ArrayNode actions = sanitized.putArray("actions");
        if (planner.path("actions").isArray()) {
            for (JsonNode action : planner.path("actions")) {
                ObjectNode safeAction = sanitizeAction(action, customerId, storeId, sku, orderId);
                if (safeAction != null) {
                    actions.add(safeAction);
                }
            }
        }

        enforceRequiredActionPatterns(actions, intent, question, customerId, storeId, sku, orderId);

        sanitized.put("plannerNotes", "Generated by BW6 OpenAI structured planner with deterministic safety validation.");

        ObjectNode memoryNode = sanitized.putObject("memory");
        memoryNode.put("enabled", memory.path("enabled").asBoolean(false));
        memoryNode.put("messageCount", memory.path("messageCount").asInt(0));
        memoryNode.put("includedMessages", memory.path("includedMessages").asInt(0));

        return sanitized;
    }

    private ObjectNode sanitizeAction(JsonNode action, String customerId, String storeId, String fallbackSku, String fallbackOrderId) {
        String toolName = action.path("toolName").asText("");

        if (!ALL_TOOLS.contains(toolName)) {
            return null;
        }

        String sku = defaultString(action.path("sku").asText(""), fallbackSku);
        String orderId = defaultString(action.path("orderId").asText(""), fallbackOrderId);
        String resolvedStoreId = defaultString(action.path("storeId").asText(""), storeId);
        String resolvedCustomerId = defaultString(action.path("customerId").asText(""), customerId);

        if (requiresSku(toolName) && !notBlank(sku)) {
            return null;
        }

        if (requiresOrderId(toolName) && !notBlank(orderId)) {
            return null;
        }

        if (requiresStoreId(toolName) && !notBlank(resolvedStoreId)) {
            return null;
        }

        if (requiresCustomerId(toolName) && !notBlank(resolvedCustomerId)) {
            return null;
        }

        boolean requiresApproval = WRITE_TOOLS.contains(toolName);
        if (READ_TOOLS.contains(toolName)) {
            requiresApproval = false;
        }

        ObjectNode safe = mapper.createObjectNode();
        safe.put("toolName", toolName);
        safe.put("sku", sku);
        safe.put("orderId", orderId);
        safe.put("storeId", resolvedStoreId);
        safe.put("customerId", resolvedCustomerId);
        safe.put("category", action.path("category").asText(""));
        safe.put("promotionId", action.path("promotionId").asText(""));
        safe.put("requiresApproval", requiresApproval);
        safe.put("rationale", action.path("rationale").asText("Selected by LLM planner."));
        return safe;
    }
    
    private boolean requiresSku(String toolName) {
        return "get_product".equals(toolName)
                || "check_inventory".equals(toolName)
                || "reserve_inventory".equals(toolName)
                || "apply_promotion".equals(toolName);
    }

    private boolean requiresOrderId(String toolName) {
        return "lookup_order".equals(toolName)
                || "check_return_eligibility".equals(toolName)
                || "create_return_authorization".equals(toolName);
    }

    private boolean requiresStoreId(String toolName) {
        return "check_inventory".equals(toolName)
                || "reserve_inventory".equals(toolName);
    }

    private boolean requiresCustomerId(String toolName) {
        return "find_promotions".equals(toolName)
                || "reserve_inventory".equals(toolName)
                || "apply_promotion".equals(toolName);
    }



    private void enforceRequiredActionPatterns(
            ArrayNode actions,
            String intent,
            String question,
            String customerId,
            String storeId,
            String sku,
            String orderId
    ) {
        if (notBlank(sku) && !hasAction(actions, "get_product")) {
            actions.insert(0, toolAction("get_product", sku, "", storeId, customerId, "", "", false, "Product SKU was provided."));
        }

        if ("inventory_lookup".equals(intent) && notBlank(sku) && !hasAction(actions, "check_inventory")) {
            actions.add(toolAction("check_inventory", sku, "", storeId, customerId, "", "", false, "Inventory status is needed."));
        }

        if ("reserve_inventory".equals(intent) && notBlank(sku)) {
            if (!hasAction(actions, "check_inventory")) {
                actions.add(toolAction("check_inventory", sku, "", storeId, customerId, "", "", false, "Inventory status is needed before reservation."));
            }
            if (!hasAction(actions, "reserve_inventory")) {
                actions.add(toolAction("reserve_inventory", sku, "", storeId, customerId, "", "", true, "Reservation changes store inventory state."));
            }
        }

        if ("return_flow".equals(intent) && notBlank(orderId)) {
            if (!hasAction(actions, "lookup_order")) {
                actions.add(toolAction("lookup_order", "", orderId, storeId, customerId, "", "", false, "Order ID was provided."));
            }
            if (!hasAction(actions, "check_return_eligibility")) {
                actions.add(toolAction("check_return_eligibility", "", orderId, storeId, customerId, "", "", false, "Return intent requires eligibility check."));
            }
            if (wantsReturnAuthorizationFromQuestion(question) && !hasAction(actions, "create_return_authorization")) {
                actions.add(toolAction("create_return_authorization", "", orderId, storeId, customerId, "", "", true, "Creating a return authorization changes order state."));
            }
        }

        if ("recommend_and_promote".equals(intent)) {
            if (!hasAction(actions, "find_promotions")) {
                actions.add(toolAction("find_promotions", sku, "", storeId, customerId, "", "", false, "Promotion context is required before applying a promotion."));
            }
            if (wantsPromotionApplicationFromQuestion(question) && !hasAction(actions, "apply_promotion")) {
                actions.add(toolAction("apply_promotion", sku, "", storeId, customerId, "", "", true, "Applying a promotion changes customer cart state."));
            }
        }
    }

    private ObjectNode toolAction(
            String toolName,
            String sku,
            String orderId,
            String storeId,
            String customerId,
            String category,
            String promotionId,
            boolean requiresApproval,
            String rationale
    ) {
        ObjectNode action = mapper.createObjectNode();
        action.put("toolName", toolName);
        action.put("sku", defaultString(sku, ""));
        action.put("orderId", defaultString(orderId, ""));
        action.put("storeId", defaultString(storeId, ""));
        action.put("customerId", defaultString(customerId, ""));
        action.put("category", defaultString(category, ""));
        action.put("promotionId", defaultString(promotionId, ""));
        action.put("requiresApproval", WRITE_TOOLS.contains(toolName) || requiresApproval);
        action.put("rationale", rationale);
        return action;
    }

    private boolean hasAction(ArrayNode actions, String toolName) {
        for (JsonNode action : actions) {
            if (toolName.equals(action.path("toolName").asText())) {
                return true;
            }
        }
        return false;
    }

    private boolean wantsApprovalAction(String question) {
        return wantsReturnAuthorizationFromQuestion(question)
                || wantsPromotionApplicationFromQuestion(question)
                || containsAny(question, "reserve", "hold");
    }

    private boolean wantsReturnAuthorizationFromQuestion(String question) {
        String lower = question == null ? "" : question.toLowerCase();
        return lower.matches(".*create\\s+(a\\s+)?return.*")
                || lower.contains("return authorization");
    }

    private boolean wantsPromotionApplicationFromQuestion(String question) {
        String lower = question == null ? "" : question.toLowerCase();

        boolean hasApplyVerb =
                lower.contains("apply")
                        || lower.contains("add")
                        || lower.contains("use")
                        || lower.contains("redeem");

        boolean hasPromotionTerm =
                lower.contains("promotion")
                        || lower.contains("promo")
                        || lower.contains("discount")
                        || lower.contains("coupon");

        return hasApplyVerb && hasPromotionTerm;
    }

    private boolean containsAny(String value, String... terms) {
        String lower = value == null ? "" : value.toLowerCase();
        for (String term : terms) {
            if (lower.contains(term)) return true;
        }
        return false;
    }

    private String firstMatch(Pattern pattern, String text) {
        if (text == null) return "";
        Matcher matcher = pattern.matcher(text);
        return matcher.find() ? matcher.group(0).toUpperCase() : "";
    }

    private JsonNode parseMemory(String memoryJson) {
        if (memoryJson == null || memoryJson.trim().isEmpty()) {
            ObjectNode empty = mapper.createObjectNode();
            empty.put("enabled", false);
            empty.put("messageCount", 0);
            empty.put("includedMessages", 0);
            empty.put("summary", "");
            return empty;
        }

        try {
            return mapper.readTree(memoryJson);
        } catch (Exception ignored) {
            ObjectNode empty = mapper.createObjectNode();
            empty.put("enabled", false);
            empty.put("messageCount", 0);
            empty.put("includedMessages", 0);
            empty.put("summary", "");
            return empty;
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

    private boolean notBlank(String value) {
        return value != null && !value.trim().isEmpty();
    }

    private String envOrDefault(String key, String fallback) {
        String value = System.getenv(key);
        return value == null || value.trim().isEmpty() ? fallback : value;
    }
}
