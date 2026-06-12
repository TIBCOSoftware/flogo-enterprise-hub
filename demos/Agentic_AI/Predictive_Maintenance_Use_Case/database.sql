-- =============================================
-- Predictive Maintenance & Asset Monitoring
-- PostgreSQL DDL — Database: predictive_maintenance
-- =============================================

-- 1. Well Sites
DROP TABLE IF EXISTS well_sites CASCADE;

CREATE TABLE well_sites (
    well_site_id VARCHAR(30) PRIMARY KEY,
    site_name VARCHAR(100),
    location VARCHAR(200),
    region VARCHAR(50)
);

-- 2. Assets
DROP TABLE IF EXISTS assets CASCADE;

CREATE TABLE assets (
    asset_id VARCHAR(30) PRIMARY KEY,
    asset_type VARCHAR(20),
    well_site_id VARCHAR(30),
    description VARCHAR(200),
    install_date VARCHAR(20),
    status VARCHAR(20) DEFAULT 'OPERATIONAL'
);

-- 3. Sensor Readings
DROP TABLE IF EXISTS sensor_readings CASCADE;

CREATE TABLE sensor_readings (
    id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    reading_timestamp VARCHAR(30),
    vibration_rms DECIMAL(5,2),
    temperature_c DECIMAL(5,1),
    pressure_psi DECIMAL(7,1),
    flow_rate DECIMAL(6,1),
    power_consumption DECIMAL(6,1)
);

-- 4. Predictions
DROP TABLE IF EXISTS predictions CASCADE;

CREATE TABLE predictions (
    prediction_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    predicted_at VARCHAR(30),
    status VARCHAR(20),
    confidence DECIMAL(4,2),
    days_to_failure INTEGER,
    failure_mode VARCHAR(50),
    recommended_action VARCHAR(500),
    sensor_anomalies VARCHAR(500)
);

-- 5. Work Orders
DROP TABLE IF EXISTS work_orders CASCADE;

CREATE TABLE work_orders (
    work_order_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    prediction_id INTEGER,
    priority VARCHAR(10),
    description VARCHAR(500),
    assigned_to VARCHAR(100),
    scheduled_date VARCHAR(20),
    status VARCHAR(20) DEFAULT 'OPEN',
    created_at VARCHAR(30)
);

-- 6. Alert History
DROP TABLE IF EXISTS alert_history CASCADE;

CREATE TABLE alert_history (
    alert_id SERIAL PRIMARY KEY,
    asset_id VARCHAR(30),
    prediction_id INTEGER,
    severity VARCHAR(20),
    message VARCHAR(500),
    sent_at VARCHAR(30),
    status VARCHAR(20) DEFAULT 'SENT'
);
