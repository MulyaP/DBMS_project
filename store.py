"""Database queries and updates for Freight Desk."""

import re
import secrets
from pathlib import Path

from db import get_db, transaction

STATUSES = ['RECEIVED', 'IN_TRANSIT', 'ARRIVED_AT_HUB', 'OUT_FOR_DELIVERY', 'DELIVERED']
TYPES = ['Box truck', 'Refrigerated van', 'Rail car']
VEHICLE_TYPES = dict(zip(TYPES, ['BOX_TRUCK', 'REFRIGERATED_VAN', 'RAIL_CAR']))
SUBTYPES = {
    'Box truck': (
        'box_truck',
        ['cargo_volume_m3', 'gross_weight_rating_kg'],
        ['cargo_volume', 'gross_weight'],
    ),
    'Refrigerated van': (
        'refrigerated_van',
        ['temp_min_c', 'temp_max_c', 'payload_limit_kg'],
        ['temp_min', 'temp_max', 'payload'],
    ),
    'Rail car': ('rail_car', ['axle_count', 'track_gauge_mm'], ['axles', 'gauge']),
}

# Load the six submitted queries and bind their variables through PyMySQL.
query_file = Path(__file__).with_name('sql').joinpath('03_queries.sql').read_text(encoding='utf-8')
NUMBERED_QUERIES = []
for section in re.split(r'^-- [1-6]\. ', query_file, flags=re.MULTILINE)[1:]:
    statement = '\n'.join(section.splitlines()[1:])
    statement = re.sub(r'--[^\n]*', '', statement).strip().rstrip(';')
    for name in ['start_date', 'end_date', 'top_n', 'shipment_code', 'carrier_code']:
        statement = statement.replace('@' + name, '%(' + name + ')s')
    NUMBERED_QUERIES.append(statement)


# SQL helpers


def fetch_all(sql, args=()):
    with get_db().cursor() as cursor:
        cursor.execute(sql, args)
        return cursor.fetchall()


def fetch_one(sql, args=()):
    rows = fetch_all(sql, args)
    return rows[0] if rows else None


def result_table(sql, args=()):
    with get_db().cursor() as cursor:
        cursor.execute(sql, args)
        headers = [column[0].replace('_', ' ').title() for column in cursor.description]
        return headers, [list(row.values()) for row in cursor.fetchall()]


def scope(user, shipper_column='s.shipper_id', carrier_column='v.carrier_id'):
    if user and user['role'] == 'shipper':
        return shipper_column + ' = %s', [user['db_id']]
    if user and user['role'] == 'carrier':
        return carrier_column + ' = %s', [user['db_id']]
    return '1 = 1', []


# Shared SELECT statements

SHIPMENT_SELECT = """
    SELECT s.shipment_id AS db_id, s.shipment_code AS id,
           u.username AS shipper, s.shipper_id AS owner_id, s.lane_id,
           o.hub_code AS origin, dest.hub_code AS destination,
           d.departure_code AS departure, s.departure_id,
           s.weight_kg AS weight, s.promised_date AS promised,
           s.current_status AS status, s.on_time, s.last_scan_seq AS scans
      FROM shipment s
      JOIN user_account u ON u.user_id = s.shipper_id
      JOIN lane l ON l.lane_id = s.lane_id
      JOIN hub o ON o.hub_id = l.origin_hub_id
      JOIN hub dest ON dest.hub_id = l.dest_hub_id
      LEFT JOIN departure d ON d.departure_id = s.departure_id
      LEFT JOIN vehicle v ON v.vehicle_id = d.vehicle_id
"""

