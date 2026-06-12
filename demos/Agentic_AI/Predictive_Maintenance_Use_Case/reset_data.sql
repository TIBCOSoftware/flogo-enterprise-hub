-- =============================================
-- Predictive Maintenance — Reset & Seed Data
-- Run this script to reset all tables to baseline
-- Baseline date: 2026-04-17
-- =============================================

TRUNCATE TABLE alert_history RESTART IDENTITY CASCADE;
TRUNCATE TABLE work_orders RESTART IDENTITY CASCADE;
TRUNCATE TABLE predictions RESTART IDENTITY CASCADE;
TRUNCATE TABLE sensor_readings RESTART IDENTITY CASCADE;
TRUNCATE TABLE assets RESTART IDENTITY CASCADE;
TRUNCATE TABLE well_sites RESTART IDENTITY CASCADE;

-- =============================================
-- WELL SITES (3 sites)
-- =============================================

INSERT INTO well_sites (well_site_id, site_name, location, region) VALUES
('WS-PERMIAN-001', 'Permian Basin Site Alpha', 'Midland, TX', 'Permian Basin'),
('WS-BAKKEN-002', 'Bakken Field Site Bravo', 'Williston, ND', 'Bakken'),
('WS-EAGLE-003', 'Eagle Ford Site Charlie', 'Karnes City, TX', 'Eagle Ford');

-- =============================================
-- ASSETS (8 assets)
-- =============================================

INSERT INTO assets (asset_id, asset_type, well_site_id, description, install_date, status) VALUES
('PUMP-W47-TX',   'PUMP',       'WS-PERMIAN-001', 'Rod Pump Unit - Well #47',           '2024-03-15', 'OPERATIONAL'),
('PUMP-W48-TX',   'PUMP',       'WS-PERMIAN-001', 'Rod Pump Unit - Well #48',           '2024-06-20', 'OPERATIONAL'),
('COMP-W12-OK',   'COMPRESSOR', 'WS-PERMIAN-001', 'Gas Compressor - Station #12',       '2023-11-10', 'OPERATIONAL'),
('VALVE-W03-NM',  'VALVE',      'WS-BAKKEN-002',  'Wellhead Valve Assembly - Well #03', '2024-01-22', 'OPERATIONAL'),
('PUMP-B21-ND',   'PUMP',       'WS-BAKKEN-002',  'ESP Pump Unit - Well #21',           '2023-08-05', 'MAINTENANCE'),
('COMP-B05-ND',   'COMPRESSOR', 'WS-BAKKEN-002',  'Gas Compressor - Station #05',       '2024-09-12', 'OPERATIONAL'),
('PUMP-E14-TX',   'PUMP',       'WS-EAGLE-003',   'Rod Pump Unit - Well #14',           '2023-05-30', 'OPERATIONAL'),
('VALVE-E07-TX',  'VALVE',      'WS-EAGLE-003',   'Wellhead Valve Assembly - Well #07', '2024-07-18', 'OPERATIONAL');

-- =============================================
-- SENSOR READINGS
-- Multiple readings per asset (every 4h over past 24h = 6 readings each)
-- Latest reading reflects intended health state
-- =============================================

-- PUMP-W47-TX: WARNING (high vibration + temp trending up)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('PUMP-W47-TX', '2026-04-16 14:00', 2.8, 78.0, 1080.0, 100.5, 42.0),
('PUMP-W47-TX', '2026-04-16 18:00', 3.1, 82.0, 1100.0, 98.0, 43.1),
('PUMP-W47-TX', '2026-04-16 22:00', 3.5, 86.5, 1120.0, 97.2, 43.8),
('PUMP-W47-TX', '2026-04-17 02:00', 3.9, 90.0, 1130.0, 96.0, 44.5),
('PUMP-W47-TX', '2026-04-17 06:00', 4.3, 94.0, 1140.0, 95.8, 45.0),
('PUMP-W47-TX', '2026-04-17 10:00', 4.8, 98.5, 1150.0, 95.2, 45.3);

