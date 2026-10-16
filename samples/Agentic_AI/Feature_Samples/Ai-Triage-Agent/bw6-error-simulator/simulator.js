/**
 * BW6 Container Edition Error Simulator
 *
 * Modes:
 *   single  -> emit 1 random event
 *   storm   -> emit N events with heavy duplication (to prove noise reduction)
 *   edge    -> emit carefully crafted cases (bad-data, cross-app, low-confidence)
 *
 * Usage:
 *   node simulator.js --mode=storm --count=50 --target=http://localhost:8080/triage
 *   node simulator.js --mode=single
 *   node simulator.js --mode=edge
 *
 * If --target points at the triage agent, events flow through AI.
 * If --bypass is set, events go straight to mock ServiceNow (baseline noise).
 */
const http = require('http');
const https = require('https');
const { URL } = require('url');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const CATALOG = JSON.parse(fs.readFileSync(path.join(__dirname, 'bw6-error-catalog.json'), 'utf8'));

// ---- args ----
const args = Object.fromEntries(
    process.argv.slice(2).map(a => {
        const [k, v] = a.replace(/^--/, '').split('=');
        return [k, v === undefined ? true : v];
    })
);
const MODE = args.mode || 'single';
const COUNT = parseInt(args.count || '10', 10);
const TARGET = args.target || process.env.TARGET || 'http://localhost:8080/triage';
const BYPASS_TARGET = args.bypassTarget || process.env.BYPASS_TARGET || 'http://localhost:8081/api/now/table/incident';
const BYPASS = !!args.bypass;
const DELAY_MS = parseInt(args.delayMs || '200', 10);

// ---- helpers ----
const pick = arr => arr[Math.floor(Math.random() * arr.length)];
const podSuffix = () => Math.floor(Math.random() * 5);
const cid = () => crypto.randomUUID();

function buildEvent(template, overrides = {}) {
    const now = new Date().toISOString();
    return {
        timestamp: now,
        appName: template.appName,
        appNode: `${template.appNodePrefix}-${podSuffix()}`,
        processName: template.processName,
        activityName: template.activityName,
        errorCode: template.errorCode,
        errorMsg: template.messageTemplate,
        stackTrace: template.stackTraceTemplate,
        correlationId: cid(),
        severity: template.severity,
        ...overrides
    };
}

function buildBadData() {
    // Randomly chosen bad-data flavor
    const flavors = [
        { errorCode: '', errorMsg: 'null', appName: '', severity: '' }, // missing fields
        { errorCode: '???', errorMsg: '\x00\x00garbled\x00', appName: '???' }, // garbage
        { /* empty */ }
    ];
    return { timestamp: new Date().toISOString(), correlationId: cid(), ...pick(flavors) };
}

// ---- event generators ----
function genSingle(n) {
    return Array.from({ length: n }, () => buildEvent(pick(CATALOG)));
}

function genStorm(n) {
    // Pick 3 "real" issues, then blast duplicates of them. Sprinkle 2 bad-data events.
    const chosen = [
        CATALOG.find(c => c.id === 'E1'),
        CATALOG.find(c => c.id === 'E2'),
        CATALOG.find(c => c.id === 'E4')
    ];
    const events = [];
    const badDataCount = 2;
    const uniqueCount = chosen.length;
    const duplicatesPerIssue = Math.max(0, n - uniqueCount - badDataCount);

    // Seed: one of each unique
    for (const c of chosen) events.push(buildEvent(c));

    // Duplicates: same errorCode + same appName, slight variation of node/correlation
    for (let i = 0; i < duplicatesPerIssue; i++) {
        const c = chosen[i % chosen.length];
        events.push(buildEvent(c));
    }

    // Bad data
    for (let i = 0; i < badDataCount; i++) events.push(buildBadData());

    // Shuffle
    for (let i = events.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [events[i], events[j]] = [events[j], events[i]];
    }
    return events;
}

function genEdge() {
    // Curated edge cases — ordered so the LOW-CONFIDENCE event fires as early as possible (position 2).
    // Event 1 (ChargeCard REST-500) must exist first so the agent has a candidate to compare against.
    const e1 = CATALOG.find(c => c.id === 'E1');
    const e3 = CATALOG.find(c => c.id === 'E3');
    return [
        // 1. REST 500 on PaymentService/ChargeCard (new) — seeds the candidate for event 2
        buildEvent(e3),
        // 2. LOW-CONFIDENCE: same app + same errorCode BUT different processName AND completely
        //    different downstream service (fraud-check.internal vs partner.stripe.example).
        //    The pre-seeded ChargeCard incident is guaranteed to be in the store, so the search
        //    returns N=1. The agent scores LOW conf (<0.75) → creates new ticket + warns on seed.
        buildEvent(e3, {
            appNode: 'paymentservice-appnode-7',
            processName: 'PaymentFlow.process.FraudScreening',
            activityName: 'InvokeRESTService',
            errorCode: 'BW-REST-500',
            errorMsg: 'Downstream service returned HTTP 500 Internal Server Error from https://fraud-check.internal/screen — fraud screening service unavailable',
            severity: '2 - High',
            stackTrace: 'com.tibco.bw.palette.rest.RESTPluginException: Non-2xx response from downstream\n\tat com.tibco.bw.palette.rest.runtime.InvokeRESTServiceActivity.processResponse(InvokeRESTServiceActivity.java:342)\nCaused by: java.io.IOException: Server returned HTTP response code: 500 for URL: https://fraud-check.internal/screen'
        }),
        // 3. JDBC timeout on OrderService (new)
        buildEvent(e1),
        // 4. Same JDBC timeout on OrderService again (duplicate)
        buildEvent(e1),
        // 5. Same JDBC timeout BUT on PaymentService (sneaky NEW — different app, different owner)
        buildEvent(e1, {
            appName: 'PaymentService',
            appNode: 'paymentservice-appnode-2',
            processName: 'PaymentFlow.process.PersistTransaction'
        }),
        // 6. Obvious duplicate of event 1 — same process, same message
        buildEvent(e3),
        // 7. Bad data
        buildBadData()
    ];
}