VEHICLE_SELECT = """
    SELECT v.vehicle_id AS db_id, v.vehicle_code AS id, u.username AS carrier,
           v.carrier_id AS owner_id, h.hub_code AS hub,
           CASE v.vehicle_type
               WHEN 'BOX_TRUCK' THEN 'Box truck'
               WHEN 'REFRIGERATED_VAN' THEN 'Refrigerated van'
               ELSE 'Rail car'
           END AS type,
           bt.cargo_volume_m3 AS cargo_volume, bt.gross_weight_rating_kg AS gross_weight,
           rv.temp_min_c AS temp_min, rv.temp_max_c AS temp_max, rv.payload_limit_kg AS payload,
           rc.axle_count AS axles, rc.track_gauge_mm AS gauge
      FROM vehicle v
      JOIN user_account u ON u.user_id = v.carrier_id
      JOIN hub h ON h.hub_id = v.home_hub_id
      LEFT JOIN box_truck bt ON bt.vehicle_id = v.vehicle_id
      LEFT JOIN refrigerated_van rv ON rv.vehicle_id = v.vehicle_id
      LEFT JOIN rail_car rc ON rc.vehicle_id = v.vehicle_id
"""

DEPARTURE_SELECT = """
    SELECT d.departure_id AS db_id, d.departure_code AS id,
           v.vehicle_code AS vehicle, v.carrier_id AS owner_id,
           u.username AS carrier, o.hub_code AS origin, dest.hub_code AS destination,
           d.depart_at AS time, d.max_weight_kg AS capacity,
           dl.booked_weight_kg AS booked, dl.remaining_weight_kg AS remaining
      FROM departure d
      JOIN vehicle v ON v.vehicle_id = d.vehicle_id
      JOIN user_account u ON u.user_id = v.carrier_id
      JOIN lane l ON l.lane_id = d.lane_id
      JOIN hub o ON o.hub_id = l.origin_hub_id
      JOIN hub dest ON dest.hub_id = l.dest_hub_id
      JOIN v_departure_load dl ON dl.departure_id = d.departure_id
"""


