-- COPA Airlines Passenger Services — Reset Demo Data
-- Run this to reset all tables with fresh, today-relative test data
-- PostgreSQL 14+

-- Clear all data (reverse dependency order)
TRUNCATE booking_segments, bookings, connectmiles, passengers, flights RESTART IDENTITY CASCADE;

-- Flights — use CURRENT_DATE for today-relative scheduling
INSERT INTO flights (flight_number, origin, origin_city, destination, destination_city, scheduled_departure, estimated_departure, scheduled_arrival, estimated_arrival, status, gate, delay_minutes, delay_reason, aircraft) VALUES
('CM801', 'BOG', 'Bogota',       'PTY', 'Panama City',  CURRENT_DATE + INTERVAL '8 hours 30 minutes',  CURRENT_DATE + INTERVAL '10 hours',            CURRENT_DATE + INTERVAL '11 hours 15 minutes', CURRENT_DATE + INTERVAL '12 hours 45 minutes', 'DELAYED', 'B12', 90, 'Late arriving aircraft from GYE', 'Boeing 737 MAX 9'),
('CM445', 'PTY', 'Panama City',  'MIA', 'Miami',        CURRENT_DATE + INTERVAL '12 hours 30 minutes', NULL,                                           CURRENT_DATE + INTERVAL '16 hours 45 minutes', NULL,                                           'ON_TIME', 'A08', 0,  NULL, 'Boeing 737-800'),
('CM447', 'PTY', 'Panama City',  'MIA', 'Miami',        CURRENT_DATE + INTERVAL '15 hours 30 minutes', NULL,                                           CURRENT_DATE + INTERVAL '19 hours 45 minutes', NULL,                                           'ON_TIME', 'A12', 0,  NULL, 'Boeing 737 MAX 9'),
('CM215', 'GRU', 'Sao Paulo',    'PTY', 'Panama City',  CURRENT_DATE + INTERVAL '6 hours',             NULL,                                           CURRENT_DATE + INTERVAL '11 hours 30 minutes', NULL,                                           'ON_TIME', 'C04', 0,  NULL, 'Boeing 737 MAX 9'),
('CM302', 'PTY', 'Panama City',  'JFK', 'New York',     CURRENT_DATE + INTERVAL '13 hours',            NULL,                                           CURRENT_DATE + INTERVAL '19 hours 15 minutes', NULL,                                           'ON_TIME', 'A15', 0,  NULL, 'Boeing 737 MAX 9'),
('CM510', 'SCL', 'Santiago',     'PTY', 'Panama City',  CURRENT_DATE + INTERVAL '7 hours 15 minutes',  CURRENT_DATE + INTERVAL '8 hours',              CURRENT_DATE + INTERVAL '12 hours 45 minutes', CURRENT_DATE + INTERVAL '13 hours 30 minutes', 'DELAYED', 'C08', 45, 'Weather conditions in Santiago',  'Boeing 737-800'),
('CM612', 'PTY', 'Panama City',  'ORD', 'Chicago',      CURRENT_DATE + INTERVAL '14 hours',            NULL,                                           CURRENT_DATE + INTERVAL '19 hours 30 minutes', NULL,                                           'ON_TIME', 'A20', 0,  NULL, 'Boeing 737 MAX 9'),
('CM725', 'LIM', 'Lima',         'PTY', 'Panama City',  CURRENT_DATE + INTERVAL '9 hours',             NULL,                                           CURRENT_DATE + INTERVAL '13 hours 30 minutes', NULL,                                           'ON_TIME', 'B06', 0,  NULL, 'Boeing 737-800');

-- Passengers
INSERT INTO passengers (passenger_id, first_name, last_name, email, phone, nationality) VALUES
('PAX-2026-00101', 'Carlos',    'Martinez',    'carlos.martinez@email.com',    '+57-310-555-0101', 'COL'),
('PAX-2026-00102', 'Ana',       'Silva',       'ana.silva@email.com',          '+55-11-555-0102',  'BRA'),
('PAX-2026-00103', 'Roberto',   'Gonzalez',    'roberto.gonzalez@email.com',   '+507-6555-0103',   'PAN'),
('PAX-2026-00104', 'Maria',     'Fernandez',   'maria.fernandez@email.com',    '+56-9-555-0104',   'CHL'),
('PAX-2026-00105', 'Jorge',     'Lopez',       'jorge.lopez@email.com',        '+51-1-555-0105',   'PER'),
('PAX-2026-00106', 'Isabella',  'Ramirez',     'isabella.ramirez@email.com',   '+54-11-555-0106',  'ARG'),
('PAX-2026-00107', 'Diego',     'Torres',      'diego.torres@email.com',       '+57-1-555-0107',   'COL'),
('PAX-2026-00108', 'Valentina', 'Herrera',     'valentina.herrera@email.com',  '+507-6555-0108',   'PAN'),
('PAX-2026-00109', 'Andres',    'Morales',     'andres.morales@email.com',     '+1-305-555-0109',  'USA'),
('PAX-2026-00110', 'Camila',    'Rojas',       'camila.rojas@email.com',       '+55-21-555-0110',  'BRA');

