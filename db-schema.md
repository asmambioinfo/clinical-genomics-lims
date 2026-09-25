# Database Schema

Source of truth for the schema is `db/schema.sql`. This document explains the
design decisions behind it. If the two ever disagree, `schema.sql` wins —
update this file to match.

Engine: Azure SQL Server (confirmed via the connection in use —
`iteragen.database.windows.net`, database `genomics_test`). Note:
`nw.md` was originally drafted assuming Azure PostgreSQL; that's a mismatch
worth resolving so networking docs match the actual engine.

## Entity relationship

```
patients (1) ──< samples (1) ──< orders (1) ──< variants
                                    │
                                    └──(self-reference)── repeat_of_order_id
```

- One patient (by `mrn`) can have many samples (different draws over time).
- One sample can have many orders (different test codes, or the same
  test code repeated on the same extracted DNA/RNA).
- One order can have many variant calls.
- An order can optionally point back at the order it's repeating
  (`repeat_of_order_id`), e.g. when a sequencing run fails and the same
  test is re-ordered against the same sample.

## `patients`

| Column | Type | Notes |
|---|---|---|
| `patient_id` | `VARCHAR(20)` PK | App-generated, format `YYYYMMDD-00001` (date + daily serial). Not a DB identity — the application must generate this before insert. |
| `mrn` | `VARCHAR(50)` NOT NULL UNIQUE | Medical record number, the human-facing identifier used in the frontend search. |
| `name` | `VARCHAR(100)` NOT NULL | |
| `age` | `INT` NOT NULL | |
| `sex` | `VARCHAR(10)` NOT NULL | |
| `date_registered` | `DATETIME` DEFAULT `GETDATE()` | |

**Why `patient_id` isn't an `IDENTITY` column:** an earlier version tried to
compute `patient_id` from `YEAR(GETDATE())`, which SQL Server rejects as a
key column because `GETDATE()` is non-deterministic. Generating the ID in
application code (see `generate_next_patient_id()` in `frontend/app.py`)
sidesteps that, at the cost of the app owning uniqueness — see the race
condition note under "Known limitations" below.

## `samples`

| Column | Type | Notes |
|---|---|---|
| `sample_id` | `VARCHAR(40)` PK | App-generated, format `SAM-YYYYMMDD-00001`. |
| `patient_id` | `VARCHAR(20)` NOT NULL FK → `patients.patient_id` | |
| `date_collected` | `DATETIME` DEFAULT `GETDATE()` | |

Index: `idx_samples_patient_id` on `patient_id` (SQL Server doesn't
auto-index foreign keys, only primary keys — every FK column in this schema
has an explicit index for join performance).

## `orders`

| Column | Type | Notes |
|---|---|---|
| `order_id` | `INT IDENTITY(1,1)` PK | DB-generated, guarantees uniqueness with no app-side locking. |
| `test_order_id` | computed, `PERSISTED UNIQUE` | `'ORD-' + order_id`. Friendly display ID. **Cannot be inserted into directly** — read it back with `OUTPUT INSERTED.test_order_id` after an insert. |
| `sample_id` | `VARCHAR(40)` NOT NULL FK → `samples.sample_id` | |
| `test_code` | `VARCHAR(50)` NOT NULL | e.g. `Hereditary_Cancer`, `Cardio_Risk`, `Whole_Exome`. Currently free text in the frontend dropdown — not DB-constrained to a fixed list. |
| `repeat_of_order_id` | `INT` NULL FK → `orders.order_id` (self) | Set when this order repeats a prior one on the same sample (e.g. failed sequencing run, re-run on the same extracted material). NULL for a first attempt. |
| `date_ordered` | `DATETIME` DEFAULT `GETDATE()` | |
| `status` | `VARCHAR(20)` DEFAULT `'Pending'`, `CHECK IN ('Pending','Running','Completed','Failed','Cancelled')` | |

Indexes: `idx_orders_sample_id`, `idx_orders_repeat_of`.

