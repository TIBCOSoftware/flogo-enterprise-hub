-- Autonomous Mortgage AI Processor — PostgreSQL Schema
-- Database: mortgage_db
-- Run: psql -U postgres -d mortgage_db -f mortgage-schema.sql

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS applicants (
    id              VARCHAR(20)  PRIMARY KEY,
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    date_of_birth   DATE,
    email           VARCHAR(200),
    phone           VARCHAR(20),
    address         TEXT,
    national_id     VARCHAR(50),
    kyc_status      VARCHAR(20)  NOT NULL DEFAULT 'PENDING',  -- PENDING | VERIFIED | FAILED
    risk_band       VARCHAR(10),                               -- A | B | C | D
    created_at      TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS existing_debts (
    id                  SERIAL       PRIMARY KEY,
    applicant_id        VARCHAR(20)  NOT NULL REFERENCES applicants(id),
    debt_type           VARCHAR(50)  NOT NULL,  -- AUTO_LOAN | CREDIT_CARD | STUDENT_LOAN | PERSONAL_LOAN | MORTGAGE
    lender              VARCHAR(100),
    outstanding_balance NUMERIC(12,2) NOT NULL DEFAULT 0,
    monthly_payment     NUMERIC(10,2) NOT NULL DEFAULT 0,
    interest_rate       NUMERIC(5,3),
    months_remaining    INTEGER,
    created_at          TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mortgage_applications (
    id               SERIAL       PRIMARY KEY,
    applicant_id     VARCHAR(20)  NOT NULL REFERENCES applicants(id),
    property_address TEXT,
    property_value   NUMERIC(12,2),
    loan_amount      NUMERIC(12,2),
    term_years       INTEGER,
    status           VARCHAR(20)  NOT NULL DEFAULT 'PENDING',  -- PENDING | APPROVED | DECLINED | ESCALATED
    submitted_at     TIMESTAMP    NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS mortgage_decisions (
    id            SERIAL       PRIMARY KEY,
    applicant_id  VARCHAR(20)  NOT NULL,
    decision      VARCHAR(20)  NOT NULL,  -- APPROVED | DECLINED | ESCALATED
    loan_amount   NUMERIC(12,2),
    term_years    INTEGER,
    interest_rate NUMERIC(5,3),
    dti_ratio     NUMERIC(5,4),
    reason        TEXT,
    decided_by    VARCHAR(50)  NOT NULL DEFAULT 'Claude-AI',
    decided_at    TIMESTAMP    NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS audit_log (
    id           SERIAL      PRIMARY KEY,
    applicant_id VARCHAR(20),
    action       VARCHAR(50) NOT NULL,  -- APPROVED | DECLINED | ESCALATED | TOOL_CALLED | ERROR
    details      TEXT,
    tools_used   TEXT,
    created_at   TIMESTAMP   NOT NULL DEFAULT NOW()
);

-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_existing_debts_applicant ON existing_debts(applicant_id);
CREATE INDEX IF NOT EXISTS idx_mortgage_applications_applicant ON mortgage_applications(applicant_id);
CREATE INDEX IF NOT EXISTS idx_mortgage_decisions_applicant ON mortgage_decisions(applicant_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_applicant ON audit_log(applicant_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created ON audit_log(created_at);

-- ============================================================
-- SEED DATA — Demo applicant APP-001 (Sarah Mitchell)
-- ============================================================

INSERT INTO applicants (id, first_name, last_name, date_of_birth, email, phone, address, national_id, kyc_status, risk_band)
VALUES (
    'APP-001',
    'Sarah',
    'Mitchell',
    '1985-07-14',
    'sarah.mitchell@email.com',
    '+1-512-555-0147',
    '47 Maple Grove, Austin TX 78701',
    'NI-998877',
    'VERIFIED',
    'B'
)
ON CONFLICT (id) DO NOTHING;

INSERT INTO existing_debts (applicant_id, debt_type, lender, outstanding_balance, monthly_payment, interest_rate, months_remaining)
VALUES
    ('APP-001', 'AUTO_LOAN',    'First National Bank', 18500.00, 420.00, 4.500, 44),
    ('APP-001', 'CREDIT_CARD',  'Chase',                4200.00, 180.00, 19.900, NULL),
    ('APP-001', 'STUDENT_LOAN', 'Sallie Mae',          22000.00, 650.00,  5.200, 36)
ON CONFLICT DO NOTHING;

INSERT INTO mortgage_applications (applicant_id, property_address, property_value, loan_amount, term_years, status)
VALUES (
    'APP-001',
    '47 Maple Grove, Austin TX 78701',
    485000.00,
    350000.00,
    30,
    'PENDING'
)
ON CONFLICT DO NOTHING;

-- ============================================================
-- GRANT (adjust role name to match your environment)
-- ============================================================

-- GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO flogo;
-- GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO flogo;
