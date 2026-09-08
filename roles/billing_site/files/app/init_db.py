"""Seed the billing SQLite DB with fictional Voltgrid Power customers.

Idempotent: if the DB file already exists, exits without touching it.
Uses a fixed random seed so the dataset is reproducible run-to-run.
"""
import os
import random
import sqlite3
from datetime import date, timedelta
from werkzeug.security import generate_password_hash

DB_PATH = os.environ.get("DB_PATH", "/data/billing.db")

FIRST_NAMES = [
    "James", "Mary", "Robert", "Patricia", "John", "Jennifer", "Michael",
    "Linda", "William", "Elizabeth", "David", "Barbara", "Richard", "Susan",
    "Joseph", "Jessica", "Thomas", "Sarah", "Charles", "Karen", "Christopher",
    "Nancy", "Daniel", "Lisa", "Matthew", "Margaret", "Anthony", "Betty",
    "Mark", "Sandra", "Donald", "Ashley", "Steven", "Kimberly", "Paul",
    "Emily", "Andrew", "Donna", "Joshua", "Michelle", "Kenneth", "Carol",
    "Kevin", "Amanda", "Brian", "Melissa", "George", "Deborah", "Edward",
    "Stephanie", "Ronald", "Rebecca", "Timothy", "Sharon", "Jason", "Laura",
    "Jeffrey", "Cynthia", "Ryan", "Kathleen", "Jacob", "Amy", "Gary", "Angela",
    "Nicholas", "Shirley", "Eric", "Anna", "Jonathan", "Brenda", "Stephen",
    "Pamela", "Larry", "Emma", "Justin", "Nicole", "Scott", "Samantha",
    "Brandon", "Katherine",
]

LAST_NAMES = [
    "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
    "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
    "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin",
    "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez", "Clark",
    "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen", "King",
    "Wright", "Scott", "Torres", "Nguyen", "Hill", "Flores", "Green",
    "Adams", "Nelson", "Baker", "Hall", "Rivera", "Campbell", "Mitchell",
    "Carter", "Roberts",
]

STREETS = [
    "Maple Street", "Oak Avenue", "Elm Lane", "Pine Road", "Cedar Court",
    "Birch Boulevard", "Spruce Drive", "Willow Way", "Aspen Trail",
    "Magnolia Place", "Sycamore Hill", "Poplar Park",
]

CITIES = [
    ("Voltgrid", "PA", "16001"),
    ("Powerton", "PA", "16002"),
    ("Currentville", "PA", "16003"),
    ("Wattford", "PA", "16004"),
    ("Ampere Heights", "PA", "16005"),
]


def init_schema(conn):
    conn.executescript(
        """
        CREATE TABLE customers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_number TEXT UNIQUE NOT NULL,
            username TEXT UNIQUE NOT NULL,
            password_hash TEXT NOT NULL,
            full_name TEXT NOT NULL,
            email TEXT NOT NULL,
            address TEXT NOT NULL,
            city TEXT NOT NULL,
            state TEXT NOT NULL,
            zip TEXT NOT NULL,
            service_start_date DATE NOT NULL
        );

        CREATE TABLE bills (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            customer_id INTEGER NOT NULL REFERENCES customers(id),
            period_start DATE NOT NULL,
            period_end DATE NOT NULL,
            kwh_used REAL NOT NULL,
            amount_due REAL NOT NULL,
            due_date DATE NOT NULL,
            issued_date DATE NOT NULL,
            paid INTEGER NOT NULL DEFAULT 0,
            paid_date DATE
        );

        CREATE TABLE usage_readings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            customer_id INTEGER NOT NULL REFERENCES customers(id),
            reading_date DATE NOT NULL,
            kwh REAL NOT NULL
        );

        CREATE INDEX idx_bills_customer ON bills(customer_id);
        CREATE INDEX idx_usage_customer ON usage_readings(customer_id);
        """
    )


