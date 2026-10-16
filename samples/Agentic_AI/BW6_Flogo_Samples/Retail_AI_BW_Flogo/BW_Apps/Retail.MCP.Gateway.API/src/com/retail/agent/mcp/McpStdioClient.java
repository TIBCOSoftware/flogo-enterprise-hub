package com.retail.agent.mcp;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;

public class McpStdioClient implements AutoCloseable {

    private final ObjectMapper mapper = new ObjectMapper();
    private final AtomicLong idCounter = new AtomicLong(1);

    private final Process process;
    private final BufferedWriter stdin;
    private final BufferedReader stdout;
    private final Thread stderrDrainer;

    public McpStdioClient(String command, List<String> args) throws IOException {
        List<String> processCommand = new ArrayList<>();
        processCommand.add(command);
        processCommand.addAll(args);

        ProcessBuilder builder = new ProcessBuilder(processCommand);
        builder.redirectErrorStream(false);

        this.process = builder.start();
        this.stdin = new BufferedWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8));
        this.stdout = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8));

        this.stderrDrainer = new Thread(() -> {
            try (BufferedReader err = new BufferedReader(new InputStreamReader(process.getErrorStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = err.readLine()) != null) {
                    System.err.println("[mcp-stdio] " + line);
                }
            } catch (IOException ignored) {
            }
        });
        this.stderrDrainer.setDaemon(true);
        this.stderrDrainer.start();
    }

    public static McpStdioClient forBw6Remote() throws IOException {
        // Resolve the npx launcher per-OS: "npx.cmd" on Windows, "npx" elsewhere.
        // Relies on npx being on PATH (install Node.js). Override with the MCP_NPX env var.
        String npxEnv = System.getenv("MCP_NPX");
        String npx = npxEnv != null && !npxEnv.isEmpty()
                ? npxEnv
                : (System.getProperty("os.name", "").toLowerCase().contains("win") ? "npx.cmd" : "npx");
        String mcpUrl = System.getenv().getOrDefault("MCP_REMOTE_URL", "http://localhost:18000/rest/mcp");
        return new McpStdioClient(
                npx,
                List.of("mcp-remote", mcpUrl, "--allow-http")
        );
    }

    public JsonNode initialize() throws IOException {
        ObjectNode params = mapper.createObjectNode();

        ObjectNode protocolVersion = params.putObject("clientInfo");
        protocolVersion.put("name", "retail-bw6-java-agent");
        protocolVersion.put("version", "1.0.0");

        params.put("protocolVersion", "2024-11-05");
        params.putObject("capabilities");

        JsonNode response = sendRequest("initialize", params);
        sendNotification("notifications/initialized", mapper.createObjectNode());
        return response;
    }

    public JsonNode listTools() throws IOException {
        return sendRequest("tools/list", mapper.createObjectNode());
    }

    public String callTool(String toolName, String argumentsJson) throws IOException {
        JsonNode arguments = argumentsJson == null || argumentsJson.trim().isEmpty()
                ? mapper.createObjectNode()
                : mapper.readTree(argumentsJson);

        ObjectNode params = mapper.createObjectNode();
        params.put("name", toolName);
        params.set("arguments", arguments);

        JsonNode response = sendRequest("tools/call", params);
        return extractToolText(response);
    }

    public boolean isAlive() {
        return process.isAlive();
    }

    private synchronized JsonNode sendRequest(String method, JsonNode params) throws IOException {
        long id = idCounter.getAndIncrement();

        ObjectNode request = mapper.createObjectNode();
        request.put("jsonrpc", "2.0");
        request.put("id", id);
        request.put("method", method);
        request.set("params", params == null ? mapper.createObjectNode() : params);

        writeJsonLine(request);

        while (true) {
            String line = stdout.readLine();
            if (line == null) {
                throw new EOFException("MCP server closed stdout while waiting for response to " + method);
            }

            if (line.trim().isEmpty()) {
                continue;
            }

            JsonNode message = mapper.readTree(line);

            if (message.has("id") && message.path("id").asLong() == id) {
                if (message.has("error")) {
                    throw new IOException("MCP error for " + method + ": " + message.path("error").toString());
                }
                return message.path("result");
            }
        }
    }

    private void sendNotification(String method, JsonNode params) throws IOException {
        ObjectNode notification = mapper.createObjectNode();
        notification.put("jsonrpc", "2.0");
        notification.put("method", method);
        notification.set("params", params == null ? mapper.createObjectNode() : params);

        writeJsonLine(notification);
    }

    private void writeJsonLine(JsonNode node) throws IOException {
        stdin.write(mapper.writeValueAsString(node));
        stdin.write("\n");
        stdin.flush();
    }

    private String extractToolText(JsonNode result) throws IOException {
        JsonNode content = result.path("content");

        if (content.isArray()) {
            ArrayNode texts = mapper.createArrayNode();

            for (JsonNode item : content) {
                if ("text".equals(item.path("type").asText())) {
                    texts.add(item.path("text").asText());
                }
            }

            if (texts.size() == 1) {
                return texts.get(0).asText();
            }

            return mapper.writeValueAsString(texts);
        }

        return result.toString();
    }

    @Override
    public void close() {
        try {
            stdin.close();
        } catch (IOException ignored) {
        }

        process.destroy();

        try {
            if (!process.waitFor(Duration.ofSeconds(3).toMillis(), java.util.concurrent.TimeUnit.MILLISECONDS)) {
                process.destroyForcibly();
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
            process.destroyForcibly();
        }
    }
}
