# Freight Tracking Database Design Report

CSC 540 Project 1 Deliverable 2

Mulya Patel (mspate22), Namit Patel (npatel44), Pranshav Patel (ppatel49)

November 14 2026

## 1 Model and implementation

Our application manages freight bookings, movement histories, and delivery commitments using MariaDB 10.5 and a Python Flask interface. The schema has eleven base tables covering accounts, hubs, lanes, vehicles and three vehicle subtypes, departures, shipments, bookings, and scan events. This report explains the dependencies and constraints in the implemented schema. All base tables satisfy BCNF under the stated domain dependencies.

Each account has one role. A hub belongs to one of the five fixed regions. A lane is an ordered pair of different hubs. A carrier owns vehicles, and each departure assigns a vehicle to a lane at a scheduled time with a maximum weight. A shipment belongs to a shipper and keeps its requested lane before booking. A separate booking associates it with at most one departure. Scan events form a weak entity identified by the shipment and its sequence number. Vehicle specialization is disjoint, with separate attributes for box trucks, refrigerated vans, and rail cars.

## 2 Functional dependencies

The notation X -> Y means that each value of X determines one value of Y. We derive dependencies from the domain and declared keys, rather than from accidental patterns in the sample records. Numeric keys provide internal identity. Unique usernames and hub, vehicle, departure, and shipment codes provide alternate candidate keys for the same records.

In user_account, either user_id or username determines display_name, password, and role, as well as the other identifier. In hub, either hub_id or hub_code determines hub_name, city, and region. We assume no additional dependency such as city -> region because city names need not uniquely identify a geographic location.

In lane, lane_id -> origin_hub_id, dest_hub_id. The ordered pair (origin_hub_id, dest_hub_id) is another candidate key. Keeping hubs and lanes separate avoids repeating a hub's descriptive attributes in shipment and departure records.

In vehicle, either vehicle_id or vehicle_code determines carrier_id, home_hub_id, and vehicle_type. Vehicle attributes are separated from departure attributes because a vehicle may operate many departures. Each subtype's vehicle_id determines its type-specific attributes. Only the parent vehicle stores vehicle_type, and subtype triggers enforce matching types.

In departure, either departure_id or departure_code determines vehicle_id, lane_id, depart_at, and max_weight_kg. Carrier ownership is obtained through vehicle, avoiding a repeated carrier_id in departure. In shipment, either shipment_id or shipment_code determines its owner, requested lane, weight, promised date, and stored movement state. In booking, shipment_id determines departure_id and booked_at. A departure can carry several shipments, so departure_id is not unique in booking.

In scan_event, (shipment_id, seq_no) determines scan_ts, hub_id, and status. Neither component alone identifies a scan. Timestamps are not keys because equal timestamps are permitted. Separating the repeated scan history from shipment preserves one shipment row regardless of how many scans it receives. Appendix A lists the candidate keys and normalization assessment for each table.

<!-- page -->

## 3 Normalization assessment

All base tables store atomic values and satisfy 1NF. BCNF requires every determinant of a nontrivial functional dependency to be a superkey. 3NF also permits a dependent attribute that belongs to a candidate key. A primary key alone therefore does not establish either normal form.

The candidate keys in user_account, hub, lane, vehicle, departure, and shipment are their numeric IDs and their unique usernames or readable codes. Each key determines the other stored attributes of its relation. The ordered hub pair is another candidate key in lane. No additional dependencies between descriptive fields are assumed. For example, hub names and city names are not treated as unique identifiers.

The earlier shipment table stored departure_id, booked_at, and lane_id together. For booked shipments, a departure determines a lane and may serve several shipments. We decomposed the booking facts into booking(shipment_id, departure_id, booked_at). Shipment retains its requested lane, so unbooked shipments still have an origin and destination. The primary key of booking is shipment_id, which enforces at most one departure per shipment. Its only stated determinant is that key, so booking satisfies BCNF.

