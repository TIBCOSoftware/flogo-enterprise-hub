const API_BASES = {
  agent: "http://localhost:18085",
  operations: "http://localhost:18084",
  ingestion: "http://localhost:18083"
};

const state = {
  conversationId: null,
  lastResult: null,
  scenarios: [],
  users: [],
  selectedUser: null
};

const elements = {
  serverStatus: document.querySelector("#serverStatus"),
  metrics: document.querySelector("#metrics"),
  chunkList: document.querySelector("#chunkList"),
  runIngest: document.querySelector("#runIngest"),
  uploadForm: document.querySelector("#uploadForm"),
  uploadFile: document.querySelector("#uploadFile"),
  uploadType: document.querySelector("#uploadType"),
  uploadHistory: document.querySelector("#uploadHistory"),
  scenarioList: document.querySelector("#scenarioList"),
  examples: document.querySelector("#examples"),
  queryForm: document.querySelector("#queryForm"),
  userId: document.querySelector("#userId"),
  question: document.querySelector("#question"),
  chatLog: document.querySelector("#chatLog"),
  customerId: document.querySelector("#customerId"),
  storeId: document.querySelector("#storeId")
};

function apiBaseForPath(path) {
  if (path === "/api/query") return API_BASES.agent;

  if (path === "/api/ingest" || path === "/api/upload" || path === "/api/uploads") {
    return API_BASES.ingestion;
  }

  return API_BASES.operations;
}

