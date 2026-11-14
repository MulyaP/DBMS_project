"""Flask freight management application backed by MariaDB."""

import os
import secrets
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from functools import wraps
from pathlib import Path

import click
import pymysql
from dotenv import load_dotenv
from flask import Flask, abort, flash, g, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash

from db import DatabaseConfigurationError, close_db, get_db
from store import SQLStore, STATUSES, TYPES

load_dotenv(Path(__file__).with_name('.env'))
app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY') or secrets.token_hex(32)
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE='Lax',
    MAX_CONTENT_LENGTH=64 * 1024,
    DB_HOST=os.environ.get('DB_HOST', 'classdb2.csc.ncsu.edu'),
    DB_PORT=int(os.environ.get('DB_PORT', '3306')),
    DB_NAME=os.environ.get('DB_NAME', 'mspate22'),
    DB_USER=os.environ.get('DB_USER', 'mspate22'),
    DB_PASSWORD=os.environ.get('DB_PASSWORD', ''),
)
app.teardown_appcontext(close_db)
store = SQLStore()

QUERIES = [
    ('Vehicles by carrier and type', 'Count each vehicle type owned by each carrier.'),
    (
        'Departure utilization ranking',
        'Rank departures within each lane by percentage of capacity used.',
    ),
    ('Shipment dwell time', 'Measure elapsed hours between consecutive scan events.'),
    ('Running delivered weight', 'Cumulative delivered kilograms by carrier and week.'),
    (
        'Departures with multiple shippers',
        'Find departures carrying freight from at least two shippers.',
    ),
    ('Shipments without scans', 'List shipments with no movement history recorded.'),
]
REPORTS = {
    'shipper': [
        ('summary', 'On-time vs. late'),
        ('transit', 'In-transit shipments'),
        ('risk', 'Near promise date'),
    ],
    'carrier': [
        ('load', 'Load per departure'),
        ('summary', 'On-time delivery rate'),
        ('dwell', 'Shipment dwell time'),
    ],
    'viewer': [
        ('lane', 'On-time rates by lane'),
        ('carrier', 'On-time rates by carrier'),
        ('volume', 'Lane volume ranking'),
        ('top', 'Top departures per lane'),
        ('dwell', 'Shipment dwell time'),
        ('running', 'Running deliveries by carrier'),
        ('risk', 'At-risk shipments'),
    ],
}


# Session and access helpers


def current_user():
    if g.get('db_unavailable'):
        return None
    if 'user' not in g:
        username = session.get('user_id')
        g.user = store.account(username) if username else None
    return g.user


@app.context_processor
def context():
    session.setdefault('csrf', secrets.token_hex(24))
    return dict(
        user=current_user(),
        csrf=session['csrf'],
        queries=QUERIES,
        reports=REPORTS,
        today=date.today().isoformat(),
        db_ready=not g.get('db_unavailable', False),
    )


@app.before_request
def protect_forms():
    if request.method == 'POST' and not secrets.compare_digest(
        request.form.get('csrf', ''), session.get('csrf', secrets.token_hex(24))
    ):
        abort(400, 'Your form expired. Reload the page and try again.')


def require_role(*roles):
    def decorator(function):
        @wraps(function)
        def wrapped(*args, **kwargs):
            user = current_user()
            if not user:
                return redirect(url_for('home'))
            if roles and user['role'] not in roles:
                abort(403)
            return function(*args, **kwargs)

        return wrapped

    return decorator


def scoped_shipments():
    return store.shipments(current_user())


def owned(row, owner):
    if not row:
        abort(404)
    if row[owner] != current_user()['id']:
        abort(403)
    return row


# Input and page helpers


def number(name, positive=True):
    try:
        value = Decimal(request.form.get(name, ''))
        if not value.is_finite() or (positive and value <= 0):
            raise ValueError('Amounts must be finite and greater than zero.')
        value = value.quantize(Decimal('0.01'))
        if positive and value < Decimal('0.01'):
            raise ValueError('Amounts must be at least 0.01.')
        return value
    except InvalidOperation:
        raise ValueError('Enter valid numeric values within the supported range.')