The booking relation references both shipment and departure. The procedure compares their lanes before recording the association. Views and application queries reconstruct a booked shipment's transportation details through booking. Departure-to-lane dependency is contained in departure, whose departure_id is a candidate key. The schema therefore avoids repeating that dependency inside shipment.

We also removed vehicle_type from box_truck, refrigerated_van, and rail_car. Each subtype contains its vehicle_id primary key and attributes specific to that type. The dependency vehicle_id -> type-specific attributes has a key determinant, so each subtype is in BCNF. Matching-type triggers replace the earlier composite foreign keys, and a parent trigger prevents a vehicle's type from changing. The application inserts a vehicle and its one matching subtype in one transaction.

The weak relation scan_event has the composite key (shipment_id, seq_no), which determines timestamp, hub, and status. A shipment can have many scans, and sequence numbers repeat across shipments. Neither component alone determines the complete scan record. The table has no stated non-key determinants and satisfies BCNF.

Shipment current_status, on_time, last_scan_seq, and last_scan_ts cache results derived from scan history and the promised date. Within shipment these attributes depend on its candidate keys. Triggers maintain their agreement with scan_event. Capacity totals remain computed values in views and queries. The final design has no relation classified only as 3NF because every base relation satisfies the stronger BCNF condition under this dependency set.

## 4 Constraints in table definitions

Primary and unique keys enforce entity identity and readable-code uniqueness. Foreign keys enforce references between accounts, hubs, lanes, vehicles, departures, shipments, bookings, and scans. Each subtype now references vehicle through vehicle_id alone. CHECK constraints require positive weights and vehicle measurements, different lane endpoints, an ordered refrigeration temperature range, and positive scan sequence numbers. ENUM columns restrict roles, regions, vehicle types, and statuses.

An unbooked shipment has no booking row. Each booking requires both departure_id and booked_at, and its shipment_id primary key permits at most one booking per shipment. An index on booking.departure_id supports departure load calculations. The on_time field is NULL until delivery and is then restricted to 0 or 1. Latest-scan sequence and timestamp fields must be consistent about whether scans exist. Deleting a shipment cascades to its booking and scan events, and deleting a vehicle cascades to its subtype row. Other references protect shared operational records from accidental deletion.

<!-- page -->

## 5 Constraints enforced by database operations

The capacity rule involves several shipment rows and a departure row, so a row-level CHECK constraint cannot express it. The book_shipment procedure owns a transaction and locks the departure before the requested shipment. It verifies the requesting shipper, rejects an existing booking or delivered shipment, and checks lane equality. A locking SUM computes the weights already booked. If the new total exceeds max_weight_kg, the procedure raises an error and rolls back. Otherwise it inserts a booking row with the current booking timestamp and commits. Calls use authenticated shipper identity supplied by the application.

The departure lock serializes competing bookings. The locking aggregate reads current booking weights, including bookings committed by an earlier caller. Exactly full loads are accepted. The application calls the procedure outside an existing transaction, as required by its transaction guard. The v_departure_load view joins booking to shipment and derives booked load, remaining capacity, and utilization from shipment weights.

The enforce_scan_chronology trigger locks the shipment and reads its latest scan metadata. It requires an existing booking, the next sequence number, and a timestamp on or after the previous scan. It rejects backward status changes and further scans after delivery. The first scan must be RECEIVED, and later movement statuses require prior progress to IN_TRANSIT. Forward skips such as IN_TRANSIT to OUT_FOR_DELIVERY are accepted, matching the supplied sample histories.

The maintain_shipment_status trigger updates current_status and the latest scan fields after insertion. For a delivered scan, it records whether DATE(scan_ts) is on or before promised_date. This includes the entire promised day. Undelivered shipments retain NULL on_time and are excluded from on-time and late delivery counts. The triggers run in the same transaction as the scan insert. Parent-row metadata permits a current locking read without attempting to lock scan_event from its own trigger.

Seven additional triggers protect vehicle specialization. The insert and update triggers on each of the three subtype tables lock the parent vehicle and verify its type. Subtype updates cannot reassign vehicle_id, and enforce_vehicle_type prevents changes to the parent's type. Together these guards enforce disjoint subtype membership without repeating vehicle_type in the subtype tables. Total participation still depends on the application transaction that creates both rows.