async function requestJson(path, options = {}) {
  const response = await fetch(`${apiBaseForPath(path)}${path}`, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(options.headers || {})
    }
  });

  const contentType = response.headers.get("content-type") || "";
  const body = contentType.includes("application/json") ? await response.json() : await response.text();

  if (!response.ok) {
    throw new Error(typeof body === "string" ? body : body.error || JSON.stringify(body));
  }

  return body;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formatDate(value) {
  if (!value) return "Not set";
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function normalizeRole(role) {
  return String(role || "")
    .trim()
    .toLowerCase()
    .replaceAll("-", "_")
    .replace(/\s+/g, "_");
}

function canApprove(user) {
  const role = normalizeRole(user?.role);
  return role === "admin" || role === "store_manager" || user?.canApprove === true;
}

function selectedUserCanApprove() {
  const option = elements.userId?.selectedOptions?.[0];

  const roleFromState = normalizeRole(state.selectedUser?.role);
  const roleFromOption = normalizeRole(option?.dataset.role);
  const textFromOption = normalizeRole(option?.textContent);

  return (
    roleFromState === "admin" ||
    roleFromState === "store_manager" ||
    roleFromOption === "admin" ||
    roleFromOption === "store_manager" ||
    textFromOption.includes("admin") ||
    textFromOption.includes("store_manager")
  );
}


function refreshSelectedUser() {
  const userId = elements.userId?.value;
  state.selectedUser = state.users.find((user) => user.userId === userId) || null;
}

function refreshApprovalButtons() {
  const allowed = selectedUserCanApprove();

  document.querySelectorAll("[data-approve-button]").forEach((button) => {
    const status = normalizeRole(button.dataset.approvalStatus);
    const hasApprovalId = Boolean(button.dataset.approvalId);

    button.disabled = !(allowed && hasApprovalId && status === "pending");
  });
}

function setStatusPill(label, mode = "ready") {
  if (!elements.serverStatus) return;
  elements.serverStatus.textContent = label;
  elements.serverStatus.dataset.mode = mode;
}

function renderStatus(status = {}) {
  setStatusPill("Ready", "ready");

  const dataset = status.dataset || {};
  const ingestion = status.ingestion || {};
  const embedding = ingestion.embedding || {};
  const storage = ingestion.storage || {};

  const metrics = [
    ["Products", dataset.products ?? 0],
    ["Inventory", dataset.inventory ?? 0],
    ["Customers", dataset.customers ?? 0],
    ["Orders", dataset.orders ?? 0],
    ["Policies", dataset.policies ?? 0],
    ["Chunks", ingestion.chunkCount ?? 0],
    ["Embedding", embedding.provider ?? "stub"],
    ["Storage", storage.provider ?? "pending"]
  ];

  if (elements.metrics) {
    elements.metrics.innerHTML = metrics
      .map(([label, value]) => `<div class="metric"><strong>${escapeHtml(value)}</strong><span>${escapeHtml(label)}</span></div>`)
      .join("");
  }

  const chunks = (ingestion.sampleChunks || []).filter(Boolean);
  if (elements.chunkList) {
    elements.chunkList.innerHTML = chunks.length
      ? chunks
          .map(
            (chunk) => `
              <article class="chunk">
                <div class="chunk-title">
                  <span>${escapeHtml(chunk.title || chunk.id || "Indexed source")}</span>
                  <span class="tag">${escapeHtml(chunk.documentType || chunk.type || "document")}</span>
                </div>
                <p>${escapeHtml(chunk.tokenCount ?? chunk.termCount ?? 0)} indexed terms</p>
              </article>
            `
          )
          .join("")
      : `<article class="chunk"><div class="chunk-title">No indexed sources yet</div><p>Run ingestion or upload a document.</p></article>`;
  }

  renderUploadHistory(ingestion.uploads || []);
}

function renderUploadHistory(uploads = []) {
  if (!elements.uploadHistory) return;

  if (!uploads.length) {
    elements.uploadHistory.innerHTML = `
      <article class="chunk">
        <div class="chunk-title">No uploads yet</div>
        <p>Upload PDFs, Markdown, CSV, JSON catalogs, or text files.</p>
      </article>
    `;
    return;
  }

  elements.uploadHistory.innerHTML = uploads
    .filter(Boolean)
    .map(
      (upload) => `
        <article class="chunk ${upload.status === "failed" ? "warning" : ""}">
          <div class="chunk-title">
            <span>${escapeHtml(upload.fileName || "Uploaded file")}</span>
            <span class="tag">${escapeHtml(upload.status || "uploaded")}</span>
          </div>
          <div class="upload-facts">
            <span>${escapeHtml(upload.productCount ?? 0)} products</span>
            <span>${escapeHtml(upload.documentCount ?? 0)} docs</span>
            <span>${escapeHtml(upload.chunkCount ?? 0)} chunks</span>
          </div>
          <p class="muted">${escapeHtml(formatDate(upload.uploadedAt))}</p>
        </article>
      `
    )
    .join("");
}

function renderInlineCitations(citations = []) {
  const visible = citations.filter(Boolean).slice(0, 5);
  if (!visible.length) return "";

  return `
    <div class="message-citations">
      ${visible
        .map(
          (citation) => `
            <span class="citation-chip">
              ${escapeHtml(citation.title || citation.id || "Citation")}
              ${citation.documentType ? `<span>${escapeHtml(citation.documentType)}</span>` : ""}
            </span>
          `
        )
        .join("")}
    </div>
  `;
}

function formatToolResultSummary(result = {}) {
  if (result.skipped) {
    return result.reason || "Skipped";
  }

  if (result.status && result.quantity !== undefined) {
    return `${result.status}${result.quantity !== undefined ? `, ${result.quantity} units` : ""}`;
  }

  if (result.eligible !== undefined) {
    return result.eligible ? "Eligible" : "Not eligible";
  }

  if (Array.isArray(result.promotions)) {
    return `${result.promotions.length} promotion${result.promotions.length === 1 ? "" : "s"}`;
  }

  if (result.name) {
    return result.name;
  }

  if (result.message) {
    return result.message;
  }

  if (result.text) {
    return result.text;
  }

  return "Completed";
}

function renderInlineToolCalls(toolCalls = []) {
  const visible = toolCalls.filter(Boolean);
  if (!visible.length) return "";

  return `
    <details class="message-tools">
      <summary>Tool calls (${visible.length})</summary>
      <div class="message-tool-list">
        ${visible
          .map((toolCall) => {
            const result = toolCall.result || {};
            const args = toolCall.arguments || {};
            const transport = toolCall.transport || "tool";
            const summary = formatToolResultSummary(result);

            return `
              <article class="message-tool-call ${result.skipped ? "skipped" : ""}">
                <div class="message-tool-title">
                  <span>${escapeHtml(toolCall.name || toolCall.toolName || "tool")}</span>
                  <span class="tag">${escapeHtml(transport)}</span>
                </div>
                <div class="message-tool-facts">
                  ${toolCall.safety ? `<span>${escapeHtml(toolCall.safety)}</span>` : ""}
                  ${toolCall.gateway ? `<span>${escapeHtml(toolCall.gateway)}</span>` : ""}
                  <span>${escapeHtml(summary)}</span>
                </div>
                <pre>${escapeHtml(JSON.stringify({ arguments: args, result }, null, 2))}</pre>
              </article>
            `;
          })
          .join("")}
      </div>
    </details>
  `;
}

function addMessage(role, text, options = {}) {
  if (!elements.chatLog) return;

  const item = document.createElement("article");
  item.className = `message ${role}`;

  const approval = hasRealPendingApproval(options.pendingApproval)
    ? options.pendingApproval
    : null;

  const approvalId = approval?.approvalId || "";
  const approvalStatus = approval?.status || "";
  const approvalAllowed = selectedUserCanApprove();
  const approvalIsPending = normalizeRole(approvalStatus) === "pending";

  const approvalHtml = approval
    ? `
      <div class="approval-actions">
        <p class="muted">${approvalAllowed ? "Current user can approve this action." : "Only managers and admins can approve this action."}</p>
        <button
          type="button"
          data-approve-button="true"
          data-approval-id="${escapeHtml(approvalId)}"
          data-approval-status="${escapeHtml(approvalStatus)}"
          ${approvalAllowed && approvalId && approvalIsPending ? "" : "disabled"}
        >
          Approve Action
        </button>
      </div>
    `
    : "";

  item.innerHTML = `
    <span class="role">${role === "user" ? "You" : "Copilot"}</span>
    <p>${escapeHtml(text)}</p>
    ${role === "assistant" ? renderInlineCitations(options.citations) : ""}
    ${role === "assistant" ? renderInlineToolCalls(options.toolCalls) : ""}
    ${approvalHtml}
  `;

  const button = item.querySelector("button[data-approve-button]");
  if (button) {
    button.addEventListener("click", () => approveAction(button.dataset.approvalId));
  }

  elements.chatLog.append(item);
  elements.chatLog.scrollTop = elements.chatLog.scrollHeight;
}

function hasRealPendingApproval(approval) {
  return Boolean(
    approval &&
      (approval.approvalId || approval.approval_id) &&
      String(approval.status || "").toLowerCase() === "pending"
  );
}


function renderExamples(items = []) {
  if (!elements.examples) return;

  elements.examples.innerHTML = items
    .filter(Boolean)
    .map((example) => `<button type="button" data-example="${escapeHtml(example)}">${escapeHtml(example)}</button>`)
    .join("");

  elements.examples.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", () => {
      if (!elements.question) return;
      elements.question.value = button.dataset.example;
      elements.question.focus();
    });
  });
}

