# Freight Tracking Database Design Report

CSC 540 Project 1 Deliverable 2

Mulya Patel (mspate22), Namit Patel (npatel44), Pranshav Patel (ppatel49)

November 14, 2026

## 1 Model and implementation

Our application tracks freight bookings, shipment movement, and delivery commitments. It uses MariaDB 10.5 and a Flask web interface written in Python. The schema has eleven base tables: accounts, hubs, lanes, vehicles, three vehicle subtypes, departures, shipments, bookings, and scan events. This report explains the dependencies and constraints in that schema. The core relations follow BCNF under the dependencies described below. The stored shipment table also includes derived movement state, which we discuss separately as deliberate denormalization.

Each account has exactly one role, and each hub belongs to one of five fixed regions. A lane is an ordered pair of two different hubs. Carriers own vehicles, and a departure assigns one vehicle to a lane at a scheduled time, with a maximum load weight. A shipment belongs to a shipper and records its requested lane before booking. A separate booking row links it to at most one departure. Scan events form a weak entity, identified by the shipment and a sequence number. Vehicle specialization is disjoint: box trucks, refrigerated vans, and rail cars each have their own attribute table.

## 2 Functional dependencies

We write X -> Y when each value of X determines exactly one value of Y. The dependencies below come from the domain and the declared keys, rather than patterns that happen to appear in the sample data. Numeric keys give records their internal identity. Unique usernames and the hub, vehicle, departure, and shipment codes provide alternate candidate keys.

In user_account, user_id and username each determine display_name, password, and role, and each determines the other identifier. In hub, hub_id and hub_code each determine the other identifier, hub_name, city, and region. We don't assume city -> region, since a city name doesn't uniquely identify a place.

In lane, lane_id -> origin_hub_id, dest_hub_id. The ordered pair (origin_hub_id, dest_hub_id) is a second candidate key and determines lane_id. Keeping hubs separate from lanes means a hub's descriptive attributes aren't repeated in every shipment and departure record.

In vehicle, vehicle_id and vehicle_code each determine the other identifier, carrier_id, home_hub_id, and vehicle_type. A vehicle can operate many departures, so vehicle attributes are stored separately from departure attributes. In each subtype table, vehicle_id determines the type-specific attributes. Only the parent vehicle row stores vehicle_type, and triggers on the subtypes check that their types match the parent.

In departure, departure_id and departure_code each determine the other identifier, vehicle_id, lane_id, depart_at, and max_weight_kg. The carrier is obtained through vehicle, so departure doesn't store its own carrier_id. In shipment, shipment_id and shipment_code each determine the other identifier, owner, requested lane, weight, promised date, and stored movement state. The movement state also has dependencies arising from its derivation, as discussed in Section 3. In booking, shipment_id determines departure_id and booked_at. One departure can carry several shipments, so departure_id is not unique in booking.

In scan_event, (shipment_id, seq_no) determines scan_ts, hub_id, and status. Neither column identifies a scan by itself. Timestamps can't serve as keys because multiple scans may share a timestamp, even within one shipment. Putting scan history in its own table keeps a single shipment row regardless of how many scans it collects. Appendix A lists the candidate keys and normalization assessment for every table.

<!-- page -->

## 3 Normalization assessment

Every base table holds atomic values, so all of them are in 1NF. BCNF requires the determinant of every nontrivial functional dependency to be a superkey. For 3NF, each nontrivial dependency X -> A must have either a superkey as its determinant or a dependent attribute A that belongs to a candidate key. Having a primary key doesn't by itself put a table in either form.

For user_account, hub, vehicle, and departure, the candidate keys are the numeric ID and the unique username or readable code. Each key determines the rest of the relation's attributes. Lane has a numeric ID and the ordered hub pair as its candidate keys; it has no separate readable-code column. We assume no additional dependencies among descriptive fields. Hub names and city names, for instance, are not treated as unique identifiers.

Our earlier shipment table kept departure_id, booked_at, and lane_id together. For booked shipments, departure_id determined lane_id but wasn't a key, since a departure could serve several shipments. We moved the booking facts into booking(shipment_id, departure_id, booked_at). Shipment keeps its requested lane, so an unbooked shipment still has an origin and destination. Booking's primary key is shipment_id, which limits each shipment to one departure. Under the stated dependencies, every nontrivial determinant in booking is a superkey, so booking is in BCNF.

Booking references both shipment and departure, and the booking procedure checks that their lanes match before inserting the row. Views and application queries reconstruct a booked shipment's transport details by joining through booking. The departure-to-lane dependency is stored in departure, where departure_id is a candidate key. Shipment retains its requested lane without also storing departure_id.