## 6 Constraints enforced in application code

### Session identity and access control

The professor requires application-level roles and passwords. Flask verifies a stored password hash, matches the selected role, and stores the account identity in a signed session. Shipper actions are scoped to owned shipments. Carrier actions are scoped to owned vehicles and operated departures. Viewers have read-only routes. The application also checks that a scan's selected departure is the shipment's booked departure. Ordinary table constraints cannot identify which browser account initiated a request through the shared database connection, so session-based authorization is enforced before issuing SQL.

### Other application checks and transaction boundaries

Vehicle and subtype rows are inserted together in a transaction. This supplies total subtype participation for application-created vehicles, which the foreign keys alone cannot require from parent to child. Shipment lane, weight, and promised date can be edited only before booking or scanning, after locking the shipment. Departure edits lock the departure, recompute its load, reject an insufficient capacity, and preserve its lane when bookings exist. These are design choices implemented in application-managed transactions, rather than rules inherently impossible to enforce in database routines.

The application validates input formats and numeric ranges and returns readable errors. Scan hubs must exist, but the schema does not define intermediate stops or status-specific permissible hubs. Geographic plausibility is therefore not enforced. Each scan belongs to one shipment, even when several shipments share a departure.

<!-- page -->

## Appendix A Candidate keys and normalization

This table describes the final implemented relations. Readable codes are unique and required. The BCNF classifications use the domain dependencies described in Section 2.

| Relation | Candidate keys | Normalization assessment |
| --- | --- | --- |
| user_account | user_id or username | BCNF under the stated account dependencies. |
| hub | hub_id or hub_code | BCNF. Descriptive attributes depend on either key. |
| lane | lane_id or (origin_hub_id, dest_hub_id) | BCNF. The ordered hub pair identifies the lane. |
| vehicle | vehicle_id or vehicle_code | BCNF. Each key determines owner, home hub, and type. |
| box_truck | vehicle_id | BCNF. The key determines only type-specific attributes. |
| refrigerated_van | vehicle_id | BCNF. The key determines only type-specific attributes. |
| rail_car | vehicle_id | BCNF. The key determines only type-specific attributes. |
| departure | departure_id or departure_code | BCNF. Carrier is obtained through vehicle. |
| shipment | shipment_id or shipment_code | BCNF. Booking facts are stored separately. |
| booking | shipment_id | BCNF. The key determines departure_id and booked_at. |
| scan_event | (shipment_id, seq_no) | BCNF under the stated scan dependencies. |

The eleven base relations satisfy BCNF and therefore meet the minimum 3NF requirement. Lane compatibility is a constraint between shipment and departure enforced by the booking procedure. It is not represented by repeating departure_id in shipment.

### Sample data and analytical queries

The seed script maps the professor's labels to internal keys and loads 11 hubs, 8 accounts, 7 vehicles, 5 lanes, 10 departures, 23 shipments, 22 bookings, and 69 scans. Seed assumptions include demo passwords, city names derived from hub names, and booking timestamps one hour before first scans. Initially, 9 shipments are on time, 5 are late, and 9 are pending. The six numbered queries use SQL aggregation, RANK, LAG, and cumulative SUM as appropriate. Python executes parameterized SQL through PyMySQL, and the root View Queries screen uses the submitted query file directly.

### Implementation verification

Local MariaDB checks covered fresh installation from the submitted SQL scripts, competing capacity requests, subtype guards, scan validation, and the affected application pages and reports. The final submission uses the three numbered SQL files for setup.

Implementation basis is Project/sql/01_schema.sql, Project/sql/02_sample_data.sql, Project/sql/03_queries.sql, Project/app.py, Project/db.py, and Project/store.py. The updated ER model is provided in report/ER-model.svg and report/ER-model.drawio. Model terminology and team identification follow the project handouts and Deliverable 1 report.