function renderScenarios(scenarios = []) {
  state.scenarios = scenarios.filter(Boolean);
  if (!elements.scenarioList) return;

  elements.scenarioList.innerHTML = state.scenarios
    .map(
      (scenario, index) => `
        <article class="scenario-card">
          <div class="scenario-index">${index + 1}</div>
          <div>
            <div class="operation-title"><span>${escapeHtml(scenario.title || scenario.id || "Scenario")}</span></div>
            <p>${escapeHtml(scenario.goal || scenario.question || "")}</p>
            <div class="trace-facts">
              ${(scenario.expected || []).map((item) => `<span>${escapeHtml(item)}</span>`).join("")}
            </div>
            <div class="scenario-actions">
              <button type="button" data-scenario-id="${escapeHtml(scenario.id)}" data-action="load">Load</button>
              <button type="button" data-scenario-id="${escapeHtml(scenario.id)}" data-action="run">Run</button>
            </div>
          </div>
        </article>
      `
    )
    .join("");
}

function selectScenario(scenario) {
  if (elements.userId && scenario.userId) {
    elements.userId.value = scenario.userId;
    refreshSelectedUser();
    refreshApprovalButtons();
  }

  if (elements.customerId && scenario.customerId) elements.customerId.value = scenario.customerId;
  if (elements.storeId && scenario.storeId) elements.storeId.value = scenario.storeId;
  if (elements.question) {
    elements.question.value = scenario.question || "";
    elements.question.focus();
  }
}

