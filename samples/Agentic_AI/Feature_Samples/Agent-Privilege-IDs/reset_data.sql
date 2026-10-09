-- Seed / reset the demo data for bankops_agents (fictional Harbor Bank).
-- Safe to re-run at any time:  psql -U postgres -d bankops_agents -f reset_data.sql
TRUNCATE agent_audit, approval_requests, transactions, cards, accounts,
         agent_entitlements, agent_identities, human_approvers RESTART IDENTITY CASCADE;
ALTER SEQUENCE approval_seq RESTART WITH 1001;

-- Each agent's privilege ID (= the JWT `sub` its token carries), its accountable owner and its lifecycle.
INSERT INTO agent_identities VALUES
 ('agt-insight-01',   'Customer Insight Agent', 'Answers staff questions about accounts and recent activity (read-only)',
  'priya.raman - Head of Customer Analytics', 'ACTIVE',    now() + interval '90 days', current_date - 20, 'risk.office'),
 ('agt-servicing-01', 'Card Servicing Agent',   'Blocks lost or compromised cards; requests limit changes for human approval',
  'daniel.ong - Head of Card Operations',     'ACTIVE',    now() + interval '90 days', current_date - 20, 'risk.office'),
 ('agt-legacy-07',    'Legacy Reporting Agent', 'Retired reporting bot - kept to show a suspended identity',
  'it.service.owner',                          'SUSPENDED', now() + interval '30 days', current_date - 400, 'risk.office'),
 ('agt-orchestrator-01', 'Operations Orchestrator', 'Front-door agent (orchestrated variant): routes requests to specialist agents; no direct access to bank systems',
  'maria.chen - Head of Digital Operations',  'ACTIVE',    now() + interval '90 days', current_date - 20, 'risk.office');

-- Least privilege: what each identity may call (checked on every call, alongside the token's scopes).
INSERT INTO agent_entitlements VALUES
 ('agt-insight-01', 'whoami'), ('agt-insight-01', 'get_account_summary'), ('agt-insight-01', 'list_recent_transactions'),
 ('agt-servicing-01', 'whoami'), ('agt-servicing-01', 'get_account_summary'), ('agt-servicing-01', 'list_recent_transactions'),
 ('agt-servicing-01', 'block_card'), ('agt-servicing-01', 'request_limit_increase'), ('agt-servicing-01', 'get_request_status'),
 ('agt-legacy-07', 'whoami'), ('agt-legacy-07', 'get_account_summary'),
 ('agt-orchestrator-01', 'ask_insight_agent'), ('agt-orchestrator-01', 'ask_servicing_agent');

-- People who may decide privileged changes. No agent appears here - and approve_request() also refuses any agent id.
INSERT INTO human_approvers VALUES
 ('supervisor.tan', 'Grace Tan',    'Card Operations Supervisor', 50000),
 ('analyst.kumar',  'Arjun Kumar',  'Operations Analyst',          5000);

INSERT INTO accounts VALUES
 ('ACC-1001', 'Mei Lin Wong',   'Premier Current', 48250.75, 10000, 'OPEN'),
 ('ACC-1002', 'Rahul Menon',    'Everyday Savings', 3120.10,  2000, 'OPEN'),
 ('ACC-1003', 'Sofia Alvarez',  'Business Current', 152300.00, 25000, 'OPEN');

INSERT INTO cards VALUES
 ('CARD-4421', 'ACC-1001', '4421', 'Visa Debit',     'ACTIVE', NULL, NULL, NULL),
 ('CARD-9013', 'ACC-1001', '9013', 'Visa Platinum',  'ACTIVE', NULL, NULL, NULL),
 ('CARD-7788', 'ACC-1002', '7788', 'Mastercard Debit','ACTIVE', NULL, NULL, NULL),
 ('CARD-5520', 'ACC-1003', '5520', 'Business Debit', 'BLOCKED', 'card.ops.desk', now() - interval '3 days', 'reported stolen');

INSERT INTO transactions VALUES
 ('TXN-50001', 'ACC-1001', current_date - 1, 'FAIRPRICE SUPERMARKET',         -86.40),
 ('TXN-50002', 'ACC-1001', current_date - 2, 'SALARY - NORTHWIND PTE LTD',  6800.00),
 ('TXN-50003', 'ACC-1001', current_date - 2, 'ONLINE PURCHASE - GADGETHUB',  -1249.00),
 ('TXN-50004', 'ACC-1001', current_date - 4, 'TRANSFER TO R MENON',           -500.00),
 ('TXN-50005', 'ACC-1001', current_date - 6, 'CAFE AURORA',                    -12.80),
 ('TXN-50006', 'ACC-1002', current_date - 1, 'TRANSFER FROM M L WONG',         500.00),
 ('TXN-50007', 'ACC-1002', current_date - 3, 'METRO TRANSIT TOP-UP',           -30.00),
 ('TXN-50008', 'ACC-1003', current_date - 1, 'SUPPLIER PAYMENT - ACME',     -18450.00);