**Why there's no "run number" column:** an earlier design tried to encode a
run/attempt number into `test_order_id` (e.g. `...-R2`), which required
locking (`UPDLOCK, HOLDLOCK`) to safely compute "next run" under concurrent
orders. Using a plain `IDENTITY` column removes the need for that locking
entirely — SQL Server guarantees uniqueness for free. "Which attempt this
is" is now a display/traceability concern (`repeat_of_order_id` +
`date_ordered`), not a schema-enforced sequence.

## `variants`

| Column | Type | Notes |
|---|---|---|
| `variant_id` | `INT IDENTITY(1,1)` PK | |
| `order_id` | `INT` NOT NULL FK → `orders.order_id` | |
| `sample_id` | `VARCHAR(40)` NOT NULL FK → `samples.sample_id` | Denormalized for query convenience (avoids a join through `orders` for simple sample-level lookups). **Must be kept in sync with the parent order's `sample_id` by the pipeline uploader at insert time** — SQL Server can't cross-check this against a second table automatically. |
| `chrom` | `VARCHAR(5)` NOT NULL | |
| `start_pos` | `INT` NOT NULL | |
| `end_pos` | `INT` NOT NULL | |
| `ref` | `VARCHAR(MAX)` NOT NULL | |
| `alt` | `VARCHAR(MAX)` NOT NULL | |
| `ref_alt_hash` | computed, `PERSISTED`, `VARBINARY(32)` | `HASHBYTES('SHA2_256', ref + '|' + alt)`. Stands in for `(ref, alt)` in the uniqueness constraint below, since SQL Server won't allow a `MAX`-length column as an index/constraint key. |
| `classification` | `VARCHAR(50)` NOT NULL, `CHECK IN ('Pathogenic','Likely Pathogenic','VUS','Likely Benign','Benign')` | Standard ACMG five-tier classification. |

Constraint: `uq_variants_call UNIQUE (order_id, chrom, start_pos, ref_alt_hash)`
— prevents the pipeline uploader from inserting the same variant call twice
on a retry.

Indexes: `idx_variants_sample_id`, `idx_variants_order_id`.

## Deletes

There is no `ON DELETE CASCADE` anywhere in this schema. Deleting a patient,
sample, or order is blocked by default (SQL Server's `NO ACTION`) rather
than silently cascading through samples → orders → variants. Clinical
genomic data typically carries retention requirements (CLIA/CAP and
state-level rules commonly require multi-year retention), so an accidental
delete should fail loudly, not quietly wipe downstream records. If records
genuinely need to be retired, use a soft-delete flag (e.g. `is_active`)
rather than a hard delete — not yet implemented.

## Known limitations / open items

- **`patient_id` and `sample_id` generation is not race-safe.** Both are
  computed in application code via `SELECT COUNT(*) ... WHERE ... LIKE
  'prefix%'`, which can return the same "next number" to two concurrent
  requests. This hasn't caused a problem yet at low usage, but should be
  fixed (transaction + `UPDLOCK, HOLDLOCK`, or switch to a DB sequence)
  before multi-user concurrent use.
- **`test_code` is not constrained to a fixed set at the DB level** — only
  by the frontend's dropdown. A future migration should probably add a
  lookup table or `CHECK` constraint once the panel list stabilizes.
- **No schema migration tooling yet.** Changes are currently applied by
  hand-editing `schema.sql` and re-running against a fresh database. Worth
  introducing versioned migrations before this touches production data.
- **Order deletion is a soft-delete only** (`status = 'Deleted'` via the
  frontend's delete button, not a hard `DELETE`). Undo, an audit trail of
  who deleted what and when, and a confirmation modal before deleting are
  intentionally out of scope for this demo — a production version would
  need at least an audit log (who/when/previous status) before this
  feature touches real patient data.

## Reset script

`db/reset_dev_db.sql` drops all four tables and is dev/test only — never run
against production. Re-run `schema.sql` afterward to recreate an empty
schema.