def lane():
    origin = request.form.get('origin', '')
    destination = request.form.get('destination', '')
    if not origin or not destination or origin == destination:
        raise ValueError('Choose two different, valid hubs.')
    return dict(origin=origin, destination=destination)


def form_error(error):
    if isinstance(error, ValueError):
        flash(str(error), 'error')
        return
    code = error.args[0]
    messages = {
        1062: 'This identifier is already in use. Choose another and try again.',
        1205: 'Another operation is using this record. Please try again.',
        1213: 'Another operation competed for this record. Please try again.',
        1264: 'A numeric value is outside the supported range.',
        1406: 'A value is longer than the allowed field length.',
        1452: 'A referenced record no longer exists. Reload the form and try again.',
        4025: 'These values violate a database constraint. Check your input.',
    }
    if code == 1644:
        flash(error.args[1], 'error')
    elif code in messages:
        flash(messages[code], 'error')
    else:
        raise error


def timestamp(value):
    stamp = datetime.fromisoformat(value)
    if stamp.tzinfo is not None or stamp.year < 1000:
        raise ValueError('Enter a local date and time from year 1000 onward.')
    return stamp


def field(name, label, kind='text', options=None, value='', required=True):
    return dict(name=name, label=label, kind=kind, options=options, value=value, required=required)


def form_page(title, fields, back, description='', button='Save'):
    return render_template(
        'form.html', title=title, fields=fields, back=back, description=description, button=button
    )


def table(title, headers, rows, description='', **extra):
    return render_template(
        'table.html', title=title, headers=headers, rows=rows, description=description, **extra
    )


# Home and login


@app.route('/')
def home():
    return render_template('home.html', title='Freight management', accounts=store.accounts())


@app.route('/login/<role>', methods=['GET', 'POST'])
def login(role):
    if role not in REPORTS:
        abort(404)
    if request.method == 'POST':
        user = store.account(request.form.get('user_id', '').strip().upper())
        if (
            user
            and user['role'] == role
            and check_password_hash(user['password'], request.form.get('password', ''))
        ):
            session.clear()
            session['user_id'] = user['id']
            return redirect(url_for('dashboard'))
        flash('Login incorrect. Check the user ID, password, and selected role.', 'error')
    return form_page(
        f'{role.title()} login',
        [field('user_id', 'User ID'), field('password', 'Password', 'password')],
        url_for('home'),
        button='Sign in',
    )


@app.post('/logout')
def logout():
    session.clear()
    return redirect(url_for('home'))


# Shared shipment pages


@app.route('/dashboard')
@require_role()
def dashboard():
    shipments = scoped_shipments()
    return render_template(
        'dashboard.html',
        title='Overview',
        shipments=shipments,
        status=store.status,
        outcome=store.outcome,
    )


@app.route('/shipments')
@require_role()
def shipments():
    return render_template(
        'shipments.html',
        title='Shipments',
        shipments=scoped_shipments(),
        status=store.status,
        outcome=store.outcome,
    )


@app.route('/track')
@require_role()
def track():
    ident = request.args.get('shipment', '').strip().upper()
    shipment = store.shipment(ident, current_user()) if ident else None
    if ident and not shipment:
        flash('Shipment not found or outside your account scope.', 'error')
    return render_template(
        'track.html',
        title='Track shipment',
        shipment=shipment,
        scans=store.elapsed(shipment) if shipment else [],
        status=store.status,
        outcome=store.outcome,
    )


# Shipper routes


@app.route('/shipment/new', methods=['GET', 'POST'])
@app.route('/shipment/<ident>/edit', methods=['GET', 'POST'])
@require_role('shipper')
def shipment_form(ident=None):
    row = owned(store.shipment(ident), 'shipper') if ident else {}
    if request.method == 'POST':
        try:
            promised = date.fromisoformat(request.form.get('promised', ''))
            if promised.year < 1000:
                raise ValueError('Enter a promised date from year 1000 onward.')
            values = dict(**lane(), weight=number('weight'), promised=promised)
            code = store.save_shipment(ident, current_user(), values)
            flash(f'Shipment {code} saved.', 'success')
            return redirect(url_for('shipments'))
        except (ValueError, pymysql.MySQLError) as error:
            form_error(error)
    options = [(h['id'], f"{h['id']} - {h['name']}") for h in store.hubs()]
    fields = [
        field('origin', 'Origin hub', 'select', options, row.get('origin', '')),
        field('destination', 'Destination hub', 'select', options, row.get('destination', '')),
        field('weight', 'Weight (kg)', 'number', value=row.get('weight', '')),
        field('promised', 'Promised delivery date', 'date', value=row.get('promised', '')),
    ]
    return form_page('Update shipment' if row else 'Create shipment', fields, url_for('shipments'))


