-- MariaDB 10.5. Run once in an empty project schema, before 02_sample_data.sql.
-- Stop on errors. CREATE statements commit automatically.

SET NAMES utf8mb4;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION,ONLY_FULL_GROUP_BY';

-- Accounts

CREATE TABLE user_account (
    user_id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) NOT NULL UNIQUE,
    display_name VARCHAR(100) NOT NULL,
    password VARCHAR(255) NOT NULL,
    role ENUM('SHIPPER', 'CARRIER', 'VIEWER') NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Hubs and lanes

CREATE TABLE hub (
    hub_id INT AUTO_INCREMENT PRIMARY KEY,
    hub_code VARCHAR(10) NOT NULL UNIQUE,
    hub_name VARCHAR(100) NOT NULL,
    city VARCHAR(100) NOT NULL,
    region ENUM('Northeast', 'Southeast', 'Midwest', 'Southwest', 'West') NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE lane (
    lane_id INT AUTO_INCREMENT PRIMARY KEY,
    origin_hub_id INT NOT NULL,
    dest_hub_id INT NOT NULL,
    CONSTRAINT uq_lane_pair UNIQUE (origin_hub_id, dest_hub_id),
    CONSTRAINT chk_lane_hubs CHECK (origin_hub_id <> dest_hub_id),
    CONSTRAINT fk_lane_origin FOREIGN KEY (origin_hub_id) REFERENCES hub(hub_id),
    CONSTRAINT fk_lane_dest FOREIGN KEY (dest_hub_id) REFERENCES hub(hub_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Vehicles and subtype details

CREATE TABLE vehicle (
    vehicle_id INT AUTO_INCREMENT PRIMARY KEY,
    vehicle_code VARCHAR(40) NOT NULL UNIQUE,
    carrier_id INT NOT NULL,
    home_hub_id INT NOT NULL,
    vehicle_type ENUM('BOX_TRUCK', 'REFRIGERATED_VAN', 'RAIL_CAR') NOT NULL,
    CONSTRAINT fk_vehicle_owner FOREIGN KEY (carrier_id) REFERENCES user_account(user_id),
    CONSTRAINT fk_vehicle_home FOREIGN KEY (home_hub_id) REFERENCES hub(hub_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE box_truck (
    vehicle_id INT PRIMARY KEY,
    cargo_volume_m3 DECIMAL(8,2) NOT NULL,
    gross_weight_rating_kg DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_bt_values CHECK (cargo_volume_m3 > 0 AND gross_weight_rating_kg > 0),
    CONSTRAINT fk_bt_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicle(vehicle_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE refrigerated_van (
    vehicle_id INT PRIMARY KEY,
    temp_min_c DECIMAL(5,2) NOT NULL,
    temp_max_c DECIMAL(5,2) NOT NULL,
    payload_limit_kg DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_rv_temp CHECK (temp_min_c < temp_max_c),
    CONSTRAINT chk_rv_payload CHECK (payload_limit_kg > 0),
    CONSTRAINT fk_rv_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicle(vehicle_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE rail_car (
    vehicle_id INT PRIMARY KEY,
    axle_count INT NOT NULL,
    track_gauge_mm DECIMAL(7,2) NOT NULL,
    CONSTRAINT chk_rc_values CHECK (axle_count > 0 AND track_gauge_mm > 0),
    CONSTRAINT fk_rc_vehicle FOREIGN KEY (vehicle_id)
        REFERENCES vehicle(vehicle_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Departures and shipments

CREATE TABLE departure (
    departure_id INT AUTO_INCREMENT PRIMARY KEY,
    departure_code VARCHAR(40) NOT NULL UNIQUE,
    vehicle_id INT NOT NULL,
    lane_id INT NOT NULL,
    depart_at DATETIME NOT NULL,
    max_weight_kg DECIMAL(10,2) NOT NULL,
    CONSTRAINT chk_dep_weight CHECK (max_weight_kg > 0),
    CONSTRAINT fk_dep_vehicle FOREIGN KEY (vehicle_id) REFERENCES vehicle(vehicle_id),
    CONSTRAINT fk_dep_lane FOREIGN KEY (lane_id) REFERENCES lane(lane_id),
    INDEX ix_departure_lane_time (lane_id, depart_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE shipment (
    shipment_id INT AUTO_INCREMENT PRIMARY KEY,
    shipment_code VARCHAR(40) NOT NULL UNIQUE,
    shipper_id INT NOT NULL,
    lane_id INT NOT NULL,
    weight_kg DECIMAL(10,2) NOT NULL,
    promised_date DATE NOT NULL,
    current_status ENUM('CREATED', 'RECEIVED', 'IN_TRANSIT', 'ARRIVED_AT_HUB',
                        'OUT_FOR_DELIVERY', 'DELIVERED') NOT NULL DEFAULT 'CREATED',
    on_time BOOLEAN NULL,
    last_scan_seq INT NOT NULL DEFAULT 0,
    last_scan_ts DATETIME NULL,
    CONSTRAINT chk_ship_weight CHECK (weight_kg > 0),
    CONSTRAINT chk_ship_ontime CHECK ((current_status = 'DELIVERED') = (on_time IS NOT NULL)),
    CONSTRAINT chk_ship_ontime_value CHECK (on_time IS NULL OR on_time IN (0, 1)),
    CONSTRAINT chk_ship_last_scan CHECK (
        (last_scan_seq = 0 AND last_scan_ts IS NULL)
        OR (last_scan_seq > 0 AND last_scan_ts IS NOT NULL)
    ),
    CONSTRAINT fk_ship_shipper FOREIGN KEY (shipper_id) REFERENCES user_account(user_id),
    CONSTRAINT fk_ship_lane FOREIGN KEY (lane_id) REFERENCES lane(lane_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- A shipment has at most one booking. Its requested lane stays in shipment.
CREATE TABLE booking (
    shipment_id INT PRIMARY KEY,
    departure_id INT NOT NULL,
    booked_at DATETIME NOT NULL,
    CONSTRAINT fk_booking_shipment FOREIGN KEY (shipment_id) REFERENCES shipment(shipment_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_booking_departure FOREIGN KEY (departure_id) REFERENCES departure(departure_id),
    INDEX ix_booking_departure (departure_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Scan history

CREATE TABLE scan_event (
    shipment_id INT NOT NULL,
    seq_no INT NOT NULL,
    scan_ts DATETIME NOT NULL,
    hub_id INT NOT NULL,
    status ENUM('RECEIVED', 'IN_TRANSIT', 'ARRIVED_AT_HUB', 'OUT_FOR_DELIVERY', 'DELIVERED') NOT NULL,
    PRIMARY KEY (shipment_id, seq_no),
    CONSTRAINT chk_scan_seq CHECK (seq_no > 0),
    CONSTRAINT fk_scan_shipment FOREIGN KEY (shipment_id) REFERENCES shipment(shipment_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_scan_hub FOREIGN KEY (hub_id) REFERENCES hub(hub_id),
    INDEX ix_scan_status_time (status, scan_ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

DELIMITER $$

-- Booking procedure

-- Call outside an active transaction. Lock departure before shipment so
-- competing bookings use a fresh capacity sum.
CREATE PROCEDURE book_shipment (
    IN p_shipment_id INT,
    IN p_departure_id INT,
    IN p_shipper_id INT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
BEGIN
    IF @@in_transaction <> 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Call book_shipment outside an active transaction';
    END IF;

    BEGIN
        DECLARE v_departure_lane INT DEFAULT NULL;
        DECLARE v_capacity DECIMAL(10,2);
        DECLARE v_shipper INT DEFAULT NULL;
        DECLARE v_shipment_lane INT;
        DECLARE v_existing_departure INT;
        DECLARE v_weight DECIMAL(10,2);
        DECLARE v_status VARCHAR(30);
        DECLARE v_booked DECIMAL(20,2);
        DECLARE v_missing BOOLEAN DEFAULT FALSE;
        DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_missing = TRUE;
        DECLARE EXIT HANDLER FOR SQLEXCEPTION
        BEGIN
            ROLLBACK;
            RESIGNAL;
        END;

        START TRANSACTION;

        SELECT lane_id, max_weight_kg
          INTO v_departure_lane, v_capacity
          FROM departure
         WHERE departure_id = p_departure_id
         FOR UPDATE;
        IF v_missing THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Departure not found';
        END IF;

        SELECT shipper_id, lane_id, weight_kg, current_status
          INTO v_shipper, v_shipment_lane, v_weight, v_status
          FROM shipment
         WHERE shipment_id = p_shipment_id
         FOR UPDATE;
        IF v_missing THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment not found';
        END IF;
        IF p_shipper_id IS NULL OR v_shipper <> p_shipper_id OR NOT EXISTS (
            SELECT 1 FROM user_account WHERE user_id = p_shipper_id AND role = 'SHIPPER'
        ) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment is not owned by this shipper';
        END IF;
        SELECT MAX(departure_id) INTO v_existing_departure
          FROM booking WHERE shipment_id = p_shipment_id FOR UPDATE;
        IF v_existing_departure IS NOT NULL THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment is already booked';
        END IF;
        IF v_status = 'DELIVERED' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Delivered shipments cannot be booked';
        END IF;
        IF v_shipment_lane <> v_departure_lane THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment and departure lanes must match';
        END IF;

        SELECT COALESCE(SUM(s.weight_kg), 0)
          INTO v_booked
          FROM booking AS b
          JOIN shipment AS s ON s.shipment_id = b.shipment_id
         WHERE b.departure_id = p_departure_id
         FOR UPDATE;
        IF v_booked + v_weight > v_capacity THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient departure capacity';
        END IF;

        INSERT INTO booking (shipment_id, departure_id, booked_at)
        VALUES (p_shipment_id, p_departure_id, CURRENT_TIMESTAMP);
        COMMIT;

        SELECT p_shipment_id AS shipment_id, p_departure_id AS departure_id,
               v_booked + v_weight AS booked_weight_kg,
               v_capacity - v_booked - v_weight AS remaining_weight_kg;
    END;
END$$

-- Scan triggers

-- Lock the shipment and read its latest scan metadata. Locking scan_event
-- inside its own insert trigger would cause MariaDB error 1442.
CREATE TRIGGER enforce_scan_chronology
BEFORE INSERT ON scan_event
FOR EACH ROW
BEGIN
    DECLARE v_current_status VARCHAR(30) DEFAULT NULL;
    DECLARE v_departure_id INT DEFAULT NULL;
    DECLARE v_last_seq INT DEFAULT 0;
    DECLARE v_last_ts DATETIME DEFAULT NULL;
    DECLARE v_missing BOOLEAN DEFAULT FALSE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_missing = TRUE;

    SELECT current_status, last_scan_seq, last_scan_ts
      INTO v_current_status, v_last_seq, v_last_ts
      FROM shipment WHERE shipment_id = NEW.shipment_id FOR UPDATE;
    IF v_missing THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment not found';
    END IF;
    SELECT MAX(departure_id) INTO v_departure_id
      FROM booking WHERE shipment_id = NEW.shipment_id FOR UPDATE;
    IF v_departure_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Book the shipment before posting scans';
    END IF;
    IF v_current_status = 'DELIVERED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Shipment is already delivered';
    END IF;

    IF NEW.seq_no IS NULL OR NEW.seq_no <> v_last_seq + 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Scan sequence must be the next consecutive number';
    END IF;
    IF NEW.scan_ts IS NULL OR (v_last_ts IS NOT NULL AND NEW.scan_ts < v_last_ts) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Scan timestamp cannot precede the latest scan';
    END IF;
    IF NEW.status IS NULL OR FIND_IN_SET(NEW.status,
        'RECEIVED,IN_TRANSIT,ARRIVED_AT_HUB,OUT_FOR_DELIVERY,DELIVERED') = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid scan status';
    END IF;
    IF v_last_seq = 0 AND NEW.status <> 'RECEIVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'First scan must be RECEIVED';
    END IF;
    IF FIND_IN_SET(NEW.status,
        'CREATED,RECEIVED,IN_TRANSIT,ARRIVED_AT_HUB,OUT_FOR_DELIVERY,DELIVERED')
       < FIND_IN_SET(v_current_status,
        'CREATED,RECEIVED,IN_TRANSIT,ARRIVED_AT_HUB,OUT_FOR_DELIVERY,DELIVERED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Scan status cannot regress';
    END IF;
    -- Forward skips are allowed, but later statuses require an IN_TRANSIT scan.
    IF NEW.status IN ('ARRIVED_AT_HUB', 'OUT_FOR_DELIVERY', 'DELIVERED')
       AND v_current_status IN ('CREATED', 'RECEIVED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Record IN_TRANSIT before later movement statuses';
    END IF;
END$$

CREATE TRIGGER maintain_shipment_status
AFTER INSERT ON scan_event
FOR EACH ROW
BEGIN
    UPDATE shipment
       SET current_status = NEW.status,
           last_scan_seq = NEW.seq_no,
           last_scan_ts = NEW.scan_ts,
           on_time = CASE
               WHEN NEW.status = 'DELIVERED' THEN DATE(NEW.scan_ts) <= promised_date
               ELSE NULL
           END
     WHERE shipment_id = NEW.shipment_id;
END$$

-- Subtype matching uses the parent's type without storing a second discriminator.
CREATE TRIGGER enforce_vehicle_type
BEFORE UPDATE ON vehicle
FOR EACH ROW
BEGIN
    IF NEW.vehicle_type <> OLD.vehicle_type THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type cannot be changed';
    END IF;
END$$

CREATE TRIGGER enforce_box_truck_insert
BEFORE INSERT ON box_truck
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'BOX_TRUCK' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match BOX_TRUCK';
    END IF;
END$$

CREATE TRIGGER enforce_box_truck_update
BEFORE UPDATE ON box_truck
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    IF NEW.vehicle_id <> OLD.vehicle_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subtype vehicle ID cannot be changed';
    END IF;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'BOX_TRUCK' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match BOX_TRUCK';
    END IF;
END$$

CREATE TRIGGER enforce_refrigerated_van_insert
BEFORE INSERT ON refrigerated_van
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'REFRIGERATED_VAN' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match REFRIGERATED_VAN';
    END IF;
END$$

CREATE TRIGGER enforce_refrigerated_van_update
BEFORE UPDATE ON refrigerated_van
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    IF NEW.vehicle_id <> OLD.vehicle_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subtype vehicle ID cannot be changed';
    END IF;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'REFRIGERATED_VAN' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match REFRIGERATED_VAN';
    END IF;
END$$

CREATE TRIGGER enforce_rail_car_insert
BEFORE INSERT ON rail_car
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'RAIL_CAR' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match RAIL_CAR';
    END IF;
END$$

CREATE TRIGGER enforce_rail_car_update
BEFORE UPDATE ON rail_car
FOR EACH ROW
BEGIN
    DECLARE v_type VARCHAR(30) DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_type = NULL;

    IF NEW.vehicle_id <> OLD.vehicle_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Subtype vehicle ID cannot be changed';
    END IF;

    SELECT vehicle_type INTO v_type FROM vehicle
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF v_type IS NULL OR v_type <> 'RAIL_CAR' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vehicle type must match RAIL_CAR';
    END IF;
END$$

DELIMITER ;

-- Reporting views

CREATE VIEW v_departure_load AS
SELECT d.departure_id, d.departure_code, d.vehicle_id, d.lane_id,
       d.depart_at, d.max_weight_kg,
       COALESCE(SUM(s.weight_kg), 0) AS booked_weight_kg,
       d.max_weight_kg - COALESCE(SUM(s.weight_kg), 0) AS remaining_weight_kg,
       100.0 * COALESCE(SUM(s.weight_kg), 0) / d.max_weight_kg AS utilization_pct
  FROM departure AS d
  LEFT JOIN booking AS b ON b.departure_id = d.departure_id
  LEFT JOIN shipment AS s ON s.shipment_id = b.shipment_id
 GROUP BY d.departure_id, d.departure_code, d.vehicle_id, d.lane_id,
          d.depart_at, d.max_weight_kg;

CREATE VIEW v_delivered_shipment AS
SELECT s.shipment_id, s.shipment_code, s.shipper_id, s.lane_id,
       b.departure_id, s.weight_kg, s.promised_date, s.on_time,
       v.carrier_id, e.scan_ts AS delivered_at
  FROM shipment AS s
  JOIN booking AS b ON b.shipment_id = s.shipment_id
  JOIN departure AS d ON d.departure_id = b.departure_id
  JOIN vehicle AS v ON v.vehicle_id = d.vehicle_id
  JOIN scan_event AS e ON e.shipment_id = s.shipment_id AND e.status = 'DELIVERED';
