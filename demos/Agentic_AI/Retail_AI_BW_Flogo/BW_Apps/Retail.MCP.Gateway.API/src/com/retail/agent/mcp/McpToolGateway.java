package com.retail.agent.mcp;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

public class McpToolGateway {

    private final ObjectMapper mapper = new ObjectMapper();

    private static McpStdioClient sharedClient;
    private static final Object lock = new Object();

    private McpStdioClient getClient() throws Exception {
        synchronized (lock) {
            if (sharedClient == null || !sharedClient.isAlive()) {
                if (sharedClient != null) {
                    try { sharedClient.close(); } catch (Exception ignored) {}
                }
                sharedClient = McpStdioClient.forBw6Remote();
                sharedClient.initialize();
            }
            return sharedClient;
        }
    }

    public String listTools() throws Exception {
        McpStdioClient client = getClient();
        JsonNode tools = client.listTools();

        ObjectNode response = mapper.createObjectNode();
        response.put("status", "ok");
        response.set("tools", tools.path("tools"));
        response.put("transport", "stdio");
        response.put("gateway", "java-mcp-client");

        return mapper.writeValueAsString(response);
    }

    public String callTool(String toolName, String argumentsJson) throws Exception {
        if (toolName == null || toolName.trim().isEmpty()) {
            return error("toolName is required.");
        }

        String safeArgumentsJson = argumentsJson == null || argumentsJson.trim().isEmpty()
                ? "{}"
                : argumentsJson;

        McpStdioClient client = getClient();
        String toolResult = client.callTool(toolName, safeArgumentsJson);

        ObjectNode response = mapper.createObjectNode();
        response.put("status", "ok");
        response.put("toolName", toolName);
        response.set("arguments", mapper.readTree(safeArgumentsJson));
        response.set("result", parsePossiblyJson(toolResult));
        response.put("transport", "stdio");
        response.put("gateway", "java-mcp-client");

        return mapper.writeValueAsString(response);
    }

    private JsonNode parsePossiblyJson(String value) {
        if (value == null || value.trim().isEmpty()) {
            return mapper.createObjectNode();
        }

        try {
            return mapper.readTree(value);
        } catch (Exception ignored) {
            ObjectNode node = mapper.createObjectNode();
            node.put("text", value);
            return node;
        }
    }

    private String error(String message) throws Exception {
        ObjectNode response = mapper.createObjectNode();
        response.put("status", "error");
        response.put("message", message);
        return mapper.writeValueAsString(response);
    }
}
