# Migration policy

Migrations in this folder change structure only. They never change the data
in a table. This is a clinical database, so existing records are never
rewritten or removed by a schema change.

## Rules

1. **No DROP TABLE and no DROP COLUMN.** To retire a table or column, rename
   it with an archive suffix that includes the migration number, for example
   `notes` becomes `notes_archive_0007`. The data stays in place and stays
   readable. If the retired column was NOT NULL, or carried a unique
   constraint, foreign key or computed column that depends on it, make it
   nullable and deal with those first. Otherwise new inserts fail against a
   column nothing writes to anymore.
2. **No INSERT, UPDATE or DELETE on patients, samples, orders or variants.**
   A migration may fill a brand new, empty lookup table with its starting
   values.
3. **ALTER COLUMN only to widen a type**, for example VARCHAR(50) to
   VARCHAR(100). Any other change is a new column plus archiving the old one.
4. **New columns must be nullable, or NOT NULL with a DEFAULT.** With a
   default, existing rows simply read as that default.
5. **Indexes, constraints and views hold no data** and may be dropped and
   recreated. Migration 0002 does this to the status CHECK constraint.

## Scope

These rules govern the migration files in this folder. They don't restrict
what the application does at runtime, such as registering patients or placing
orders. The one exception is `db/reset_dev_db.sql`, which drops tables and is
only for disposable test databases, never prod.

## When data does need to change

Correcting a bad record or converting a column's contents is not a
migration. It needs a separate, reviewed script run by hand, with a verified
backup taken first. Until the audit trail below exists, nothing records who
changed what, so these should be rare and written down.

## Planned: audit trail

Audit columns (created and modified timestamp and user, plus a record status
for soft delete) will let a record be marked deleted or modified without ever
removing a row. These should go in while the tables are still small, because
adding a NOT NULL column to a table full of rows is exactly the case that
rule 4 makes awkward.

## How a new migration is added

Add the next numbered `.sql` file here and run
`python _scripts/run_migrations.py test`, then prod. The runner only reads
files ending in `.sql`, so this README is ignored by it. Never edit a
migration that has already been applied.