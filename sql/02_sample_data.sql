-- Professor's sample data. Run once after 01_schema.sql, with empty tables.
-- All application passwords are demo123, stored as Werkzeug scrypt hashes.
-- City names come from hub names. Booking times are one hour before first scans.
-- Sample codes map to integer keys. Scans populate status and on_time via triggers.

SET NAMES utf8mb4;
START TRANSACTION;

-- Accounts

INSERT INTO user_account (user_id, username, display_name, password, role) VALUES
    (1, 'C1', 'Piedmont Freight Lines', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'CARRIER'),
    (2, 'C2', 'Atlantic Coast Haulers', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'CARRIER'),
    (3, 'C3', 'Plains Rail Co', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'CARRIER'),
    (4, 'SH1', 'Triangle Textiles', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'SHIPPER'),
    (5, 'SH2', 'Oak City Electronics', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'SHIPPER'),
    (6, 'SH3', 'Carolina Produce Co', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'SHIPPER'),
    (7, 'SH4', 'Coastal Furniture', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'SHIPPER'),
    (8, 'VW1', 'Fedex', 'scrypt:32768:8:1$5nCeQdsqw0TG6bRY$925430f3693d601c405d93257abc4f659e34a630a84ba6a50f794c224706b4178bd4d606e14027ee0aa637ee164660e4d9c3cddf0547086f4c2774602a83f2be', 'VIEWER');

-- Hubs and lanes

INSERT INTO hub (hub_id, hub_code, hub_name, city, region) VALUES
    (1, 'RDU', 'Raleigh Hub', 'Raleigh', 'Southeast'),
    (2, 'ATL', 'Atlanta Hub', 'Atlanta', 'Southeast'),
    (3, 'MIA', 'Miami Hub', 'Miami', 'Southeast'),
    (4, 'JFK', 'New York Hub', 'New York', 'Northeast'),
    (5, 'BOS', 'Boston Hub', 'Boston', 'Northeast'),
    (6, 'ORD', 'Chicago Hub', 'Chicago', 'Midwest'),
    (7, 'STL', 'St. Louis Hub', 'St. Louis', 'Midwest'),
    (8, 'DFW', 'Dallas Hub', 'Dallas', 'Southwest'),
    (9, 'PHX', 'Phoenix Hub', 'Phoenix', 'Southwest'),
    (10, 'LAX', 'Los Angeles Hub', 'Los Angeles', 'West'),
    (11, 'SEA', 'Seattle Hub', 'Seattle', 'West');

INSERT INTO lane (lane_id, origin_hub_id, dest_hub_id) VALUES
    (1, 1, 2),
    (2, 2, 3),
    (3, 4, 5),
    (4, 6, 8),
    (5, 8, 10);

-- Vehicles and subtype details

INSERT INTO vehicle (vehicle_id, vehicle_code, carrier_id, home_hub_id, vehicle_type) VALUES
    (101, 'V101', 1, 1, 'BOX_TRUCK'),
    (102, 'V102', 1, 2, 'REFRIGERATED_VAN'),
    (103, 'V103', 1, 1, 'BOX_TRUCK'),
    (201, 'V201', 2, 4, 'BOX_TRUCK'),
    (202, 'V202', 2, 6, 'BOX_TRUCK'),
    (203, 'V203', 2, 6, 'REFRIGERATED_VAN'),
    (301, 'V301', 3, 8, 'RAIL_CAR');

INSERT INTO box_truck (vehicle_id, cargo_volume_m3, gross_weight_rating_kg) VALUES
    (101, 45.0, 12000.0),
    (103, 30.0, 8000.0),
    (201, 40.0, 10000.0),
    (202, 50.0, 14000.0);

INSERT INTO refrigerated_van (vehicle_id, temp_min_c, temp_max_c, payload_limit_kg) VALUES
    (102, -18.0, 4.0, 4000.0),
    (203, -25.0, -10.0, 3000.0);

INSERT INTO rail_car (vehicle_id, axle_count, track_gauge_mm) VALUES
    (301, 4, 1435.0);

-- Departures