-- PUMP-W48-TX: NORMAL (all sensors stable)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('PUMP-W48-TX', '2026-04-16 14:00', 2.0, 71.0, 1040.0, 103.0, 40.0),
('PUMP-W48-TX', '2026-04-16 18:00', 2.1, 72.0, 1045.0, 102.8, 40.2),
('PUMP-W48-TX', '2026-04-16 22:00', 1.9, 71.5, 1050.0, 103.2, 39.8),
('PUMP-W48-TX', '2026-04-17 02:00', 2.0, 72.0, 1048.0, 102.5, 40.1),
('PUMP-W48-TX', '2026-04-17 06:00', 2.1, 72.5, 1050.0, 102.0, 40.3),
('PUMP-W48-TX', '2026-04-17 10:00', 2.1, 72.3, 1050.0, 102.5, 40.2);

-- COMP-W12-OK: CRITICAL (all sensors elevated)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('COMP-W12-OK', '2026-04-16 14:00', 4.0, 90.0, 1250.0, 92.0, 78.0),
('COMP-W12-OK', '2026-04-16 18:00', 4.5, 95.0, 1300.0, 90.0, 80.5),
('COMP-W12-OK', '2026-04-16 22:00', 5.2, 100.5, 1350.0, 89.0, 83.0),
('COMP-W12-OK', '2026-04-17 02:00', 5.8, 105.0, 1400.0, 88.5, 85.0),
('COMP-W12-OK', '2026-04-17 06:00', 6.2, 109.0, 1450.0, 88.0, 87.0),
('COMP-W12-OK', '2026-04-17 10:00', 6.5, 112.0, 1480.0, 88.0, 88.5);

-- VALVE-W03-NM: NORMAL (stable)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('VALVE-W03-NM', '2026-04-16 14:00', 1.7, 67.0, 975.0, 106.0, 12.0),
('VALVE-W03-NM', '2026-04-16 18:00', 1.8, 68.0, 980.0, 105.5, 12.1),
('VALVE-W03-NM', '2026-04-16 22:00', 1.7, 67.5, 978.0, 105.0, 12.0),
('VALVE-W03-NM', '2026-04-17 02:00', 1.8, 68.0, 980.0, 105.2, 12.1),
('VALVE-W03-NM', '2026-04-17 06:00', 1.9, 68.5, 982.0, 104.8, 12.2),
('VALVE-W03-NM', '2026-04-17 10:00', 1.8, 68.0, 980.0, 105.0, 12.1);

-- PUMP-B21-ND: WARNING (vibration + low pressure + low flow)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('PUMP-B21-ND', '2026-04-16 14:00', 3.8, 82.0, 850.0, 85.0, 48.0),
('PUMP-B21-ND', '2026-04-16 18:00', 4.2, 84.0, 820.0, 82.0, 49.5),
('PUMP-B21-ND', '2026-04-16 22:00', 4.5, 86.0, 800.0, 78.0, 50.0),
('PUMP-B21-ND', '2026-04-17 02:00', 4.8, 88.0, 780.0, 76.0, 51.0),
('PUMP-B21-ND', '2026-04-17 06:00', 5.0, 89.5, 760.0, 74.0, 51.5),
('PUMP-B21-ND', '2026-04-17 10:00', 5.2, 91.0, 750.0, 72.0, 52.0);

-- COMP-B05-ND: NORMAL (stable)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('COMP-B05-ND', '2026-04-16 14:00', 2.9, 77.0, 1090.0, 99.0, 70.0),
('COMP-B05-ND', '2026-04-16 18:00', 3.0, 78.0, 1095.0, 98.5, 70.5),
('COMP-B05-ND', '2026-04-16 22:00', 2.8, 77.5, 1092.0, 99.0, 70.2),
('COMP-B05-ND', '2026-04-17 02:00', 3.0, 78.0, 1098.0, 98.0, 70.8),
('COMP-B05-ND', '2026-04-17 06:00', 3.1, 78.5, 1100.0, 98.0, 71.0),
('COMP-B05-ND', '2026-04-17 10:00', 3.0, 78.5, 1100.0, 98.0, 70.8);

-- PUMP-E14-TX: CRITICAL (vibration + temp + low pressure + low flow)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('PUMP-E14-TX', '2026-04-16 14:00', 5.0, 92.0, 750.0, 72.0, 55.0),
('PUMP-E14-TX', '2026-04-16 18:00', 5.5, 96.0, 700.0, 68.0, 57.0),
('PUMP-E14-TX', '2026-04-16 22:00', 6.0, 100.0, 660.0, 64.0, 59.0),
('PUMP-E14-TX', '2026-04-17 02:00', 6.5, 103.0, 620.0, 60.0, 61.0),
('PUMP-E14-TX', '2026-04-17 06:00', 6.8, 106.0, 600.0, 57.0, 62.5),
('PUMP-E14-TX', '2026-04-17 10:00', 7.1, 108.0, 580.0, 55.0, 63.0);