-- ConnectMiles
INSERT INTO connectmiles (passenger_id, connectmiles_number, tier, miles_balance, tier_miles_ytd) VALUES
('PAX-2026-00101', 'CM-98765432', 'Gold',          87500, 52000),
('PAX-2026-00102', 'CM-87654321', 'Silver',        34200, 28000),
('PAX-2026-00103', 'CM-76543210', 'Presidential', 245000, 95000),
('PAX-2026-00104', 'CM-65432109', 'PreferMember',  12300,  8000),
('PAX-2026-00105', 'CM-54321098', 'Silver',        41000, 31000),
('PAX-2026-00106', 'CM-43210987', 'Gold',          68000, 48000),
('PAX-2026-00107', 'CM-32109876', 'PreferMember',   5200,  3000),
('PAX-2026-00108', 'CM-21098765', 'Presidential', 312000, 110000),
('PAX-2026-00109', 'CM-10987654', 'Silver',        29000, 22000),
('PAX-2026-00110', 'CM-99887766', 'Gold',          71000, 45000);

-- Bookings
INSERT INTO bookings (pnr, passenger_id, booking_date) VALUES
('ABCDE1', 'PAX-2026-00101', CURRENT_DATE - INTERVAL '36 days'),
('FGHIJ2', 'PAX-2026-00102', CURRENT_DATE - INTERVAL '31 days'),
('KLMNO3', 'PAX-2026-00103', CURRENT_DATE - INTERVAL '20 days'),
('PQRST4', 'PAX-2026-00104', CURRENT_DATE - INTERVAL '16 days'),
('UVWXY5', 'PAX-2026-00105', CURRENT_DATE - INTERVAL '23 days'),
('BCDEF6', 'PAX-2026-00106', CURRENT_DATE - INTERVAL '11 days'),
('GHIJK7', 'PAX-2026-00107', CURRENT_DATE - INTERVAL '9 days'),
('LMNOP8', 'PAX-2026-00110', CURRENT_DATE - INTERVAL '13 days');

-- Booking Segments (all today-relative)
-- Carlos: BOG→PTY (delayed) + PTY→MIA (will miss)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(1, 1, 'CM801', 'BOG', 'PTY', CURRENT_DATE + INTERVAL '8 hours 30 minutes',  CURRENT_DATE + INTERVAL '11 hours 15 minutes', '4A', 'Business', 'CHECKED_IN'),
(1, 2, 'CM445', 'PTY', 'MIA', CURRENT_DATE + INTERVAL '12 hours 30 minutes', CURRENT_DATE + INTERVAL '16 hours 45 minutes', '3C', 'Business', 'CONFIRMED');

-- Ana: GRU→PTY + PTY→JFK
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(2, 1, 'CM215', 'GRU', 'PTY', CURRENT_DATE + INTERVAL '6 hours',  CURRENT_DATE + INTERVAL '11 hours 30 minutes', '12B', 'Economy', 'CHECKED_IN'),
(2, 2, 'CM302', 'PTY', 'JFK', CURRENT_DATE + INTERVAL '13 hours', CURRENT_DATE + INTERVAL '19 hours 15 minutes', '14A', 'Economy', 'CONFIRMED');

-- Roberto: PTY→MIA (direct)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(3, 1, 'CM445', 'PTY', 'MIA', CURRENT_DATE + INTERVAL '12 hours 30 minutes', CURRENT_DATE + INTERVAL '16 hours 45 minutes', '1A', 'Business', 'CONFIRMED');

-- Maria: SCL→PTY (delayed 45 min) + PTY→ORD
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(4, 1, 'CM510', 'SCL', 'PTY', CURRENT_DATE + INTERVAL '7 hours 15 minutes', CURRENT_DATE + INTERVAL '12 hours 45 minutes', '8C',  'Economy', 'CHECKED_IN'),
(4, 2, 'CM612', 'PTY', 'ORD', CURRENT_DATE + INTERVAL '14 hours',           CURRENT_DATE + INTERVAL '19 hours 30 minutes', '10A', 'Economy', 'CONFIRMED');

-- Jorge: LIM→PTY + PTY→MIA
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(5, 1, 'CM725', 'LIM', 'PTY', CURRENT_DATE + INTERVAL '9 hours',            CURRENT_DATE + INTERVAL '13 hours 30 minutes', '15D', 'Economy', 'CONFIRMED'),
(5, 2, 'CM447', 'PTY', 'MIA', CURRENT_DATE + INTERVAL '15 hours 30 minutes', CURRENT_DATE + INTERVAL '19 hours 45 minutes', '16A', 'Economy', 'CONFIRMED');

-- Isabella: BOG→PTY (one-way, on delayed CM801)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(6, 1, 'CM801', 'BOG', 'PTY', CURRENT_DATE + INTERVAL '8 hours 30 minutes', CURRENT_DATE + INTERVAL '11 hours 15 minutes', '6B', 'Economy', 'CHECKED_IN');

-- Diego: BOG→PTY + PTY→JFK
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(7, 1, 'CM801', 'BOG', 'PTY', CURRENT_DATE + INTERVAL '8 hours 30 minutes', CURRENT_DATE + INTERVAL '11 hours 15 minutes', '22A', 'Economy', 'CHECKED_IN'),
(7, 2, 'CM302', 'PTY', 'JFK', CURRENT_DATE + INTERVAL '13 hours',           CURRENT_DATE + INTERVAL '19 hours 15 minutes', '20C', 'Economy', 'CONFIRMED');

-- Camila: GRU→PTY + PTY→ORD
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(8, 1, 'CM215', 'GRU', 'PTY', CURRENT_DATE + INTERVAL '6 hours',  CURRENT_DATE + INTERVAL '11 hours 30 minutes', '18B', 'Economy', 'CONFIRMED'),
(8, 2, 'CM612', 'PTY', 'ORD', CURRENT_DATE + INTERVAL '14 hours', CURRENT_DATE + INTERVAL '19 hours 30 minutes', '19A', 'Economy', 'CONFIRMED');