INSERT INTO departure (departure_id, departure_code, vehicle_id, lane_id, depart_at, max_weight_kg) VALUES
    (1, 'D1', 101, 1, '2026-03-01 22:00', 10000.0),
    (2, 'D2', 102, 2, '2026-03-04 06:00', 4000.0),
    (3, 'D3', 201, 3, '2026-03-02 09:00', 8000.0),
    (4, 'D4', 202, 4, '2026-03-02 20:00', 12000.0),
    (5, 'D5', 301, 5, '2026-03-03 08:00', 9000.0),
    (6, 'D6', 101, 1, '2026-03-07 22:00', 10000.0),
    (7, 'D7', 103, 1, '2026-10-29 09:00', 2000.0),
    (8, 'D8', 101, 1, '2026-10-30 09:00', 8000.0),
    (9, 'D9', 101, 1, '2026-01-10 09:00', 10000.0),
    (10, 'D10', 101, 1, '2026-02-10 09:00', 10000.0);

-- Shipments and bookings

INSERT INTO shipment (shipment_id, shipment_code, shipper_id, lane_id, departure_id, booked_at, weight_kg, promised_date) VALUES
    (1, 'S1', 4, 1, 1, '2026-03-01 20:00:00', 3000.0, '2026-03-04'),
    (2, 'S2', 5, 3, 3, '2026-03-01 14:00:00', 2500.0, '2026-03-02'),
    (3, 'S3', 6, 1, 1, '2026-03-01 18:15:00', 2000.0, '2026-03-02'),
    (4, 'S4', 4, 3, 3, '2026-03-01 15:00:00', 1500.0, '2026-03-05'),
    (5, 'S5', 5, 2, 2, '2026-03-03 14:00:00', 2000.0, '2026-03-07'),
    (6, 'S6', 6, 2, 2, '2026-03-03 15:30:00', 1700.0, '2026-03-06'),
    (7, 'S7', 6, 4, 4, '2026-03-02 10:00:00', 3000.0, '2026-03-05'),
    (8, 'S8', 6, 4, 4, '2026-03-02 11:30:00', 4000.0, '2026-03-03'),
    (9, 'S9', 4, 1, 1, '2026-03-01 17:40:00', 2500.0, '2026-03-05'),
    (10, 'S10', 6, 1, 6, '2026-03-07 14:00:00', 2800.0, '2026-03-11'),
    (11, 'S11', 5, 5, 5, '2026-03-02 18:00:00', 3500.0, '2026-03-05'),
    (12, 'S12', 4, 1, 7, '2026-10-28 15:00:00', 1000.0, '2026-11-02'),
    (13, 'S13', 4, 1, 7, '2026-10-28 15:30:00', 1000.0, '2026-11-02'),
    (14, 'S14', 4, 1, NULL, NULL, 500.0, '2026-11-03'),
    (15, 'S15', 4, 1, 8, '2026-10-29 15:00:00', 500.0, '2026-11-02'),
    (16, 'S16', 4, 1, 8, '2026-10-29 16:00:00', 500.0, '2026-10-30'),
    (17, 'S17', 4, 1, 8, '2026-10-29 16:15:00', 1000.0, '2026-10-31'),
    (18, 'S18', 4, 1, 8, '2026-10-29 16:30:00', 1000.0, '2026-11-02'),
    (19, 'S19', 4, 1, 8, '2026-10-29 16:45:00', 1000.0, '2026-11-03'),
    (20, 'S20', 4, 1, 9, '2026-01-09 15:00:00', 1000.0, '2026-01-11'),
    (21, 'S21', 4, 1, 9, '2026-01-09 15:30:00', 1000.0, '2026-01-12'),
    (22, 'S22', 4, 1, 10, '2026-02-09 15:00:00', 1000.0, '2026-02-11'),
    (23, 'S23', 4, 1, 10, '2026-02-09 15:30:00', 1000.0, '2026-02-12');

