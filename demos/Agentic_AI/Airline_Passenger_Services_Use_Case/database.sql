-- Airline Passenger Services — Database Schema & Demo Data
-- PostgreSQL 14+

-- Drop existing tables (reverse dependency order)
DROP TABLE IF EXISTS booking_segments CASCADE;
DROP TABLE IF EXISTS bookings CASCADE;
DROP TABLE IF EXISTS frequentflyer CASCADE;
DROP TABLE IF EXISTS passengers CASCADE;
DROP TABLE IF EXISTS flights CASCADE;

-- 1. Flights — Flight schedule with real-time status
CREATE TABLE flights (
    id              SERIAL PRIMARY KEY,
    flight_number   VARCHAR(10) NOT NULL,
    origin          VARCHAR(3) NOT NULL,        -- IATA code
    origin_city     VARCHAR(50) NOT NULL,
    destination     VARCHAR(3) NOT NULL,        -- IATA code
    destination_city VARCHAR(50) NOT NULL,
    scheduled_departure TIMESTAMP WITH TIME ZONE NOT NULL,
    estimated_departure TIMESTAMP WITH TIME ZONE,
    scheduled_arrival   TIMESTAMP WITH TIME ZONE NOT NULL,
    estimated_arrival   TIMESTAMP WITH TIME ZONE,
    status          VARCHAR(20) NOT NULL DEFAULT 'ON_TIME',  -- ON_TIME, DELAYED, BOARDING, DEPARTED, CANCELLED
    gate            VARCHAR(5),
    delay_minutes   INTEGER DEFAULT 0,
    delay_reason    VARCHAR(200),
    aircraft        VARCHAR(50) DEFAULT 'Boeing 737 MAX 9',
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_status CHECK (status IN ('ON_TIME','DELAYED','BOARDING','DEPARTED','CANCELLED'))
);