@app.route('/shipment/<ident>/book', methods=['GET', 'POST'])
@require_role('shipper')
def book(ident):
    shipment = owned(store.shipment(ident), 'shipper')
    if request.method == 'POST':
        try:
            departure_code = request.form.get('departure', '')
            store.book(shipment, departure_code, current_user())
            flash(f'{ident} booked onto {departure_code}.', 'success')
            return redirect(url_for('shipments'))
        except (ValueError, pymysql.MySQLError) as error:
            form_error(error)
    options = [
        (d['id'], f"{d['id']} - {d['time']} - {d['remaining']:g} kg remaining")
        for d in store.eligible_departures(shipment)
    ]
    return form_page(
        f'Book {ident}',
        [field('departure', 'Eligible departure', 'select', options)],
        url_for('shipments'),
        f"{shipment['origin']} to {shipment['destination']} - {shipment['weight']:g} kg",
        'Book shipment',
    )


# Carrier routes


@app.route('/vehicles')
@require_role('carrier')
def vehicles():
    return render_template(
        'vehicles.html', title='Vehicles', vehicles=store.vehicles(current_user())
    )


@app.route('/vehicle/new', methods=['GET', 'POST'])
@app.route('/vehicle/<ident>/edit', methods=['GET', 'POST'])
@require_role('carrier')
def vehicle_form(ident=None):
    row = owned(store.vehicle(ident), 'carrier') if ident else {}
    kind = row.get('type') or request.values.get('type', TYPES[0])
    if kind not in TYPES:
        abort(400)
    attributes = {
        'Box truck': [
            ('cargo_volume', 'Cargo volume (m³)'),
            ('gross_weight', 'Gross weight rating (kg)'),
        ],
        'Refrigerated van': [
            ('temp_min', 'Minimum temperature (°C)'),
            ('temp_max', 'Maximum temperature (°C)'),
            ('payload', 'Payload limit (kg)'),
        ],
        'Rail car': [('axles', 'Axle count'), ('gauge', 'Track gauge (mm)')],
    }[kind]
    if request.method == 'POST':
        try:
            vehicle_id = ident or request.form.get('id', '').strip().upper()
            if not vehicle_id or len(vehicle_id) > 40:
                raise ValueError('Enter a vehicle ID up to 40 characters.')
            values = {
                key: number(key, positive=not key.startswith('temp')) for key, _ in attributes
            }
            values.update(id=vehicle_id, hub=request.form.get('hub', ''))
            if kind == 'Refrigerated van' and values['temp_min'] >= values['temp_max']:
                raise ValueError('Minimum temperature must be lower than maximum temperature.')
            if kind == 'Rail car' and values['axles'] != values['axles'].to_integral_value():
                raise ValueError('Axle count must be a whole number.')
            store.save_vehicle(ident, current_user(), kind, values)
            flash(f'Vehicle {vehicle_id} saved.', 'success')
            return redirect(url_for('vehicles'))
        except (ValueError, pymysql.MySQLError) as error:
            form_error(error)
    fields = ([] if ident else [field('id', 'Vehicle ID')]) + [
        field(
            'hub',
            'Home hub',
            'select',
            [(h['id'], h['id']) for h in store.hubs()],
            row.get('hub', ''),
        )
    ]
    fields += [field(key, label, 'number', value=row.get(key, '')) for key, label in attributes]
    return form_page(
        f"{'Update' if ident else 'Add'} {kind.lower()}",
        fields,
        url_for('vehicles'),
        'Vehicle type is selected before entering its details.',
    )


@app.route('/departures')
@require_role('carrier')
def departures():
    return render_template(
        'departures.html', title='Departures', departures=store.departures(current_user())
    )