// ---- transport ----
function post(targetUrl, body) {
    return new Promise((resolve, reject) => {
        const u = new URL(targetUrl);
        const lib = u.protocol === 'https:' ? https : http;
        const data = JSON.stringify(body);
        const req = lib.request(
            {
                method: 'POST',
                hostname: u.hostname,
                port: u.port || (u.protocol === 'https:' ? 443 : 80),
                path: u.pathname + u.search,
                headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) }
            },
            res => {
                let chunks = '';
                res.on('data', c => (chunks += c));
                res.on('end', () => resolve({ status: res.statusCode, body: chunks }));
            }
        );
        req.on('error', reject);
        req.write(data);
        req.end();
    });
}

function toBypassIncident(evt) {
    // If bypassing agent, every event becomes a raw incident (baseline noise)
    return {
        short_description: `[${evt.errorCode || 'UNKNOWN'}] ${evt.appName || 'unknown-app'} - ${evt.activityName || 'unknown-activity'}`,
        description: evt.errorMsg || '',
        severity: evt.severity || '3 - Moderate',
        u_error_code: evt.errorCode || '',
        u_app_name: evt.appName || '',
        u_app_node: evt.appNode || '',
        u_process_name: evt.processName || '',
        u_activity_name: evt.activityName || '',
        u_correlation_id: evt.correlationId || '',
        u_decision_source: 'bypass-baseline'
    };
}

// ---- main ----
async function run() {
    let events;
    if (MODE === 'storm') events = genStorm(COUNT);
    else if (MODE === 'edge') {
        const script = genEdge();
        events = Array.from({ length: COUNT }, (_, i) => ({ ...script[i % script.length], correlationId: cid() }));
    }
    else events = genSingle(COUNT);

    const destination = BYPASS ? BYPASS_TARGET : TARGET;
    console.log(`[simulator] mode=${MODE} count=${events.length} target=${destination} bypass=${BYPASS}`);

    // Edge mode (non-bypass): pre-seed the ChargeCard incident DIRECTLY into the ServiceNow
    // store before any events reach the triage agent. This guarantees the agent always finds
    // a candidate when the FraudScreening (low-confidence) event arrives, regardless of how
    // long the LLM takes to process event 1. Without this, the 200ms inter-event delay means
    // event 2 arrives while event 1's LLM call (3-10s) is still in flight → search returns
    // N=0 → agent creates NEW with conf=1.0 instead of the intended low-confidence path.
    if (MODE === 'edge' && !BYPASS) {
        const e3 = CATALOG.find(c => c.id === 'E3');
        const seed = buildEvent(e3, { appNode: `${e3.appNodePrefix}-seed` });
        const seedIncident = {
            short_description: `[${seed.errorCode}] ${seed.appName} - ${seed.activityName}`,
            description: seed.errorMsg,
            severity: seed.severity,
            u_error_code: seed.errorCode,
            u_app_name: seed.appName,
            u_app_node: seed.appNode,
            u_process_name: seed.processName,
            u_activity_name: seed.activityName,
            u_correlation_id: seed.correlationId,
            u_decision_source: 'agent-new',
            u_agent_confidence: 1.0,
            u_triage_reason: 'Pre-existing ChargeCard incident (seeded for edge scenario)'
        };
        try {
            await post(BYPASS_TARGET, seedIncident);
            console.log(`  [edge-seed] pre-seeded ChargeCard incident in ServiceNow store`);
        } catch (e) {
            console.error(`  ! edge-seed failed: ${e.message} — low-confidence event may not trigger correctly`);
        }
    }

    let ok = 0, fail = 0;
    for (const evt of events) {
        const payload = BYPASS ? toBypassIncident(evt) : evt;
        try {
            const res = await post(destination, payload);
            ok++;
            const label = BYPASS ? 'bypass->SN' : 'agent';
            console.log(`  [${label}] ${evt.errorCode || 'BAD_DATA'} @ ${evt.appName || '-'} -> HTTP ${res.status}`);
        } catch (e) {
            fail++;
            console.error(`  ! send failed: ${e.message}`);
        }
        if (DELAY_MS > 0) await new Promise(r => setTimeout(r, DELAY_MS));
    }
    console.log(`[simulator] done. sent=${ok} failed=${fail}`);
}

run().catch(e => {
    console.error(e);
    process.exit(1);
});