-- 2. Passengers — Passenger master records
CREATE TABLE passengers (
    id              SERIAL PRIMARY KEY,
    passenger_id    VARCHAR(20) NOT NULL UNIQUE,   -- PAX-2026-XXXXX
    first_name      VARCHAR(50) NOT NULL,
    last_name       VARCHAR(50) NOT NULL,
    email           VARCHAR(100),
    phone           VARCHAR(30),
    nationality     VARCHAR(3),                    -- ISO country code
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 3. FrequentFlyer — Loyalty program membership
CREATE TABLE frequentflyer (
    id                  SERIAL PRIMARY KEY,
    passenger_id        VARCHAR(20) NOT NULL REFERENCES passengers(passenger_id),
    frequentflyer_number VARCHAR(20) NOT NULL UNIQUE,  -- CM-XXXXXXXX
    tier                VARCHAR(20) NOT NULL DEFAULT 'Basic',  -- Basic, Silver, Gold, Platinum
    miles_balance       INTEGER DEFAULT 0,
    tier_miles_ytd      INTEGER DEFAULT 0,
    CONSTRAINT chk_tier CHECK (tier IN ('Basic','Silver','Gold','Platinum'))
);

-- 4. Bookings — PNR-based itineraries
CREATE TABLE bookings (
    id              SERIAL PRIMARY KEY,
    pnr             VARCHAR(6) NOT NULL UNIQUE,    -- 6-character PNR
    passenger_id    VARCHAR(20) NOT NULL REFERENCES passengers(passenger_id),
    booking_date    DATE NOT NULL DEFAULT CURRENT_DATE,
    booking_status  VARCHAR(20) NOT NULL DEFAULT 'CONFIRMED',  -- CONFIRMED, CANCELLED, COMPLETED
    created_at      TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 5. Booking Segments — Individual flight legs per booking
CREATE TABLE booking_segments (
    id              SERIAL PRIMARY KEY,
    booking_id      INTEGER NOT NULL REFERENCES bookings(id),
    segment_order   INTEGER NOT NULL,              -- 1, 2, 3... for multi-leg
    flight_number   VARCHAR(10) NOT NULL,
    origin          VARCHAR(3) NOT NULL,
    destination     VARCHAR(3) NOT NULL,
    departure_time  TIMESTAMP WITH TIME ZONE NOT NULL,
    arrival_time    TIMESTAMP WITH TIME ZONE NOT NULL,
    seat_number     VARCHAR(5),
    cabin           VARCHAR(20) DEFAULT 'Economy', -- Economy, Business
    segment_status  VARCHAR(20) DEFAULT 'CONFIRMED', -- CONFIRMED, CHECKED_IN, BOARDED, COMPLETED, CANCELLED
    CONSTRAINT chk_cabin CHECK (cabin IN ('Economy','Business')),
    CONSTRAINT chk_seg_status CHECK (segment_status IN ('CONFIRMED','CHECKED_IN','BOARDED','COMPLETED','CANCELLED'))
);

-- Indexes
CREATE INDEX idx_flights_number ON flights(flight_number);
CREATE INDEX idx_flights_status ON flights(status);
CREATE INDEX idx_passengers_id ON passengers(passenger_id);
CREATE INDEX idx_bookings_pnr ON bookings(pnr);
CREATE INDEX idx_bookings_passenger ON bookings(passenger_id);
CREATE INDEX idx_segments_booking ON booking_segments(booking_id);
CREATE INDEX idx_frequentflyer_passenger ON frequentflyer(passenger_id);

-- ============================================================
-- DEMO DATA — Airline Route Network through Hub
-- ============================================================

-- Flights (8 flights — today's date, flight numbers)
INSERT INTO flights (flight_number, origin, origin_city, destination, destination_city, scheduled_departure, estimated_departure, scheduled_arrival, estimated_arrival, status, gate, delay_minutes, delay_reason, aircraft) VALUES
('FL801', 'BOG', 'Bogota',       'PTY', 'Panama City',  '2026-05-21 08:30:00-05:00', '2026-05-21 10:00:00-05:00', '2026-05-21 11:15:00-05:00', '2026-05-21 12:45:00-05:00', 'DELAYED', 'B12', 90, 'Late arriving aircraft from GYE', 'Boeing 737 MAX 9'),
('FL445', 'PTY', 'Panama City',  'MIA', 'Miami',        '2026-05-21 12:30:00-05:00', NULL,                         '2026-05-21 16:45:00-04:00', NULL,                         'ON_TIME', 'A08', 0,  NULL, 'Boeing 737-800'),
('FL447', 'PTY', 'Panama City',  'MIA', 'Miami',        '2026-05-21 15:30:00-05:00', NULL,                         '2026-05-21 19:45:00-04:00', NULL,                         'ON_TIME', 'A12', 0,  NULL, 'Boeing 737 MAX 9'),
('FL215', 'GRU', 'Sao Paulo',    'PTY', 'Panama City',  '2026-05-21 06:00:00-03:00', NULL,                         '2026-05-21 11:30:00-05:00', NULL,                         'ON_TIME', 'C04', 0,  NULL, 'Boeing 737 MAX 9'),
('FL302', 'PTY', 'Panama City',  'JFK', 'New York',     '2026-05-21 13:00:00-05:00', NULL,                         '2026-05-21 19:15:00-04:00', NULL,                         'ON_TIME', 'A15', 0,  NULL, 'Boeing 737 MAX 9'),
('FL510', 'SCL', 'Santiago',     'PTY', 'Panama City',  '2026-05-21 07:15:00-04:00', '2026-05-21 08:00:00-04:00',  '2026-05-21 12:45:00-05:00', '2026-05-21 13:30:00-05:00', 'DELAYED', 'C08', 45, 'Weather conditions in Santiago',  'Boeing 737-800'),
('FL612', 'PTY', 'Panama City',  'ORD', 'Chicago',      '2026-05-21 14:00:00-05:00', NULL,                         '2026-05-21 19:30:00-05:00', NULL,                         'ON_TIME', 'A20', 0,  NULL, 'Boeing 737 MAX 9'),
('FL725', 'LIM', 'Lima',         'PTY', 'Panama City',  '2026-05-21 09:00:00-05:00', NULL,                         '2026-05-21 13:30:00-05:00', NULL,                         'ON_TIME', 'B06', 0,  NULL, 'Boeing 737-800');

-- Passengers (10 passengers)
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

-- FrequentFlyer loyalty program
INSERT INTO frequentflyer (passenger_id, frequentflyer_number, tier, miles_balance, tier_miles_ytd) VALUES
('PAX-2026-00101', 'FF-98765432', 'Gold',          87500, 52000),
('PAX-2026-00102', 'FF-87654321', 'Silver',        34200, 28000),
('PAX-2026-00103', 'FF-76543210', 'Platinum', 245000, 95000),
('PAX-2026-00104', 'FF-65432109', 'Basic',  12300,  8000),
('PAX-2026-00105', 'FF-54321098', 'Silver',        41000, 31000),
('PAX-2026-00106', 'FF-43210987', 'Gold',          68000, 48000),
('PAX-2026-00107', 'FF-32109876', 'Basic',   5200,  3000),
('PAX-2026-00108', 'FF-21098765', 'Platinum', 312000, 110000),
('PAX-2026-00109', 'FF-10987654', 'Silver',        29000, 22000),
('PAX-2026-00110', 'FF-99887766', 'Gold',          71000, 45000);

-- Bookings (8 PNRs)
INSERT INTO bookings (pnr, passenger_id, booking_date) VALUES
('ABCDE1', 'PAX-2026-00101', '2026-04-15'),  -- Carlos: BOG→PTY→MIA (disrupted)
('FGHIJ2', 'PAX-2026-00102', '2026-04-20'),  -- Ana: GRU→PTY→JFK
('KLMNO3', 'PAX-2026-00103', '2026-05-01'),  -- Roberto: local PTY→MIA
('PQRST4', 'PAX-2026-00104', '2026-05-05'),  -- Maria: SCL→PTY→ORD (at risk)
('UVWXY5', 'PAX-2026-00105', '2026-04-28'),  -- Jorge: LIM→PTY→MIA
('BCDEF6', 'PAX-2026-00106', '2026-05-10'),  -- Isabella: BOG→PTY (one-way)
('GHIJK7', 'PAX-2026-00107', '2026-05-12'),  -- Diego: BOG→PTY→JFK
('LMNOP8', 'PAX-2026-00110', '2026-05-08');  -- Camila: GRU→PTY→ORD

-- Booking Segments (multi-leg itineraries)
-- Carlos Martinez: BOG→PTY (FL801, delayed) + PTY→MIA (FL445, will miss)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(1, 1, 'FL801', 'BOG', 'PTY', '2026-05-21 08:30:00-05:00', '2026-05-21 11:15:00-05:00', '4A', 'Business', 'CHECKED_IN'),
(1, 2, 'FL445', 'PTY', 'MIA', '2026-05-21 12:30:00-05:00', '2026-05-21 16:45:00-04:00', '3C', 'Business', 'CONFIRMED');

-- Ana Silva: GRU→PTY + PTY→JFK
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(2, 1, 'FL215', 'GRU', 'PTY', '2026-05-21 06:00:00-03:00', '2026-05-21 11:30:00-05:00', '12B', 'Economy', 'CHECKED_IN'),
(2, 2, 'FL302', 'PTY', 'JFK', '2026-05-21 13:00:00-05:00', '2026-05-21 19:15:00-04:00', '14A', 'Economy', 'CONFIRMED');

-- Roberto Gonzalez: PTY→MIA (direct)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(3, 1, 'FL445', 'PTY', 'MIA', '2026-05-21 12:30:00-05:00', '2026-05-21 16:45:00-04:00', '1A', 'Business', 'CONFIRMED');

-- Maria Fernandez: SCL→PTY (FL510, delayed 45 min) + PTY→ORD (FL612)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(4, 1, 'FL510', 'SCL', 'PTY', '2026-05-21 07:15:00-04:00', '2026-05-21 12:45:00-05:00', '8C', 'Economy', 'CHECKED_IN'),
(4, 2, 'FL612', 'PTY', 'ORD', '2026-05-21 14:00:00-05:00', '2026-05-21 19:30:00-05:00', '10A', 'Economy', 'CONFIRMED');

-- Jorge Lopez: LIM→PTY + PTY→MIA
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(5, 1, 'FL725', 'LIM', 'PTY', '2026-05-21 09:00:00-05:00', '2026-05-21 13:30:00-05:00', '15D', 'Economy', 'CONFIRMED'),
(5, 2, 'FL447', 'PTY', 'MIA', '2026-05-21 15:30:00-05:00', '2026-05-21 19:45:00-04:00', '16A', 'Economy', 'CONFIRMED');

-- Isabella Ramirez: BOG→PTY (one-way, same delayed flight FL801)
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(6, 1, 'FL801', 'BOG', 'PTY', '2026-05-21 08:30:00-05:00', '2026-05-21 11:15:00-05:00', '6B', 'Economy', 'CHECKED_IN');

-- Diego Torres: BOG→PTY + PTY→JFK
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(7, 1, 'FL801', 'BOG', 'PTY', '2026-05-21 08:30:00-05:00', '2026-05-21 11:15:00-05:00', '22A', 'Economy', 'CHECKED_IN'),
(7, 2, 'FL302', 'PTY', 'JFK', '2026-05-21 13:00:00-05:00', '2026-05-21 19:15:00-04:00', '20C', 'Economy', 'CONFIRMED');

-- Camila Rojas: GRU→PTY + PTY→ORD
INSERT INTO booking_segments (booking_id, segment_order, flight_number, origin, destination, departure_time, arrival_time, seat_number, cabin, segment_status) VALUES
(8, 1, 'FL215', 'GRU', 'PTY', '2026-05-21 06:00:00-03:00', '2026-05-21 11:30:00-05:00', '18B', 'Economy', 'CONFIRMED'),
(8, 2, 'FL612', 'PTY', 'ORD', '2026-05-21 14:00:00-05:00', '2026-05-21 19:30:00-05:00', '19A', 'Economy', 'CONFIRMED');