def seed_customers(conn, n=80):
    rng = random.Random(42)
    customers = []
    used_usernames = set()
    for i in range(n):
        first = rng.choice(FIRST_NAMES)
        last = rng.choice(LAST_NAMES)
        username = f"{first.lower()}.{last.lower()}"
        suffix = 1
        base = username
        while username in used_usernames:
            suffix += 1
            username = f"{base}{suffix}"
        used_usernames.add(username)
        full_name = f"{first} {last}"
        # All seed customers share the password "voltgrid123" for the demo.
        password_hash = generate_password_hash("voltgrid123")
        account_number = f"VG-{100000 + i:06d}"
        email = f"{username}@example.com"
        street_num = rng.randint(100, 9999)
        street = rng.choice(STREETS)
        address = f"{street_num} {street}"
        city, state, zipc = rng.choice(CITIES)
        # Start dates spread across the last 5 years
        days_back = rng.randint(180, 5 * 365)
        start = date.today() - timedelta(days=days_back)
        customers.append((
            account_number, username, password_hash, full_name, email,
            address, city, state, zipc, start.isoformat(),
        ))
    conn.executemany(
        """INSERT INTO customers (
              account_number, username, password_hash, full_name, email,
              address, city, state, zip, service_start_date)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        customers,
    )
    return rng


def seed_bills_and_usage(conn, rng):
    """Generate 6 months of bills and daily usage per customer.

    kWh follows a household-ish daily pattern (15-60 kWh/day with seasonal
    drift), price is $0.13/kWh + $12.50 fixed service fee.
    """
    rate = 0.13
    service_fee = 12.50
    today = date.today()

    customers = conn.execute("SELECT id, service_start_date FROM customers").fetchall()

    bills = []
    readings = []
    for cust_id, _ in customers:
        # 6 full months ending last month
        for months_back in range(6, 0, -1):
            # First day of period_start
            ps_year = today.year
            ps_month = today.month - months_back
            while ps_month <= 0:
                ps_month += 12
                ps_year -= 1
            period_start = date(ps_year, ps_month, 1)
            # period_end = day before next month's first day
            if ps_month == 12:
                next_first = date(ps_year + 1, 1, 1)
            else:
                next_first = date(ps_year, ps_month + 1, 1)
            period_end = next_first - timedelta(days=1)

            total_kwh = 0.0
            d = period_start
            while d <= period_end:
                # Seasonal swing: higher in summer (cooling) and winter (heating)
                month_factor = 1.0
                if d.month in (6, 7, 8):
                    month_factor = 1.5
                elif d.month in (12, 1, 2):
                    month_factor = 1.3
                base = rng.uniform(15, 35) * month_factor
                noise = rng.uniform(-3, 3)
                kwh = round(max(5.0, base + noise), 2)
                readings.append((cust_id, d.isoformat(), kwh))
                total_kwh += kwh
                d += timedelta(days=1)

            amount = round(total_kwh * rate + service_fee, 2)
            due_date = period_end + timedelta(days=20)
            issued = period_end + timedelta(days=2)
            # Older bills mostly paid, most recent often unpaid
            if months_back >= 2:
                paid = 1
                paid_date = (due_date - timedelta(days=rng.randint(0, 15))).isoformat()
            else:
                paid = 1 if rng.random() < 0.4 else 0
                paid_date = (due_date - timedelta(days=rng.randint(0, 15))).isoformat() if paid else None

            bills.append((
                cust_id, period_start.isoformat(), period_end.isoformat(),
                round(total_kwh, 2), amount, due_date.isoformat(),
                issued.isoformat(), paid, paid_date,
            ))

    conn.executemany(
        """INSERT INTO bills (
              customer_id, period_start, period_end, kwh_used, amount_due,
              due_date, issued_date, paid, paid_date)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        bills,
    )
    conn.executemany(
        "INSERT INTO usage_readings (customer_id, reading_date, kwh) VALUES (?, ?, ?)",
        readings,
    )


def main():
    if os.path.exists(DB_PATH):
        print(f"DB already present at {DB_PATH}; skipping seed.")
        return
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    print(f"Seeding fresh DB at {DB_PATH}")
    conn = sqlite3.connect(DB_PATH)
    try:
        init_schema(conn)
        rng = seed_customers(conn)
        seed_bills_and_usage(conn, rng)
        conn.commit()
        n_cust = conn.execute("SELECT COUNT(*) FROM customers").fetchone()[0]
        n_bill = conn.execute("SELECT COUNT(*) FROM bills").fetchone()[0]
        n_read = conn.execute("SELECT COUNT(*) FROM usage_readings").fetchone()[0]
        print(f"Seeded {n_cust} customers, {n_bill} bills, {n_read} usage readings.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
