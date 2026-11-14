# Freight Desk

A simple Flask UI and Python backend for the CSC 540 logistics project.

The app uses PyMySQL connections and cursors to execute SQL against MariaDB 10.5.
Records persist in the database across Flask restarts.

## Run on Windows

Use Python 3.10 or newer. Open a terminal in this folder and run:

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe -m flask --app app check-db
.venv\Scripts\python.exe app.py
```

Open http://127.0.0.1:5000 in a browser. Stop with Ctrl+C.

On macOS/Linux, use `.venv/bin/python` instead of `.venv\Scripts\python.exe`.

## Database configuration

Before running check-db or starting the app, enter your MariaDB password in the
local `.env` file. For a new checkout, copy `.env.example` to `.env` first.

```dotenv
DB_HOST=classdb2.csc.ncsu.edu
DB_PORT=3306
DB_NAME=mspate22
DB_USER=mspate22
DB_PASSWORD='your_database_password'
SECRET_KEY='your_own_random_session_secret'
```

The default database username assumes your Unity ID is mspate22. Change DB_USER
if your assigned database account is different. DB_PASSWORD is the MariaDB account
password. Application accounts below use their own passwords from user_account.
The local .env file is ignored by Git. Keep it out of submissions and shared archives.
Environment variables override .env settings. Restart Flask after editing them.
SECRET_KEY is optional; without it, login sessions expire when Flask restarts.

Connect your laptop to campus Wi-Fi or the NC State VPN. Flask runs on your laptop
and connects directly to the database server. An SSH session on EOS does not give
your local Flask process network access to that server.

The selected database must already contain the objects and data from these files:

1. sql/01_schema.sql — schema, constraints, booking procedure, scan triggers, views.
2. sql/02_sample_data.sql — the professor's supplied data and seed checks.
3. sql/03_queries.sql — the six required analytical queries.

These are installation scripts for empty project tables. After initial loading,
use check-db to verify the connection and required objects. It does not reload data.
The current integration expects the integer IDs and separate unique code columns
in 01_schema.sql. Forms display codes such as S14 while SQL relationships use IDs.

## Sample accounts

All accounts use password `demo123`.

| Role | User IDs |
| --- | --- |
| Shipper | SH1, SH2, SH3, SH4 |
| Carrier | C1, C2, C3 |
| Viewer | VW1 |

Select the corresponding role before signing in. View Queries is also accessible from Home.

## Current behavior

The seed SQL loads the supplied sample dataset: 11 hubs,
8 accounts, 7 vehicles, 10 departures, 23 shipments, and 69 scans.
The application reads and writes those records in MariaDB. The JSON file is a
reference copy of the professor's sample data and is not loaded by the backend.

Shippers can create/edit unbooked shipments without scans, book matching departures,
track their freight, and run their reports. Carrier screens provide vehicle subtype
forms, departure management, scan posting, and operational reports. Viewers have
read-only tracking and seven published reports. All six numbered queries are available.
Role and record ownership checks run on the server.

Try SH1 / S14 for booking, C1 / D7 for a full departure, S3 for delivery on the
promised date, S2 for a late delivery, and S4 for an unfinished scan history.

Report conventions:

- Delivery summaries filter by delivery scan date and exclude undelivered shipments.
- Departure reports and lane-volume reports filter by scheduled departure date.
- Lane volume is total shipment weight in kilograms.
- Running totals group deliveries into Monday-starting weeks, within the selected
  date range. Query 4 measures kilograms. The viewer running report counts shipments.
- Query 2 ranks utilization percentages. The viewer top-departures report ranks
  booked kilograms. Ties share competition rank and can return more than N rows.
- Near-promise reports include all undelivered shipments, using the server's current date.
- Date filters initially cover 2026 so the professor's historical sample is visible.
- Vehicle type stays fixed when editing. Booked shipment edits and booked departure
  lane changes are restricted to preserve consistency.

## Database operations

db.py creates one connection per Flask request and closes it at teardown.
Autocommit reads leave the connection ready for the booking procedure, which owns
its transaction. Other writes explicitly begin, commit, or roll back a transaction.

store.py contains parameterized SQL and explicit ownership filters. Bookings call
book_shipment. Scan insertion is authorized and sequenced under row locks, then
the database triggers validate chronology and maintain delivery state. Vehicle
and subtype inserts commit together. Departure capacity edits lock the departure
and recheck its booked load before updating it.

The View Queries screens execute the six SELECT statements read directly from
sql/03_queries.sql, with values bound through the driver. Additional role reports
also use SQL, including window functions for rankings and cumulative totals.
Use Python Decimal for weights and capacities throughout writes.

## Connection troubleshooting

- Missing password: fill DB_PASSWORD in .env and restart Flask.
- Cannot reach server: check the VPN and DB_HOST/DB_PORT.
- Login rejected: check DB_USER and the MariaDB password.
- Missing table, column, procedure or view: compare the installed schema with
  sql/01_schema.sql, including the code and latest-scan columns.