@app.route('/departure/new', methods=['GET', 'POST'])
@app.route('/departure/<ident>/edit', methods=['GET', 'POST'])
@require_role('carrier')
def departure_form(ident=None):
    row = owned(store.departure(ident), 'carrier') if ident else {}
    if request.method == 'POST':
        try:
            values = dict(
                **lane(),
                vehicle=request.form.get('vehicle', ''),
                capacity=number('capacity'),
                time=timestamp(request.form.get('time', '')),
            )
            code = store.save_departure(ident, current_user(), values)
            flash(f'Departure {code} saved.', 'success')
            return redirect(url_for('departures'))
        except (ValueError, pymysql.MySQLError) as error:
            form_error(error)
    vehicles = [(v['id'], f"{v['id']} - {v['type']}") for v in store.vehicles(current_user())]
    hubs = [(h['id'], h['id']) for h in store.hubs()]
    fields = [
        field('vehicle', 'Vehicle', 'select', vehicles, row.get('vehicle', '')),
        field('origin', 'Origin hub', 'select', hubs, row.get('origin', '')),
        field('destination', 'Destination hub', 'select', hubs, row.get('destination', '')),
        field(
            'time',
            'Departure date and time',
            'datetime-local',
            value=row['time'].isoformat(timespec='minutes') if row else '',
        ),
        field('capacity', 'Capacity (kg)', 'number', value=row.get('capacity', '')),
    ]
    return form_page(
        'Update departure' if row else 'Schedule departure', fields, url_for('departures')
    )


@app.route('/scans/new', methods=['GET', 'POST'])
@require_role('carrier')
def scan_form():
    if request.method == 'POST':
        try:
            values = {
                key: request.form.get(key, '') for key in ['shipment', 'departure', 'hub', 'status']
            }
            values['time'] = timestamp(request.form.get('time', ''))
            store.post_scan(current_user(), values)
            flash('Scan recorded.', 'success')
            return redirect(url_for('track', shipment=values['shipment']))
        except (ValueError, pymysql.MySQLError) as error:
            form_error(error)
    options = [
        (s['id'], f"{s['id']} - {s['departure']}")
        for s in scoped_shipments()
        if store.status(s) != 'DELIVERED'
    ]
    deps = [(d['id'], d['id']) for d in store.departures(current_user())]
    fields = [
        field('shipment', 'Shipment', 'select', options),
        field('departure', 'Departure', 'select', deps),
        field('time', 'Scan date and time', 'datetime-local'),
        field('hub', 'Hub', 'select', [(h['id'], h['id']) for h in store.hubs()]),
        field('status', 'Status', 'select', [(s, s.replace('_', ' ').title()) for s in STATUSES]),
    ]
    return form_page('Post scan event', fields, url_for('dashboard'))


# Reports and queries


def report_results(kind, public):
    start = date.fromisoformat(request.args.get('start') or '2026-01-01')
    end = date.fromisoformat(request.args.get('end') or '2026-12-31')
    if start > end or end == date.max:
        raise ValueError('Choose a valid date range with start on or before end.')
    n = int(request.args.get('n') or 3)
    if n < 0 or n > 10000:
        raise ValueError('N must be between 0 and 10,000.')
    carrier = request.args.get('carrier', '').strip().upper() or None
    if carrier:
        account = store.account(carrier)
        if not account or account['role'] != 'carrier':
            raise ValueError('Enter a valid carrier ID, such as C1.')
    params = dict(
        start_date=start,
        end_date=end,
        top_n=n,
        shipment_code=request.args.get('shipment', '').strip().upper(),
        carrier_code=carrier,
        risk_date=date.today() + timedelta(days=n),
    )
    return store.report(kind, params, None if public else current_user())


def render_report(kind, title, public=False):
    headers, rows = [], []
    if request.args.get('run'):
        try:
            headers, rows = report_results(kind, public)
        except (ValueError, OverflowError) as error:
            flash(str(error), 'error')
    description = (
        'Delivery reports use delivery scan dates. Load and lane-volume reports use scheduled '
        'departure dates. Running totals begin at the selected start date.'
    )
    return render_template(
        'report.html',
        title=title,
        kind=kind,
        headers=headers,
        rows=rows,
        description=description,
        public=public,
    )


