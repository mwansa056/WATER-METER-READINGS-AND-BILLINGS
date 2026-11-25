
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL
        CHECK (previous_reading >= 0),
    current_reading NUMERIC(10,2) NOT NULL
        CHECK (current_reading >= 0),

    UNIQUE (customer_id, reading_month),
    CHECK (reading_month = DATE_TRUNC('month', reading_month)::DATE)
);

CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INT NOT NULL UNIQUE
        REFERENCES readings(reading_id),
    charge NUMERIC(10,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10,2) NOT NULL DEFAULT 0
        CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12,2) NOT NULL CHECK (total_due >= 0)
);

INSERT INTO customers (full_name)
VALUES
    ('John Banda'),
    ('Mary Phiri'),
    ('Peter Zulu');

INSERT INTO readings
    (customer_id, reading_month, previous_reading, current_reading)
VALUES
    (1, '2026-01-01', 100, 100),  -- 0 units
    (1, '2026-02-01', 100, 110),  -- 10 units
    (2, '2026-01-01', 200, 215),  -- 15 units
    (2, '2026-02-01', 215, 220),  -- 5 units
    (3, '2026-01-01', 50, 70),    -- 20 units
    (3, '2026-02-01', 70, 80);    -- 10 units


CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(10,2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be NULL or negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge := (10 * 5) + ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;


CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INT,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous NUMERIC(10,2);
    v_current NUMERIC(10,2);
    v_units NUMERIC(10,2);
    v_charge NUMERIC(10,2);
BEGIN
    SELECT previous_reading, current_reading
    INTO v_previous, v_current
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reading does not exist';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION 'A bill already exists for this reading';
    END IF;

    v_units := v_current - v_previous;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

CALL pr_generate_bill(1, '2026-02-15');
CALL pr_generate_bill(2, '2026-03-15');
CALL pr_generate_bill(3, '2026-02-15');
CALL pr_generate_bill(4, '2026-03-15');
CALL pr_generate_bill(5, '2026-02-15');
CALL pr_generate_bill(6, '2026-03-15');


CREATE OR REPLACE FUNCTION fn_validate_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
            'Current reading cannot be below previous reading';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_validate_reading();


CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM customers c
JOIN readings r
    ON c.customer_id = r.customer_id
JOIN bills b
    ON r.reading_id = b.reading_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;


CREATE INDEX idx_unpaid_bills_due_on
ON bills (due_on)
WHERE amount_paid < charge;

SELECT
    bill_id,
    due_on,
    charge - amount_paid AS outstanding_amount
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

EXPLAIN
SELECT
    bill_id,
    due_on,
    charge - amount_paid AS outstanding_amount
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;


CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(12,2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0)
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();

CALL pr_refresh_receivables();

SELECT *
FROM receivable_snapshot
ORDER BY snapshot_date;
