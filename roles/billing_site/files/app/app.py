"""Voltgrid Power Company — customer billing portal.

INTENTIONALLY seeded vulnerabilities (range training; do not "fix"):
  - IDOR on /bill/<int:bill_id> — fetches by primary key with no ownership
    check; trainees can iterate IDs and read other customers' bills.
  - Reflected XSS via the `error` query parameter on /login — the value is
    rendered directly into the page through innerHTML on the client side.
"""
import os
import sqlite3
from datetime import date, timedelta

from flask import (
    Flask, g, request, session, redirect, url_for, render_template, flash,
)
from werkzeug.security import check_password_hash

DB_PATH = os.environ.get("DB_PATH", "/data/billing.db")

app = Flask(__name__)
app.secret_key = os.environ.get("SECRET_KEY", "voltgrid-dev-secret-change-me")


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(_):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def current_customer():
    cid = session.get("customer_id")
    if not cid:
        return None
    row = get_db().execute(
        "SELECT * FROM customers WHERE id = ?", (cid,)
    ).fetchone()
    return row


@app.context_processor
def inject_user():
    return {"customer": current_customer()}


@app.route("/")
def index():
    if session.get("customer_id"):
        return redirect(url_for("dashboard"))
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        row = get_db().execute(
            "SELECT * FROM customers WHERE username = ?", (username,)
        ).fetchone()
        if row and check_password_hash(row["password_hash"], password):
            session.clear()
            session["customer_id"] = row["id"]
            return redirect(url_for("dashboard"))
        # NOTE: passing `username` back through a URL param feeds the
        # client-side error renderer, which uses innerHTML — see login.html.
        return redirect(url_for("login", error=f"Invalid login for {username}"))
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


def require_login():
    if not session.get("customer_id"):
        return redirect(url_for("login"))
    return None


@app.route("/dashboard")
def dashboard():
    if (r := require_login()):
        return r
    db = get_db()
    cust = current_customer()
    latest_bill = db.execute(
        "SELECT * FROM bills WHERE customer_id = ? ORDER BY period_end DESC LIMIT 1",
        (cust["id"],),
    ).fetchone()
    unpaid_total = db.execute(
        "SELECT COALESCE(SUM(amount_due), 0) AS t FROM bills WHERE customer_id = ? AND paid = 0",
        (cust["id"],),
    ).fetchone()["t"]
    last_30_kwh = db.execute(
        "SELECT COALESCE(SUM(kwh), 0) AS t FROM usage_readings WHERE customer_id = ? AND reading_date >= ?",
        (cust["id"], (date.today() - timedelta(days=30)).isoformat()),
    ).fetchone()["t"]
    return render_template(
        "dashboard.html",
        latest_bill=latest_bill,
        unpaid_total=unpaid_total,
        last_30_kwh=round(last_30_kwh, 1),
    )


@app.route("/bills")
def bills():
    if (r := require_login()):
        return r
    cust = current_customer()
    rows = get_db().execute(
        "SELECT * FROM bills WHERE customer_id = ? ORDER BY period_end DESC",
        (cust["id"],),
    ).fetchall()
    return render_template("bills.html", bills=rows)


@app.route("/bill/<int:bill_id>")
def bill_detail(bill_id):
    """View a specific bill.

    SEEDED VULNERABILITY (IDOR): we look the bill up by its primary key with
    no check that it belongs to the logged-in customer. Iterating bill_id
    exposes everyone's bills.
    """
    if (r := require_login()):
        return r
    db = get_db()
    bill = db.execute("SELECT * FROM bills WHERE id = ?", (bill_id,)).fetchone()
    if not bill:
        return "Bill not found", 404
    owner = db.execute(
        "SELECT full_name, account_number FROM customers WHERE id = ?",
        (bill["customer_id"],),
    ).fetchone()
    return render_template("bill_detail.html", bill=bill, owner=owner)


@app.route("/usage")
def usage():
    if (r := require_login()):
        return r
    cust = current_customer()
    rows = get_db().execute(
        """SELECT reading_date, kwh
           FROM usage_readings
           WHERE customer_id = ?
             AND reading_date >= ?
           ORDER BY reading_date""",
        (cust["id"], (date.today() - timedelta(days=90)).isoformat()),
    ).fetchall()
    return render_template("usage.html", readings=rows)


@app.route("/pay", methods=["GET", "POST"])
def pay():
    if (r := require_login()):
        return r
    cust = current_customer()
    db = get_db()
    if request.method == "POST":
        bill_id = request.form.get("bill_id", type=int)
        bill = db.execute(
            "SELECT * FROM bills WHERE id = ? AND customer_id = ?",
            (bill_id, cust["id"]),
        ).fetchone()
        if not bill:
            flash("Bill not found.", "error")
        elif bill["paid"]:
            flash("That bill is already paid.", "info")
        else:
            db.execute(
                "UPDATE bills SET paid = 1, paid_date = ? WHERE id = ?",
                (date.today().isoformat(), bill_id),
            )
            db.commit()
            flash(f"Payment of ${bill['amount_due']:.2f} accepted. Thank you!", "success")
        return redirect(url_for("pay"))
    unpaid = db.execute(
        "SELECT * FROM bills WHERE customer_id = ? AND paid = 0 ORDER BY due_date",
        (cust["id"],),
    ).fetchall()
    return render_template("pay.html", unpaid=unpaid)


@app.route("/profile")
def profile():
    if (r := require_login()):
        return r
    return render_template("profile.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