function renderUsers(users = []) {
  if (!elements.userId) return;

  state.users = users.filter(Boolean);

  elements.userId.innerHTML = state.users
    .map((user) => {
      const userId = user.userId || user.id || "";
      const role = normalizeRole(user.role);
      const canApproveByRole = role === "admin" || role === "store_manager";
      const label = `${user.name || userId} - ${role.replaceAll("_", " ")}`;

      return `
        <option
          value="${escapeHtml(userId)}"
          data-role="${escapeHtml(role)}"
          data-can-approve="${canApproveByRole}"
        >
          ${escapeHtml(label)}
        </option>
      `;
    })
    .join("");

  refreshSelectedUser();
  refreshApprovalButtons();
}


async function approveAction(approvalId) {
  if (!approvalId) {
    addMessage("assistant", "Approval failed: approval id is missing.");
    return;
  }

  const result = await requestJson("/api/approve", {
    method: "POST",
    body: JSON.stringify({
      approvalId,
      userId: elements.userId?.value,
      conversationId: state.conversationId
    })
  });

  document.querySelectorAll(`[data-approval-id="${CSS.escape(approvalId)}"]`).forEach((button) => {
    button.disabled = true;
    button.dataset.approvalStatus = "approved";
    button.textContent = "Approved";
  });

  addMessage(
    "assistant",
    `Approved action completed by ${result.approvedBy?.name || "approver"}: ${result.result?.message || "Action executed."}`
  );

  state.lastResult = { ...(state.lastResult || {}), pendingApproval: null };
  await loadStatus();
}

async function loadStatus() {
  const status = await requestJson("/api/status");
  renderStatus(status);
}

async function loadExamples() {
  try {
    const data = await requestJson("/api/examples");
    renderExamples(data.examples || data || []);
  } catch {
    renderExamples([
      "Is RUN-PEG-001 available at SFO-001?",
      "Reserve RUN-PEG-001 at SFO-001 for CUST-001.",
      "Can I return order ORD-1001?",
      "Create a return for order ORD-1001.",
      "What is the electronics return policy?"
    ]);
  }
}

async function loadScenarios() {
  try {
    const data = await requestJson("/api/demo/scenarios");
    renderScenarios(data.scenarios || data || []);
  } catch {
    renderScenarios([]);
  }
}

async function loadUsers() {
  const data = await requestJson("/api/users");
  renderUsers(data.users || data || []);
}

async function runIngestion() {
  if (!elements.runIngest) return;

  elements.runIngest.disabled = true;
  elements.runIngest.textContent = "Running";

  const ingestRequest = {
    source: "seed",
    documentTypes: ["policy", "faq", "promotion"],
    resetCollection: false
  };

  try {
    const response = await requestJson("/api/ingest", {
      method: "POST",
      body: JSON.stringify(ingestRequest)
    });

    renderStatus(response.status || response);
  } catch (error) {
    addMessage("assistant", `Ingestion failed: ${error.message}`);
  } finally {
    elements.runIngest.disabled = false;
    elements.runIngest.textContent = "Run";
  }
}