-- Scan history, in sequence order

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (1, 1, '2026-03-01 21:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (1, 2, '2026-03-01 22:05', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (1, 3, '2026-03-02 12:30', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (1, 4, '2026-03-02 14:00', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (2, 1, '2026-03-01 15:00', 4, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (2, 2, '2026-03-02 09:10', 4, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (2, 3, '2026-03-03 08:00', 5, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (2, 4, '2026-03-03 11:30', 5, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (3, 1, '2026-03-01 19:15', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (3, 2, '2026-03-01 22:05', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (3, 3, '2026-03-02 18:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (3, 4, '2026-03-02 20:45', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (4, 1, '2026-03-01 16:00', 4, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (4, 2, '2026-03-02 09:10', 4, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (5, 1, '2026-03-03 15:00', 2, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (5, 2, '2026-03-04 06:10', 2, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (5, 3, '2026-03-06 08:00', 3, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (5, 4, '2026-03-06 12:15', 3, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (6, 1, '2026-03-03 16:30', 2, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (6, 2, '2026-03-04 06:10', 2, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (6, 3, '2026-03-07 09:00', 3, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (6, 4, '2026-03-07 16:20', 3, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (7, 1, '2026-03-02 11:00', 6, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (7, 2, '2026-03-02 20:15', 6, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (7, 3, '2026-03-04 07:30', 8, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (7, 4, '2026-03-04 11:00', 8, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (8, 1, '2026-03-02 12:30', 6, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (8, 2, '2026-03-02 20:15', 6, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (8, 3, '2026-03-05 07:00', 8, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (8, 4, '2026-03-05 09:45', 8, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (9, 1, '2026-03-01 18:40', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (9, 2, '2026-03-01 22:05', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (9, 3, '2026-03-03 09:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (9, 4, '2026-03-03 12:00', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (10, 1, '2026-03-07 15:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (10, 2, '2026-03-07 22:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (10, 3, '2026-03-10 08:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (10, 4, '2026-03-10 10:30', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (11, 1, '2026-03-02 19:00', 8, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (11, 2, '2026-03-03 08:30', 8, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (11, 3, '2026-03-07 06:00', 10, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (11, 4, '2026-03-07 08:30', 10, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (12, 1, '2026-10-28 16:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (13, 1, '2026-10-28 16:30', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (15, 1, '2026-10-29 16:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (16, 1, '2026-10-29 17:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (16, 2, '2026-10-30 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (17, 1, '2026-10-29 17:15', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (17, 2, '2026-10-30 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (18, 1, '2026-10-29 17:30', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (18, 2, '2026-10-30 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (19, 1, '2026-10-29 17:45', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (19, 2, '2026-10-30 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (20, 1, '2026-01-09 16:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (20, 2, '2026-01-10 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (20, 3, '2026-01-11 08:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (20, 4, '2026-01-11 10:00', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (21, 1, '2026-01-09 16:30', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (21, 2, '2026-01-10 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (21, 3, '2026-01-11 08:15', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (21, 4, '2026-01-11 11:00', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (22, 1, '2026-02-09 16:00', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (22, 2, '2026-02-10 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (22, 3, '2026-02-11 08:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (22, 4, '2026-02-11 10:00', 2, 'DELIVERED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (23, 1, '2026-02-09 16:30', 1, 'RECEIVED');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (23, 2, '2026-02-10 09:10', 1, 'IN_TRANSIT');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (23, 3, '2026-02-13 08:00', 2, 'OUT_FOR_DELIVERY');

INSERT INTO scan_event (shipment_id, seq_no, scan_ts, hub_id, status) VALUES
    (23, 4, '2026-02-13 11:00', 2, 'DELIVERED');

COMMIT;

-- Import checks

SELECT 'user_account' AS table_name, COUNT(*) AS row_count FROM user_account
UNION ALL SELECT 'hub', COUNT(*) FROM hub
UNION ALL SELECT 'lane', COUNT(*) FROM lane
UNION ALL SELECT 'vehicle', COUNT(*) FROM vehicle
UNION ALL SELECT 'box_truck', COUNT(*) FROM box_truck
UNION ALL SELECT 'refrigerated_van', COUNT(*) FROM refrigerated_van
UNION ALL SELECT 'rail_car', COUNT(*) FROM rail_car
UNION ALL SELECT 'departure', COUNT(*) FROM departure
UNION ALL SELECT 'shipment', COUNT(*) FROM shipment
UNION ALL SELECT 'scan_event', COUNT(*) FROM scan_event;

SELECT SUM(on_time = 1) AS on_time_shipments,
       SUM(on_time = 0) AS late_shipments,
       SUM(on_time IS NULL) AS pending_shipments
  FROM shipment;

-- An empty result confirms that no departure is over capacity.
SELECT departure_code, booked_weight_kg, max_weight_kg
  FROM v_departure_load WHERE booked_weight_kg > max_weight_kg;

-- Optional capacity-rejection example. Run separately.
-- SET @s = (SELECT shipment_id FROM shipment WHERE shipment_code = 'S14');
-- SET @d = (SELECT departure_id FROM departure WHERE departure_code = 'D7');
-- SET @u = (SELECT user_id FROM user_account WHERE username = 'SH1');
-- CALL book_shipment(@s, @d, @u);
-- Expected error: Insufficient departure capacity; S14 stays unbooked.