We also removed vehicle_type from box_truck, refrigerated_van, and rail_car. Each subtype now holds its vehicle_id primary key and its own attributes. Under the stated dependencies, vehicle_id determines all remaining attributes, with no non-key determinants, so each subtype is in BCNF. Triggers that check for a matching type replace the earlier composite foreign keys, and a trigger on the parent prevents changes to a vehicle's type. The application inserts a vehicle and its matching subtype row in one transaction.

scan_event is a weak relation whose composite key (shipment_id, seq_no) determines timestamp, hub, and status. A shipment can have many scans, and sequence numbers repeat across shipments, so neither part of the key works alone. Under the stated domain dependencies, the table has no non-key determinants and is in BCNF.

The stored shipment table needs a separate qualification. Its core attributes, shipment_id, shipment_code, shipper_id, lane_id, weight_kg, and promised_date, satisfy BCNF under the stated dependencies. It also stores current_status, on_time, last_scan_seq, and last_scan_ts as a cache of movement state. These derived columns introduce dependencies beyond the shipment keys. For example, the combination of current_status, last_scan_ts, and promised_date determines on_time: it is NULL before delivery and otherwise records whether the delivery date meets the promise. That combination is not a superkey, and on_time is not part of a candidate key. This dependency prevents an unqualified 3NF or BCNF classification of the full stored relation.

We therefore describe shipment as deliberately denormalized. Scan-insertion triggers maintain its cached state during the application's normal write path. A fully normalized version would keep the core shipment facts in shipment and calculate the derived state from scan_event in views or queries. Departure capacity totals already follow that approach: they are computed rather than stored.

## 4 Constraints in table definitions

Primary and unique keys enforce entity identity and keep readable codes unique. Foreign keys enforce references between accounts, hubs, lanes, vehicles, departures, shipments, bookings, and scans. Each subtype references vehicle through vehicle_id alone. CHECK constraints require positive weights and vehicle measurements, distinct lane endpoints, a minimum refrigeration temperature below the maximum, and positive scan sequence numbers. ENUM columns restrict roles, regions, vehicle types, and statuses to fixed sets.

An unbooked shipment has no booking row. A booking must have both departure_id and booked_at, and the shipment_id primary key allows at most one booking per shipment. An index on booking.departure_id supports departure load calculations. CHECK constraints require on_time to be NULL for undelivered shipments and either 0 or 1 for delivered shipments. The latest-scan sequence and timestamp fields must also agree: a zero sequence requires a NULL timestamp, while a positive sequence requires a timestamp. These checks don't independently verify the contents of scan_event; the insertion triggers maintain that agreement.

Deleting a shipment cascades to its booking and scan events, and deleting a vehicle cascades to its subtype row. Other foreign keys prevent deletion while referencing rows still exist. For example, a vehicle cannot be deleted while a departure references it.

<!-- page -->

## 5 Constraints enforced by database operations

The capacity rule spans several shipment rows and one departure row, so a row-level CHECK constraint can't express it. The book_shipment procedure handles it in its own transaction. It locks the departure first, then the requested shipment. It checks that the supplied account identity owns the shipment and has the SHIPPER role, rejects shipments that are already booked or delivered, and checks that the lanes match. A locking SUM totals the weight already booked. If adding the new shipment would exceed max_weight_kg, the procedure raises an error and rolls back. Otherwise, it inserts a booking row with the current timestamp and commits. The application supplies the authenticated shipper's identity; the procedure doesn't authenticate the browser session itself.

Locking the departure serializes competing bookings. The aggregate is a locking read, so it sees bookings committed by an earlier caller. A load that is exactly full is accepted. The procedure has a transaction guard, so the application calls it outside any open transaction. The v_departure_load view joins booking to shipment and derives booked load, remaining capacity, and utilization from shipment weights.

The enforce_scan_chronology trigger locks the shipment and reads its latest-scan metadata. It requires an existing booking, the next sequence number, and a timestamp no earlier than the previous scan's. The trigger rejects backward status changes and any scan after delivery. The first scan must be RECEIVED, and later movement statuses require the shipment to have reached IN_TRANSIT. Forward skips, such as IN_TRANSIT directly to OUT_FOR_DELIVERY, are allowed to accommodate the supplied sample histories.

After each scan insert, the maintain_shipment_status trigger updates current_status and the latest-scan fields. For a delivered scan, it sets on_time by checking whether DATE(scan_ts) falls on or before promised_date. A delivery at any time on the promised day therefore counts as on time. Undelivered shipments keep on_time NULL and are excluded from on-time and late delivery counts. Both triggers run within the scan insert's transaction. Storing the latest-scan metadata on the parent shipment row allows a current locking read without attempting to lock scan_event from inside its own insert trigger.

These triggers cover scan insertion. The application has no route for updating or deleting existing scans. Direct SQL changes to scan history or the cached shipment fields would need additional safeguards to preserve their agreement.