@app.route('/queries')
def queries():
    return render_template('queries.html', title='View queries')


@app.route('/queries/<int:index>')
def query(index):
    if index < 1 or index > len(QUERIES):
        abort(404)
    if index == 1:
        headers, rows = store.numbered_query(1, {})
        return table('1. ' + QUERIES[0][0], headers, rows)
    return render_report(
        {2: 'utilization', 3: 'dwell', 4: 'weight', 5: 'multi', 6: 'noscan'}[index],
        f'{index}. {QUERIES[index - 1][0]}',
        public=True,
    )


@app.route('/reports/<kind>')
@require_role()
def report(kind):
    allowed = dict(REPORTS[current_user()['role']])
    if kind not in allowed:
        abort(403)
    return render_report(kind, allowed[kind])


# Error pages


@app.errorhandler(400)
@app.errorhandler(403)
@app.errorhandler(404)
@app.errorhandler(413)
def error_page(error):
    return (
        render_template(
            'error.html', title=f'{error.code} - {error.name}', message=error.description
        ),
        error.code,
    )


@app.errorhandler(DatabaseConfigurationError)
@app.errorhandler(pymysql.MySQLError)
def database_error(error):
    g.db_unavailable = True
    if isinstance(error, DatabaseConfigurationError):
        message = str(error)
    elif error.args[0] == 1045:
        message = 'Database login failed. Check DB_USER and DB_PASSWORD in the local .env file.'
    elif error.args[0] == 1049:
        message = 'Database not found. Check DB_NAME in the local .env file.'
    elif error.args[0] in (2002, 2003, 2006, 2013):
        message = 'Cannot reach the database. Check the VPN, database host and port, then retry.'
    else:
        message = 'The database request failed. Check that all three project SQL files were loaded successfully.'
    app.logger.warning(
        'Database request failed (code %s)',
        'configuration' if isinstance(error, DatabaseConfigurationError) else error.args[0],
    )
    return render_template('error.html', title='Database unavailable', message=message), 503


# Database check command


@app.cli.command('check-db')
def check_db():
    """Check credentials, server version, project objects, and sample counts."""
    try:
        with get_db().cursor() as cursor:
            cursor.execute('SELECT VERSION() AS version, DATABASE() AS db_name')
            info = cursor.fetchone()
            click.echo(f"Connected to {info['db_name']} on MariaDB/MySQL {info['version']}")
            cursor.execute('SELECT COUNT(*) AS count FROM shipment')
            click.echo(f"Shipments: {cursor.fetchone()['count']}")
            cursor.execute('SELECT COUNT(*) AS count FROM scan_event')
            click.echo(f"Scans: {cursor.fetchone()['count']}")
            cursor.execute(
                (
                    'SELECT COUNT(*) AS count FROM information_schema.ROUTINES WHERE '
                    "ROUTINE_SCHEMA=DATABASE() AND ROUTINE_NAME='book_shipment'"
                )
            )
            procedures = cursor.fetchone()['count']
            cursor.execute(
                (
                    'SELECT COUNT(*) AS count FROM information_schema.TRIGGERS WHERE '
                    'TRIGGER_SCHEMA=DATABASE() AND TRIGGER_NAME IN '
                    "('enforce_scan_chronology','maintain_shipment_status')"
                )
            )
            triggers = cursor.fetchone()['count']
            if procedures != 1 or triggers != 2:
                raise click.ClickException(
                    'The required booking procedure or scan triggers are missing.'
                )
            cursor.execute('SELECT COUNT(*) AS count FROM v_departure_load')
            cursor.execute('SELECT COUNT(*) AS count FROM v_delivered_shipment')
            click.echo('Booking procedure, both scan triggers, and reporting views are present.')
    except (DatabaseConfigurationError, pymysql.MySQLError) as error:
        code = 'configuration' if isinstance(error, DatabaseConfigurationError) else error.args[0]
        raise click.ClickException(
            f'Database check failed ({code}). Check .env, VPN, and the loaded schema.'
        )


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
