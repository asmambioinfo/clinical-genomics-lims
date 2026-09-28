# Architecture

## Components

**Frontend** — `frontend/app.py`, a Streamlit app. Three workflows: register
a patient, accession a sample and place a test order, and search existing
patients/samples/orders/variants. Talks to the database directly through
`DatabaseManager` — there is no API layer between the UI and the DB.

**Database core** — `_scripts/core/database.py`. Provides `DatabaseManager`,
which switches between test and production credentials based on environment
(`.env.test` / `.env.prod`). The frontend never connects to the DB directly;
everything goes through this layer.

**Database** — Azure SQL Server (`iteragen.database.windows.net`, database
`genomics_test` in the test environment). Schema is `patients → samples →
orders → variants`; see `docs/db-schema.md` for the full table design and
rationale. Accessed via `pymssql` (DB-Lib) based on error output seen during
development.

**NGS pipeline** — `nextflow-run/main.nf` + `nextflow.config`. Runs fastp trimming,
alignment, and variant calling on sequencing output.

**Pipeline uploader** — `_scripts/pipeline_uploader/`, an OOP tool invoked by
Nextflow as the last step of a pipeline run. Parses the pipeline's VCF/JSON
output and writes results back to the database (`variants` rows, and an
`orders.status` update).

## Data flow

```
 ┌────────────┐      ┌──────────────────┐      ┌───────────────────┐
 │  frontend/  │ ───▶ │ DatabaseManager   │ ───▶ │  Azure SQL Server  │
 │  app.py     │ ◀─── │ (_scripts/core)   │ ◀─── │  (genomics_test)   │
 └────────────┘      └──────────────────┘      └────────┬──────────┘
                                                          ▲
                                                          │ INSERT variants,
                                                          │ UPDATE orders.status
                                                 ┌────────┴──────────┐
                                                 │ pipeline_uploader  │
                                                 └────────▲──────────┘
                                                          │ parses VCF/JSON
                                                 ┌────────┴──────────┐
                                                 │ nextflow-run/      │
                                                 │ main.nf            │
                                                 │ (fastp → Align →   │
                                                 │  Variant Calling)  │
                                                 └────────────────────┘
```

End-to-end: a patient is registered and a sample accessioned through the
frontend, which creates an `orders` row with `status = 'Pending'`. The
Nextflow pipeline runs against that sample's sequencing data, and
`pipeline_uploader` writes the resulting variant calls into the `variants`
table against that order, updating `orders.status` to `Completed` or
`Failed`. Results then become visible through the frontend's search tab.

**Planned:** nothing in the current repo automatically triggers a Nextflow
run when an order is placed — that hand-off is manual/external today. Next
step is an Azure Function (Azure's equivalent of AWS Lambda) triggered on
order placement to kick off the pipeline run automatically, removing the
manual step.

## Repository layout

```
my-genomics-platform/
├── .env.test              <- test DB credentials
├── .env.prod              <- production DB credentials
├── pyproject.toml
│
├── docs/                  <- cross-cutting documentation (this folder)
│   ├── db-schema.md
│   ├── architecture.md
│   ├── nw.md
│   └── workflows.md
│
├── db/                    <- schema source of truth
│   ├── schema.sql
│   └── reset_dev_db.sql   <- dev/test only, never run against prod
│
├── frontend/
│   └── app.py
│
├── _scripts/
│   ├── core/
│   │   ├── __init__.py
│   │   └── database.py            <- test/prod DB switching
│   └── pipeline_uploader/
│       ├── __init__.py
│       ├── __main__.py            <- entrypoint, called by Nextflow
│       └── uploader.py            <- parses VCF/JSON, writes to DB
│
└── nextflow-run/
    ├── main.nf                    <- fastp, alignment, variant calling
    └── nextflow.config
```

## Key design decisions

- **App-generated human-readable IDs, DB-generated surrogate keys.**
  `patient_id` and `sample_id` are generated in application code (date +
  daily serial, e.g. `SAM-20260925-00001`) for readability. `order_id` and
  `variant_id` are plain SQL Server `IDENTITY` columns — see `db-schema.md`
  for why this split exists (it removes the need for app-side locking on
  order creation).
- **No hard deletes.** Every foreign key defaults to `NO ACTION`; nothing
  cascades. Records identified for removal are soft-deleted via a status
  flag rather than actually deleted, given clinical data retention
  requirements.
- **Credentials are environment-switched, not hardcoded.** `DatabaseManager`
  picks `.env.test` or `.env.prod` based on environment — check
  `_scripts/core/database.py` for how that switch is triggered before
  running anything against production.

## Known gaps

- No automated trigger from "order placed" to "pipeline runs" (see above).
- No API layer — the frontend talks to the database directly, which is fine
  for a single Streamlit app but won't scale to multiple clients without
  refactoring.
- No test suite beyond `test_conn.py` (a connection smoke test, not
  functional coverage of the frontend or uploader logic).