Seven more triggers protect vehicle specialization. Each of the three subtype tables has an insert trigger and an update trigger that lock the parent vehicle and check its type. Subtype updates can't change vehicle_id. The seventh trigger, enforce_vehicle_type, prevents changes to the parent's type. Together they enforce disjoint membership without storing vehicle_type in the subtypes. Total participation still relies on the application transaction that creates both rows.

## 6 Constraints enforced in application code

### Session identity and access control

The professor requires roles and passwords at the application level. Flask checks the stored password hash, confirms that the selected role matches the account, and stores the account identity in a signed session. Shippers' protected operations are limited to their own shipments. Carriers' protected operations are limited to their own vehicles and the departures those vehicles operate. Viewers have read-only routes. The six numbered queries are also available without signing in and return results across accounts.

The application checks that the departure chosen for a scan is the one the shipment is booked on. Database connections are opened as needed for each Flask request and closed at teardown. These connections use the same configured database account, so table constraints can't identify the browser user from the database login alone. The application resolves the session identity and checks authorization before carrying out protected operations.

### Other application checks and transaction boundaries

Vehicle and subtype rows are inserted in one transaction. For vehicles created through the application, this supplies total subtype participation, which the foreign keys alone can't require in the parent-to-child direction. A shipment's lane, weight, and promised date can be edited only while it is unbooked and has no scans, after locking the shipment row. Editing a departure locks it, recomputes its load, rejects a capacity below that load, and keeps the lane fixed once bookings exist. We chose to put these rules in application-managed transactions. They could also be implemented as database routines.

The application validates input formats and numeric ranges and returns readable error messages. Scan hubs must exist, but the schema doesn't define intermediate stops or which hubs are valid for a given status, so geographic plausibility isn't checked. Each scan belongs to one shipment, even when several shipments share a departure.

<!-- page -->

## Appendix A Candidate keys and normalization

The table covers the implemented relations. Readable codes are unique and required where present. The normalization assessments use the domain dependencies from Section 2 and account for the derived shipment state discussed in Section 3.

| Relation | Candidate keys | Normalization assessment |
| --- | --- | --- |
| user_account | user_id or username | BCNF under the stated account dependencies. |
| hub | hub_id or hub_code | BCNF. Descriptive attributes depend on either key. |
| lane | lane_id or (origin_hub_id, dest_hub_id) | BCNF. The ordered hub pair identifies the lane. |
| vehicle | vehicle_id or vehicle_code | BCNF. Each key determines owner, home hub, and type. |
| box_truck | vehicle_id | BCNF. The key determines the type-specific attributes. |
| refrigerated_van | vehicle_id | BCNF. The key determines the type-specific attributes. |
| rail_car | vehicle_id | BCNF. The key determines the type-specific attributes. |
| departure | departure_id or departure_code | BCNF. Carrier is obtained through vehicle. |
| shipment | shipment_id or shipment_code | Core shipment facts satisfy BCNF. The stored relation is deliberately denormalized with derived movement state. |
| booking | shipment_id | BCNF. The key determines departure_id and booked_at. |
| scan_event | (shipment_id, seq_no) | BCNF under the stated scan dependencies. |

The ten relations other than shipment satisfy BCNF under the stated dependencies and therefore meet the 3NF minimum. The core shipment facts also satisfy BCNF, but the full stored shipment relation needs the qualification described in Section 3. Lane compatibility between a shipment and its departure is enforced by the booking procedure.

### Sample data and analytical queries

The seed script maps the professor's labels to internal keys and loads 11 hubs, 8 accounts, 7 vehicles, 5 lanes, 10 departures, 23 shipments, 22 bookings, and 69 scans. It makes a few assumptions: demo passwords, city names taken from hub names, and booking timestamps set one hour before each booked shipment's first scan. At load time, 9 shipments are on time, 5 are late, and 9 are pending. The six numbered queries use SQL aggregation, RANK, LAG, and cumulative SUM as appropriate. Python executes parameterized SQL through PyMySQL, and the View Queries pages execute statements read from sql/03_queries.sql.

### Implementation verification

We tested a fresh installation from the submitted SQL scripts on a local MariaDB instance, along with competing capacity requests, subtype guards, scan validation, and the application pages and reports affected by these changes. Setup for the final submission uses the three numbered SQL files.

The implementation is in sql/01_schema.sql, sql/02_sample_data.sql, sql/03_queries.sql, app.py, db.py, and store.py. The report folder currently contains an earlier diagram, report/DDL Project.drawio.xml. It still places booking time in Shipment and doesn't show the separate booking table, so it needs updating to match the implemented schema. Terminology and team identification follow the project handouts and the Deliverable 1 report.