class SQLStore:

    # Accounts and hubs

    def account(self, username):
        return fetch_one(
            """
            SELECT user_id AS db_id, username AS id, display_name AS name,
                   LOWER(role) AS role, password
              FROM user_account WHERE username = %s
        """,
            (username,),
        )

    def accounts(self):
        return fetch_all("""
            SELECT username AS id, display_name AS name, LOWER(role) AS role
              FROM user_account ORDER BY user_id
        """)

    def hubs(self):
        return fetch_all('SELECT hub_code AS id, hub_name AS name FROM hub ORDER BY hub_id')

    # Shipment lookup and tracking

    def shipments(self, user=None):
        condition, args = scope(user)
        return fetch_all(SHIPMENT_SELECT + ' WHERE ' + condition + ' ORDER BY s.shipment_id', args)

    def shipment(self, code, user=None):
        condition, args = scope(user)
        return fetch_one(
            SHIPMENT_SELECT + ' WHERE s.shipment_code = %s AND ' + condition, [code] + args
        )

    @staticmethod
    def status(shipment):
        return shipment['status']

    @staticmethod
    def outcome(shipment):
        if shipment['on_time'] is None:
            return 'Pending'
        return 'On time' if shipment['on_time'] else 'Late'

    def elapsed(self, shipment):
        _, rows = self.numbered_query(3, {'shipment_code': shipment['id']})
        return [
            [r[1], r[2], r[3].replace('_', ' ').title(), r[5], r[7] if r[7] is not None else '—']
            for r in rows
        ]

    # Lanes

    def lane_id(self, origin, destination):
        if origin == destination:
            raise ValueError('Choose two different hubs.')
        hubs = fetch_all(
            'SELECT hub_id, hub_code FROM hub WHERE hub_code IN (%s, %s)', (origin, destination)
        )
        ids = {h['hub_code']: h['hub_id'] for h in hubs}
        if len(ids) != 2:
            raise ValueError('Choose two valid hubs.')
        with get_db().cursor() as cursor:
            # LAST_INSERT_ID also returns the ID of an existing lane.
            cursor.execute(
                """
                INSERT INTO lane (origin_hub_id, dest_hub_id) VALUES (%s, %s)
                ON DUPLICATE KEY UPDATE lane_id = LAST_INSERT_ID(lane_id)
            """,
                (ids[origin], ids[destination]),
            )
            return cursor.lastrowid

    # Shipper operations

    def save_shipment(self, code, user, values):
        with transaction() as connection:
            with connection.cursor() as cursor:
                row = None
                if code:
                    cursor.execute(
                        'SELECT * FROM shipment WHERE shipment_code = %s FOR UPDATE', (code,)
                    )
                    row = cursor.fetchone()
                    if not row or row['shipper_id'] != user['db_id']:
                        raise ValueError('Shipment not found or outside your account scope.')
                    if row['departure_id'] is not None or row['last_scan_seq']:
                        raise ValueError('Only unbooked shipments with no scans can be edited.')
                lane_id = self.lane_id(values['origin'], values['destination'])
                args = (lane_id, values['weight'], values['promised'])
                if row:
                    cursor.execute(
                        'UPDATE shipment SET lane_id=%s, weight_kg=%s, promised_date=%s WHERE shipment_id=%s',
                        args + (row['shipment_id'],),
                    )
                else:
                    # Replace the temporary code before the transaction commits.
                    cursor.execute(
                        """
                        INSERT INTO shipment (lane_id, weight_kg, promised_date, shipper_id, shipment_code)
                        VALUES (%s, %s, %s, %s, %s)
                    """,
                        args + (user['db_id'], 'pending_' + secrets.token_hex(16)),
                    )
                    ident = cursor.lastrowid
                    code = f'S{ident}'
                    cursor.execute(
                        'UPDATE shipment SET shipment_code=%s WHERE shipment_id=%s', (code, ident)
                    )
        return code

    def eligible_departures(self, shipment):
        return fetch_all(
            DEPARTURE_SELECT + """
            WHERE d.lane_id = %s AND dl.remaining_weight_kg >= %s
            ORDER BY d.depart_at, d.departure_id
        """,
            (shipment['lane_id'], shipment['weight']),
        )

    def book(self, shipment, departure_code, user):
        departure = self.departure(departure_code)
        if not departure:
            raise ValueError('Select a valid departure.')
        # The procedure starts its own transaction after the autocommit reads.
        with get_db().cursor() as cursor:
            cursor.callproc('book_shipment', (shipment['db_id'], departure['db_id'], user['db_id']))
            # Drain every result set returned by the procedure.
            while cursor.nextset():
                pass

    # Carrier vehicles

    def vehicles(self, user):
        return fetch_all(
            VEHICLE_SELECT + ' WHERE v.carrier_id = %s ORDER BY v.vehicle_id', (user['db_id'],)
        )

    def vehicle(self, code):
        return fetch_one(VEHICLE_SELECT + ' WHERE v.vehicle_code = %s', (code,))

    def save_vehicle(self, code, user, kind, values):
        with transaction() as connection:
            with connection.cursor() as cursor:
                hub = fetch_one('SELECT hub_id FROM hub WHERE hub_code=%s', (values['hub'],))
                if not hub:
                    raise ValueError('Choose a valid home hub.')
                existing = None
                if code:
                    cursor.execute(
                        'SELECT * FROM vehicle WHERE vehicle_code=%s FOR UPDATE', (code,)
                    )
                    existing = cursor.fetchone()
                    if not existing or existing['carrier_id'] != user['db_id']:
                        raise ValueError('Vehicle not found or outside your account scope.')
                    if existing['vehicle_type'] != VEHICLE_TYPES[kind]:
                        raise ValueError('Vehicle type cannot be changed.')
                    ident = existing['vehicle_id']
                    cursor.execute(
                        'UPDATE vehicle SET home_hub_id=%s WHERE vehicle_id=%s',
                        (hub['hub_id'], ident),
                    )
                else:
                    code = values['id']
                    cursor.execute(
                        """
                        INSERT INTO vehicle (vehicle_code, carrier_id, home_hub_id, vehicle_type)
                        VALUES (%s, %s, %s, %s)
                    """,
                        (code, user['db_id'], hub['hub_id'], VEHICLE_TYPES[kind]),
                    )
                    ident = cursor.lastrowid
                # Identifiers come exclusively from the fixed map in this module.
                table, columns, keys = SUBTYPES[kind]
                args = [values[key] for key in keys]
                if existing:
                    assignments = ', '.join(column + '=%s' for column in columns)
                    cursor.execute(
                        f'UPDATE {table} SET {assignments} WHERE vehicle_id=%s', args + [ident]
                    )
                    if not fetch_one(
                        f'SELECT vehicle_id FROM {table} WHERE vehicle_id=%s', (ident,)
                    ):
                        raise ValueError(
                            'Vehicle subtype details are missing. Ask the team to repair this record.'
                        )
                else:
                    placeholders = ', '.join(['%s'] * (len(columns) + 1))
                    cursor.execute(
                        f"INSERT INTO {table} (vehicle_id, {', '.join(columns)}) VALUES ({placeholders})",
                        [ident] + args,
                    )
        return code

    # Carrier departures and scans

    def departures(self, user=None):
        condition, args = scope(user)
        return fetch_all(
            DEPARTURE_SELECT + ' WHERE ' + condition + ' ORDER BY d.departure_id', args
        )

    def departure(self, code):
        return fetch_one(DEPARTURE_SELECT + ' WHERE d.departure_code = %s', (code,))

    def save_departure(self, code, user, values):
        with transaction() as connection:
            with connection.cursor() as cursor:
                row = None
                if code:
                    cursor.execute(
                        'SELECT * FROM departure WHERE departure_code=%s FOR UPDATE', (code,)
                    )
                    row = cursor.fetchone()
                    if not row:
                        raise ValueError('Departure not found.')
                    owner = fetch_one(
                        'SELECT carrier_id FROM vehicle WHERE vehicle_id=%s', (row['vehicle_id'],)
                    )
                    if owner['carrier_id'] != user['db_id']:
                        raise ValueError('Departure is outside your account scope.')
                vehicle = fetch_one(
                    'SELECT vehicle_id FROM vehicle WHERE vehicle_code=%s AND carrier_id=%s',
                    (values['vehicle'], user['db_id']),
                )
                if not vehicle:
                    raise ValueError('Select one of your vehicles.')
                lane_id = self.lane_id(values['origin'], values['destination'])
                if row:
                    cursor.execute(
                        (
                            'SELECT COUNT(*) AS count, COALESCE(SUM(weight_kg),0) AS load_kg FROM shipment WHERE '
                            'departure_id=%s FOR UPDATE'
                        ),
                        (row['departure_id'],),
                    )
                    load = cursor.fetchone()
                    if values['capacity'] < load['load_kg']:
                        raise ValueError('Capacity cannot be lower than the booked load.')
                    if load['count'] and row['lane_id'] != lane_id:
                        raise ValueError('A departure with bookings must keep its current lane.')
                args = (vehicle['vehicle_id'], lane_id, values['time'], values['capacity'])
                if row:
                    cursor.execute(
                        'UPDATE departure SET vehicle_id=%s, lane_id=%s, depart_at=%s, max_weight_kg=%s WHERE departure_id=%s',
                        args + (row['departure_id'],),
                    )
                else:
                    cursor.execute(
                        'INSERT INTO departure (vehicle_id,lane_id,depart_at,max_weight_kg,departure_code) VALUES (%s,%s,%s,%s,%s)',
                        args + ('pending_' + secrets.token_hex(16),),
                    )
                    ident = cursor.lastrowid
                    code = f'D{ident}'
                    cursor.execute(
                        'UPDATE departure SET departure_code=%s WHERE departure_id=%s',
                        (code, ident),
                    )
        return code

    def post_scan(self, user, values):
        with transaction() as connection:
            with connection.cursor() as cursor:
                # Lock departure before shipment, matching the booking procedure.
                cursor.execute(
                    """
                    SELECT d.departure_id FROM departure d
                    JOIN vehicle v ON v.vehicle_id=d.vehicle_id
                    WHERE d.departure_code=%s AND v.carrier_id=%s FOR UPDATE
                """,
                    (values['departure'], user['db_id']),
                )
                departure = cursor.fetchone()
                if not departure:
                    raise ValueError('Select a departure operated by your carrier.')
                cursor.execute(
                    'SELECT shipment_id, departure_id, last_scan_seq FROM shipment WHERE shipment_code=%s FOR UPDATE',
                    (values['shipment'],),
                )
                shipment = cursor.fetchone()
                if not shipment or shipment['departure_id'] != departure['departure_id']:
                    raise ValueError(
                        'Select a shipment booked onto the specified departure you operate.'
                    )
                hub = fetch_one('SELECT hub_id FROM hub WHERE hub_code=%s', (values['hub'],))
                if not hub or values['status'] not in STATUSES:
                    raise ValueError('Choose a valid scan hub and status.')
                cursor.execute(
                    """
                    INSERT INTO scan_event (shipment_id,seq_no,scan_ts,hub_id,status)
                    VALUES (%s,%s,%s,%s,%s)
                """,
                    (
                        shipment['shipment_id'],
                        shipment['last_scan_seq'] + 1,
                        values['time'],
                        hub['hub_id'],
                        values['status'],
                    ),
                )

    # Reports and queries

    def numbered_query(self, index, params):
        return result_table(NUMBERED_QUERIES[index - 1], params)

    def report(self, kind, params, user=None):
        if user is None and kind in ['utilization', 'dwell', 'weight', 'multi', 'noscan']:
            if kind == 'dwell' and not self.shipment(params['shipment_code']):
                raise ValueError('Shipment not found.')
            return self.numbered_query(
                {'utilization': 2, 'dwell': 3, 'weight': 4, 'multi': 5, 'noscan': 6}[kind], params
            )
        condition, args = scope(user)
        if kind == 'dwell':
            if not self.shipment(params['shipment_code'], user):
                raise ValueError('Enter a shipment ID within your account scope.')
            return self.numbered_query(3, params)
        if kind in ['transit', 'risk']:
            extra = ''
            if kind == 'risk':
                extra = ' AND s.promised_date <= %s'
                args.append(params['risk_date'])
            return result_table(
                """
                SELECT s.shipment_code AS shipment, u.username AS shipper,
                       o.hub_code AS origin, dest.hub_code AS destination,
                       s.promised_date, s.current_status
                  FROM shipment s
                  JOIN user_account u ON u.user_id=s.shipper_id
                  JOIN lane l ON l.lane_id=s.lane_id
                  JOIN hub o ON o.hub_id=l.origin_hub_id
                  JOIN hub dest ON dest.hub_id=l.dest_hub_id
                  LEFT JOIN departure d ON d.departure_id=s.departure_id
                  LEFT JOIN vehicle v ON v.vehicle_id=d.vehicle_id
                 WHERE """
                + condition
                + " AND s.current_status <> 'DELIVERED'"
                + extra
                + ' ORDER BY s.shipment_id',
                args,
            )
        if kind in ['load', 'top']:
            if user and user['role'] == 'carrier':
                condition, args = 'v.carrier_id=%s', [user['db_id']]
            else:
                condition, args = '1=1', []
            args += [params['start_date'], params['end_date']]
            limit = ''
            if kind == 'top':
                limit = 'WHERE load_rank <= %s'
                args.append(params['top_n'])
            return result_table(
                """
                WITH loads AS (
                    SELECT o.hub_code AS origin, dest.hub_code AS destination,
                           dl.departure_code AS departure, dl.depart_at,
                           dl.max_weight_kg AS capacity_kg, dl.booked_weight_kg,
                           dl.remaining_weight_kg, ROUND(dl.utilization_pct,2) AS utilization_pct,
                           RANK() OVER (PARTITION BY dl.lane_id ORDER BY dl.booked_weight_kg DESC) AS load_rank
                      FROM v_departure_load dl
                      JOIN vehicle v ON v.vehicle_id=dl.vehicle_id
                      JOIN lane l ON l.lane_id=dl.lane_id
                      JOIN hub o ON o.hub_id=l.origin_hub_id
                      JOIN hub dest ON dest.hub_id=l.dest_hub_id
                     WHERE """
                + condition
                + """ AND dl.depart_at >= %s
                       AND dl.depart_at < DATE_ADD(%s, INTERVAL 1 DAY)
                ) SELECT * FROM loads """
                + limit
                + ' ORDER BY origin,destination,load_rank,departure',
                args,
            )
        if kind == 'volume':
            return result_table(
                """
                SELECT RANK() OVER (ORDER BY SUM(s.weight_kg) DESC) AS volume_rank,
                       o.hub_code AS origin, dest.hub_code AS destination,
                       SUM(s.weight_kg) AS shipment_kg
                  FROM shipment s
                  JOIN departure d ON d.departure_id=s.departure_id
                  JOIN lane l ON l.lane_id=s.lane_id
                  JOIN hub o ON o.hub_id=l.origin_hub_id
                  JOIN hub dest ON dest.hub_id=l.dest_hub_id
                 WHERE d.depart_at >= %s AND d.depart_at < DATE_ADD(%s, INTERVAL 1 DAY)
                 GROUP BY l.lane_id,o.hub_code,dest.hub_code
                 ORDER BY volume_rank,origin,destination
            """,
                (params['start_date'], params['end_date']),
            )
        if kind == 'running':
            return result_table(
                """
                WITH weekly AS (
                    SELECT ds.carrier_id,
                           DATE_SUB(DATE(ds.delivered_at),INTERVAL WEEKDAY(ds.delivered_at) DAY) AS week_start,
                           COUNT(*) AS delivered_shipments
                      FROM v_delivered_shipment ds
                      JOIN user_account c ON c.user_id=ds.carrier_id
                     WHERE ds.delivered_at >= %s AND ds.delivered_at < DATE_ADD(%s,INTERVAL 1 DAY)
                       AND (%s IS NULL OR c.username=%s)
                     GROUP BY ds.carrier_id,week_start
                ) SELECT c.username AS carrier,w.week_start,w.delivered_shipments,
                         SUM(w.delivered_shipments) OVER (
                             PARTITION BY w.carrier_id ORDER BY w.week_start
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
                         ) AS cumulative_shipments
                    FROM weekly w JOIN user_account c ON c.user_id=w.carrier_id
                   ORDER BY c.username,w.week_start
            """,
                (
                    params['start_date'],
                    params['end_date'],
                    params['carrier_code'],
                    params['carrier_code'],
                ),
            )
        if kind in ['summary', 'lane', 'carrier']:
            condition, args = scope(user, 'ds.shipper_id', 'ds.carrier_id')
            group = "'All delivered shipments'"
            grouping = ''
            if kind == 'lane':
                group = "CONCAT(o.hub_code,' → ',dest.hub_code)"
                grouping = 'GROUP BY ds.lane_id,o.hub_code,dest.hub_code'
            if kind == 'carrier':
                group = 'c.username'
                grouping = 'GROUP BY ds.carrier_id,c.username'
            return result_table(
                """
                SELECT """
                + group
                + """ AS report_group, COUNT(*) AS delivered,
                       COALESCE(SUM(ds.on_time=1),0) AS on_time,
                       COALESCE(SUM(ds.on_time=0),0) AS late,
                       ROUND(100.0*SUM(ds.on_time=1)/NULLIF(COUNT(*),0),2) AS on_time_pct,
                       ROUND(100.0*SUM(ds.on_time=0)/NULLIF(COUNT(*),0),2) AS late_pct
                  FROM v_delivered_shipment ds
                  JOIN user_account c ON c.user_id=ds.carrier_id
                  JOIN lane l ON l.lane_id=ds.lane_id
                  JOIN hub o ON o.hub_id=l.origin_hub_id
                  JOIN hub dest ON dest.hub_id=l.dest_hub_id
                 WHERE """
                + condition
                + """ AND ds.delivered_at >= %s
                   AND ds.delivered_at < DATE_ADD(%s,INTERVAL 1 DAY)
                """
                + grouping
                + ' ORDER BY on_time_pct DESC,report_group',
                args + [params['start_date'], params['end_date']],
            )
        raise ValueError('Unknown report.')
