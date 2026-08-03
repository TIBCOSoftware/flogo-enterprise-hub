#!/usr/bin/env python3
"""
BeautyCo Dashboard API Server
Serves the dashboard UI and live data from PostgreSQL beauty_db.

  http://localhost:8092/           -> index.html
  http://localhost:8092/dashboard  -> JSON API

Usage:
    python dashboard_server.py

Optional env vars:
    DB_HOST        default: localhost
    DB_PORT        default: 5432
    DB_NAME        default: beauty_db
    DB_USER        default: postgres
    DB_PASSWORD    default: postgres
    DASHBOARD_PORT default: 8092
"""

import json
import os
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("ERROR: psycopg2 not installed.")
    print("       Run: pip install psycopg2-binary")
    sys.exit(1)

DB_CONFIG = {
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     int(os.getenv("DB_PORT", "5432")),
    "dbname":   os.getenv("DB_NAME",     "beauty_db"),
    "user":     os.getenv("DB_USER",     "postgres"),
    "password": os.getenv("DB_PASSWORD", "postgres"),
}
PORT       = int(os.getenv("DASHBOARD_PORT", "8092"))
INDEX_HTML = Path(__file__).parent / "index.html"


def get_dashboard_data():
    conn = psycopg2.connect(**DB_CONFIG)
    cur  = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    today = datetime.now().date()

    # ── Stat cards ───────────────────────────────────────────────────────────
    # consultations written by UpsertConsultationRecord; agent_log by LogAgentDecision
    cur.execute("SELECT COUNT(*) AS cnt FROM consultations WHERE created_at >= %s", (today,))
    consultations_today = int(cur.fetchone()["cnt"])

    cur.execute("SELECT COUNT(*) AS cnt FROM loyalty_offers WHERE created_at >= %s", (today,))
    offers_today = int(cur.fetchone()["cnt"])

    # tool_calls: prefer agent_log sum; fall back to estimated count from activity tables
    cur.execute(
        "SELECT COALESCE(SUM(COALESCE(array_length(tools_used,1),0)),0) AS cnt FROM agent_log WHERE created_at >= %s",
        (today,),
    )
    tool_calls_today = int(cur.fetchone()["cnt"])
    if tool_calls_today == 0:
        # estimate: each consultation ~ 6 tools, each offer-only record ~ 4 tools
        tool_calls_today = consultations_today * 6 + offers_today * 4

    # sequences: count TriggerMarketingSequence outcomes in agent_log
    cur.execute(
        "SELECT COUNT(*) AS cnt FROM agent_log WHERE outcome ILIKE '%%marketing%%' AND created_at >= %s",
        (today,),
    )
    sequences_today = int(cur.fetchone()["cnt"])

    # ── Live tool-call stream ─────────────────────────────────────────────────
    # Primary: agent_log with tools_used array
    cur.execute(
        """
        SELECT al.member_id, al.tools_used, al.created_at,
               m.first_name, m.last_name, m.tier
        FROM   agent_log al
        LEFT JOIN members m ON al.member_id = m.member_id
        ORDER  BY al.created_at DESC
        LIMIT  20
        """
    )
    recent_tool_calls = []
    for row in cur.fetchall():
        tools = row["tools_used"] or []
        name  = f"{row['first_name']} {row['last_name']}" if row["first_name"] else row["member_id"]
        for tool in tools:
            recent_tool_calls.append({
                "timestamp":     row["created_at"].isoformat(),
                "tool":          tool,
                "memberId":      row["member_id"],
                "memberDisplay": name,
                "tier":          row["tier"] or "",
                "status":        "OK",
                "responseMs":    None,
            })

    # Fallback: synthesize from loyalty_offers + consultations written today
    if not recent_tool_calls:
        cur.execute(
            """
            SELECT lo.member_id, lo.offer_type, lo.created_at,
                   m.first_name, m.last_name, m.tier
            FROM   loyalty_offers lo
            LEFT JOIN members m ON lo.member_id = m.member_id
            WHERE  lo.created_at >= %s
            ORDER  BY lo.created_at DESC
            LIMIT  10
            """,
            (today,),
        )
        for row in cur.fetchall():
            name = f"{row['first_name']} {row['last_name']}" if row["first_name"] else row["member_id"]
            for tool in ["GetMemberProfile", "GetLoyaltyAccount", "CreateLoyaltyOffer"]:
                recent_tool_calls.append({
                    "timestamp":     row["created_at"].isoformat(),
                    "tool":          tool,
                    "memberId":      row["member_id"],
                    "memberDisplay": name,
                    "tier":          row["tier"] or "",
                    "status":        "OK",
                    "responseMs":    None,
                })

        cur.execute(
            """
            SELECT c.member_id, c.channel_type, c.created_at,
                   m.first_name, m.last_name, m.tier
            FROM   consultations c
            LEFT JOIN members m ON c.member_id = m.member_id
            WHERE  c.created_at >= %s
            ORDER  BY c.created_at DESC
            LIMIT  10
            """,
            (today,),
        )
        for row in cur.fetchall():
            name = f"{row['first_name']} {row['last_name']}" if row["first_name"] else row["member_id"]
            for tool in ["GetMemberProfile", "GetBeautyProfile", "GetProductInventory", "GetLoyaltyAccount", "UpsertConsultationRecord"]:
                recent_tool_calls.append({
                    "timestamp":     row["created_at"].isoformat(),
                    "tool":          tool,
                    "memberId":      row["member_id"],
                    "memberDisplay": name,
                    "tier":          row["tier"] or "",
                    "status":        "OK",
                    "responseMs":    None,
                })

        recent_tool_calls.sort(key=lambda x: x["timestamp"], reverse=True)

    # ── Consultation cards ────────────────────────────────────────────────────
    # Primary: agent_log; fallback: consultations table
    cur.execute(
        """
        SELECT al.id, al.member_id, al.agent_reasoning, al.tools_used,
               al.outcome, al.confidence_score, al.created_at,
               m.first_name, m.last_name, m.tier
        FROM   agent_log al
        LEFT JOIN members m ON al.member_id = m.member_id
        ORDER  BY al.created_at DESC
        LIMIT  10
        """
    )
    consultations = []
    for row in cur.fetchall():
        consultations.append({
            "id":               row["id"],
            "member_id":        row["member_id"],
            "first_name":       row["first_name"]  or "",
            "last_name":        row["last_name"]   or "",
            "tier":             row["tier"]        or "",
            "agent_reasoning":  row["agent_reasoning"] or "",
            "tools_used":       row["tools_used"]  or [],
            "confidence_score": float(row["confidence_score"]) if row["confidence_score"] else None,
            "created_at":       row["created_at"].isoformat(),
        })

    if not consultations:
        cur.execute(
            """
            SELECT c.id, c.member_id, c.consultation_notes, c.recommended_skus,
                   c.offer_applied, c.channel_type, c.created_at,
                   m.first_name, m.last_name, m.tier
            FROM   consultations c
            LEFT JOIN members m ON c.member_id = m.member_id
            WHERE  c.created_at >= %s
            ORDER  BY c.created_at DESC
            LIMIT  10
            """,
            (today,),
        )
        for row in cur.fetchall():
            tools = ["GetMemberProfile", "GetBeautyProfile", "GetProductInventory",
                     "GetLoyaltyAccount", "UpsertConsultationRecord"]
            reasoning = row["consultation_notes"] or ""
            if row["recommended_skus"]:
                reasoning = f"Recommended SKUs: {row['recommended_skus']}. " + reasoning
            consultations.append({
                "id":               row["id"],
                "member_id":        row["member_id"],
                "first_name":       row["first_name"]  or "",
                "last_name":        row["last_name"]   or "",
                "tier":             row["tier"]        or "",
                "agent_reasoning":  reasoning,
                "tools_used":       tools,
                "confidence_score": None,
                "created_at":       row["created_at"].isoformat(),
            })

    # ── Agent audit log ───────────────────────────────────────────────────────
    # Primary: agent_log; fallback: loyalty_offers + consultations as events
    cur.execute(
        """
        SELECT id, member_id, outcome, created_at
        FROM   agent_log
        ORDER  BY created_at DESC
        LIMIT  20
        """
    )
    agent_log = [
        {
            "id":         row["id"],
            "member_id":  row["member_id"],
            "outcome":    row["outcome"] or "",
            "created_at": row["created_at"].isoformat(),
            "status":     "OK",
        }
        for row in cur.fetchall()
    ]

    if not agent_log:
        cur.execute(
            """
            SELECT member_id, offer_type AS outcome, created_at
            FROM   loyalty_offers WHERE created_at >= %s
            UNION ALL
            SELECT member_id, 'CONSULTATION_SAVED' AS outcome, created_at
            FROM   consultations WHERE created_at >= %s
            ORDER  BY created_at DESC LIMIT 20
            """,
            (today, today),
        )
        agent_log = [
            {
                "id":         None,
                "member_id":  row["member_id"],
                "outcome":    row["outcome"] or "",
                "created_at": row["created_at"].isoformat(),
                "status":     "OK",
            }
            for row in cur.fetchall()
        ]

    cur.close()
    conn.close()

    return {
        "consultationsToday": consultations_today,
        "toolCallsToday":     tool_calls_today,
        "offersCreatedToday": offers_today,
        "sequencesToday":     sequences_today,
        "recentToolCalls":    recent_tool_calls,
        "consultations":      consultations,
        "agentLog":           agent_log,
    }


class DashboardHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")

        if path == "/dashboard":
            try:
                self._json(200, get_dashboard_data())
            except Exception as exc:
                self._json(500, {"error": str(exc)})

        elif path in ("", "/"):
            self._serve_html()

        else:
            self._json(404, {"error": "not found"})

    def do_OPTIONS(self):
        self.send_response(200)
        self._cors()
        self.end_headers()

    def _serve_html(self):
        body = INDEX_HTML.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type",   "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, payload):
        body = json.dumps(payload, default=str).encode()
        self.send_response(code)
        self.send_header("Content-Type",   "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin",  "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, fmt, *args):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] {fmt % args}")


if __name__ == "__main__":
    print("BeautyCo Dashboard")
    print(f"  DB  : {DB_CONFIG['user']}@{DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['dbname']}")
    print(f"  UI  : http://localhost:{PORT}/")
    print(f"  API : http://localhost:{PORT}/dashboard")
    print()
    server = HTTPServer(("", PORT), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
