-- Required queries, in the professor's order. Run after the sample-data script.
-- Set parameters below. Date ranges include both dates; running totals start there.

SET @start_date = '2026-01-01';
SET @end_date = '2026-12-31';
SET @top_n = 3;
SET @shipment_code = 'S1';
SET @carrier_code = NULL; -- NULL means all carriers, or use 'C1', 'C2', 'C3'.

-- 1. Number of vehicles of each type owned by each carrier.
SELECT c.username AS carrier_code, c.display_name AS carrier_name,
       t.vehicle_type, COUNT(v.vehicle_id) AS vehicle_count
  FROM user_account AS c
 CROSS JOIN (
       SELECT 'BOX_TRUCK' AS vehicle_type
       UNION ALL SELECT 'REFRIGERATED_VAN'
       UNION ALL SELECT 'RAIL_CAR'
 ) AS t
  LEFT JOIN vehicle AS v
    ON v.carrier_id = c.user_id AND v.vehicle_type = t.vehicle_type
 WHERE c.role = 'CARRIER'
 GROUP BY c.user_id, c.username, c.display_name, t.vehicle_type
 ORDER BY c.username, t.vehicle_type;

-- 2. Rank departures per lane by weight utilization, and list top N ranks.
-- Rank before rounding. Ties share a rank and can return more than N rows.
WITH ranked_departures AS (
    SELECT dl.*,
           RANK() OVER (
               PARTITION BY dl.lane_id ORDER BY dl.utilization_pct DESC
           ) AS utilization_rank
      FROM v_departure_load AS dl
     WHERE dl.depart_at >= @start_date
       AND dl.depart_at < DATE_ADD(@end_date, INTERVAL 1 DAY)
)
SELECT o.hub_code AS origin, dest.hub_code AS destination,
       r.utilization_rank, r.departure_code, r.depart_at,
       r.booked_weight_kg, r.max_weight_kg, r.remaining_weight_kg,
       ROUND(r.utilization_pct, 2) AS utilization_pct
  FROM ranked_departures AS r
  JOIN lane AS l ON l.lane_id = r.lane_id
  JOIN hub AS o ON o.hub_id = l.origin_hub_id
  JOIN hub AS dest ON dest.hub_id = l.dest_hub_id
 WHERE r.utilization_rank <= @top_n
 ORDER BY o.hub_code, dest.hub_code, r.utilization_rank, r.departure_code;

-- 3. Elapsed time between consecutive scans for a given shipment.
WITH ordered_scans AS (
    SELECT s.shipment_code, e.seq_no, e.hub_id, e.status, e.scan_ts,
           LAG(e.scan_ts) OVER (
               PARTITION BY e.shipment_id ORDER BY e.seq_no
           ) AS previous_scan_ts
      FROM scan_event AS e
      JOIN shipment AS s ON s.shipment_id = e.shipment_id
     WHERE s.shipment_code = @shipment_code
)
SELECT e.shipment_code, e.seq_no, h.hub_code, e.status,
       e.previous_scan_ts, e.scan_ts,
       TIMESTAMPDIFF(SECOND, e.previous_scan_ts, e.scan_ts) AS elapsed_seconds,
       ROUND(TIMESTAMPDIFF(SECOND, e.previous_scan_ts, e.scan_ts) / 3600.0, 2) AS elapsed_hours
  FROM ordered_scans AS e
  JOIN hub AS h ON h.hub_id = e.hub_id
 ORDER BY e.seq_no;

-- 4. Cumulative delivered weight per carrier by Monday-starting week.
-- Only weeks with deliveries appear.
WITH weekly_weight AS (
    SELECT ds.carrier_id,
           DATE_SUB(DATE(ds.delivered_at), INTERVAL WEEKDAY(ds.delivered_at) DAY) AS week_start,
           SUM(ds.weight_kg) AS delivered_weight_kg
      FROM v_delivered_shipment AS ds
      JOIN user_account AS c ON c.user_id = ds.carrier_id
     WHERE ds.delivered_at >= @start_date
       AND ds.delivered_at < DATE_ADD(@end_date, INTERVAL 1 DAY)
       AND (@carrier_code IS NULL OR c.username = @carrier_code)
     GROUP BY ds.carrier_id,
              DATE_SUB(DATE(ds.delivered_at), INTERVAL WEEKDAY(ds.delivered_at) DAY)
)
SELECT c.username AS carrier_code, c.display_name AS carrier_name,
       w.week_start, w.delivered_weight_kg,
       SUM(w.delivered_weight_kg) OVER (
           PARTITION BY w.carrier_id ORDER BY w.week_start
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_delivered_weight_kg
  FROM weekly_weight AS w
  JOIN user_account AS c ON c.user_id = w.carrier_id
 ORDER BY c.username, w.week_start;

-- 5. Departures carrying shipments belonging to at least two shippers.
SELECT d.departure_id, d.departure_code,
       COUNT(DISTINCT s.shipper_id) AS distinct_shipper_count
  FROM departure AS d
  JOIN booking AS b ON b.departure_id = d.departure_id
  JOIN shipment AS s ON s.shipment_id = b.shipment_id
 GROUP BY d.departure_id, d.departure_code
HAVING COUNT(DISTINCT s.shipper_id) >= 2
 ORDER BY d.departure_id;

-- 6. Shipments with no scan events, including the required owner and hubs.
SELECT s.shipment_id, s.shipment_code,
       u.username AS shipper_code, u.display_name AS shipper_name,
       o.hub_code AS origin, dest.hub_code AS destination, s.promised_date
  FROM shipment AS s
  JOIN user_account AS u ON u.user_id = s.shipper_id
  JOIN lane AS l ON l.lane_id = s.lane_id
  JOIN hub AS o ON o.hub_id = l.origin_hub_id
  JOIN hub AS dest ON dest.hub_id = l.dest_hub_id
 WHERE NOT EXISTS (
       SELECT 1 FROM scan_event AS e WHERE e.shipment_id = s.shipment_id
 )
 ORDER BY s.shipment_id;