-- VALVE-E07-TX: NORMAL (stable)
INSERT INTO sensor_readings (asset_id, reading_timestamp, vibration_rms, temperature_c, pressure_psi, flow_rate, power_consumption) VALUES
('VALVE-E07-TX', '2026-04-16 14:00', 2.4, 74.0, 1015.0, 111.0, 11.5),
('VALVE-E07-TX', '2026-04-16 18:00', 2.5, 75.0, 1020.0, 110.5, 11.6),
('VALVE-E07-TX', '2026-04-16 22:00', 2.4, 74.5, 1018.0, 110.0, 11.5),
('VALVE-E07-TX', '2026-04-17 02:00', 2.5, 75.0, 1020.0, 110.2, 11.6),
('VALVE-E07-TX', '2026-04-17 06:00', 2.6, 75.5, 1022.0, 109.8, 11.7),
('VALVE-E07-TX', '2026-04-17 10:00', 2.5, 75.0, 1020.0, 110.0, 11.6);

-- =============================================
-- PREDICTIONS (4 historical entries — test assets left clean)
-- =============================================

INSERT INTO predictions (asset_id, predicted_at, status, confidence, days_to_failure, failure_mode, recommended_action, sensor_anomalies) VALUES
('PUMP-B21-ND', '2026-04-10 08:30', 'WARNING', 0.82, 18, 'seal_leak', 'Schedule seal inspection within 1 week', 'pressure_psi: 820 (low), flow_rate: 78 bbl/hr (low)'),
('PUMP-B21-ND', '2026-04-14 09:00', 'WARNING', 0.87, 14, 'seal_leak', 'Seal degradation progressing. Schedule maintenance.', 'pressure_psi: 790 (low), flow_rate: 75 bbl/hr (low), vibration: 4.5g (elevated)'),
('COMP-B05-ND', '2026-04-12 10:00', 'NORMAL', 0.95, 120, 'none', 'No action required. All sensors within normal range.', 'No anomalies detected'),
('VALVE-E07-TX', '2026-04-15 11:00', 'NORMAL', 0.93, 90, 'none', 'No action required. Continue routine monitoring.', 'No anomalies detected');

-- =============================================
-- WORK ORDERS (2 historical entries)
-- =============================================

INSERT INTO work_orders (asset_id, prediction_id, priority, description, assigned_to, scheduled_date, status, created_at) VALUES
('PUMP-B21-ND', 1, 'MEDIUM', 'Inspect pump seals — low pressure trend detected', 'Field Tech Team B', '2026-04-14', 'COMPLETED', '2026-04-10 08:35'),
('PUMP-B21-ND', 2, 'HIGH', 'Seal degradation progressing. Replace pump seals.', 'Field Tech Team B', '2026-04-18', 'IN_PROGRESS', '2026-04-14 09:05');

-- =============================================
-- ALERT HISTORY (2 historical entries)
-- =============================================

INSERT INTO alert_history (asset_id, prediction_id, severity, message, sent_at, status) VALUES
('PUMP-B21-ND', 1, 'WARNING', 'WARNING — PUMP-B21-ND | Seal leak detected | Est. 18 days to failure | Confidence: 82%', '2026-04-10 08:35', 'ACKNOWLEDGED'),
('PUMP-B21-ND', 2, 'WARNING', 'WARNING — PUMP-B21-ND | Seal degradation progressing | Est. 14 days to failure | Confidence: 87%', '2026-04-14 09:05', 'ACKNOWLEDGED');

-- =============================================
-- VERIFY DATA
-- =============================================

SELECT 'well_sites' AS table_name, COUNT(*) AS row_count FROM well_sites
UNION ALL SELECT 'assets', COUNT(*) FROM assets
UNION ALL SELECT 'sensor_readings', COUNT(*) FROM sensor_readings
UNION ALL SELECT 'predictions', COUNT(*) FROM predictions
UNION ALL SELECT 'work_orders', COUNT(*) FROM work_orders
UNION ALL SELECT 'alert_history', COUNT(*) FROM alert_history;