function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();

    reader.addEventListener("load", () => {
      const result = String(reader.result);
      resolve(result.includes(",") ? result.split(",")[1] : result);
    });

    reader.addEventListener("error", () => reject(reader.error));
    reader.readAsDataURL(file);
  });
}

async function uploadSelectedFile() {
  const file = elements.uploadFile?.files?.[0];

  if (!file) {
    addMessage("assistant", "Choose a file before uploading.");
    return;
  }

  const contentBase64 = await fileToBase64(file);
  const response = await requestJson("/api/upload", {
    method: "POST",
    body: JSON.stringify({
      fileName: file.name,
      mimeType: file.type || "application/octet-stream",
      declaredType: elements.uploadType?.value || "auto",
      contentBase64
    })
  });

  renderStatus(response.status || response);

  if (response.upload) {
    addMessage(
      "assistant",
      `${response.upload.fileName} parsed with ${response.upload.chunkCount ?? 0} chunks and ${response.upload.errors?.length || 0} parsing errors.`
    );
  } else {
    addMessage("assistant", "Upload completed.");
  }
}

async function askQuestion(question) {
  addMessage("user", question);

  if (elements.question) {
    elements.question.value = "";
  }

  const result = await requestJson("/api/query", {
    method: "POST",
    body: JSON.stringify({
      question,
      userId: elements.userId?.value,
      customerId: elements.customerId?.value,
      storeId: elements.storeId?.value,
      conversationId: state.conversationId
    })
  });

  state.lastResult = result;
  state.conversationId = result.conversation?.conversationId || state.conversationId;

  addMessage("assistant", result.answer || "No answer returned.", {
    citations: result.citations || [],
    toolCalls: result.toolCalls || [],
    pendingApproval: result.pendingApproval
  });

  await loadStatus();
}

function bindEvents() {
  elements.runIngest?.addEventListener("click", runIngestion);

  elements.userId?.addEventListener("change", () => {
    refreshSelectedUser();
    refreshApprovalButtons();
  });

  elements.scenarioList?.addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-scenario-id]");
    if (!button) return;

    const scenario = state.scenarios.find((item) => item.id === button.dataset.scenarioId);
    if (!scenario) return;

    selectScenario(scenario);

    if (button.dataset.action === "run") {
      button.disabled = true;
      button.textContent = "Running";

      try {
        await askQuestion(scenario.question);
      } finally {
        button.disabled = false;
        button.textContent = "Run";
      }
    }
  });

  elements.uploadForm?.addEventListener("submit", async (event) => {
    event.preventDefault();

    const button = elements.uploadForm.querySelector("button");
    if (button) {
      button.disabled = true;
      button.textContent = "Uploading";
    }

    try {
      await uploadSelectedFile();
    } catch (error) {
      addMessage("assistant", `Upload failed: ${error.message}`);
    } finally {
      if (button) {
        button.disabled = false;
        button.textContent = "Upload";
      }
    }
  });

  elements.queryForm?.addEventListener("submit", async (event) => {
    event.preventDefault();

    const question = elements.question?.value.trim();
    if (!question) return;

    const submitButton = elements.queryForm.querySelector("button");
    if (submitButton) {
      submitButton.disabled = true;
      submitButton.textContent = "Thinking";
    }

    try {
      await askQuestion(question);
    } catch (error) {
      addMessage("assistant", `Request failed: ${error.message}`);
    } finally {
      if (submitButton) {
        submitButton.disabled = false;
        submitButton.textContent = "Ask";
      }
    }
  });
}

async function init() {
  setStatusPill("Starting", "loading");
  bindEvents();

  try {
    await Promise.all([loadStatus(), loadExamples(), loadScenarios(), loadUsers()]);
    setStatusPill("Ready", "ready");
    addMessage("assistant", "Choose a guided scenario or ask a retail question to start the demo.");
  } catch (error) {
    setStatusPill("API error", "error");
    addMessage("assistant", `Startup failed: ${error.message}`);
  }
}

await init();
