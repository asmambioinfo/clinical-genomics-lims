# Clinical Genomics LIMS & NGS Analysis Platform

**Author:** Asma Mustafa

This is a working platform for a clinical NGS workflow. It covers both sides of the problem: a LIMS for patient registration, sample accessioning, test ordering, and variant results, and the NGS variant calling pipeline that feeds it. I designed and built the schema, the app, the pipeline integration, and the deployment path myself, end to end.

The variant calling pipeline design is based on the bioinformatic methodology I helped develop and describe in Khanolkar et al., ImmunoHorizons 2020 (https://doi.org/10.4049/immunohorizons.1900060): adapter trimming, alignment, indel realignment, multi caller consensus variant calling, and annotation. I was the bioinformatician on that study who performed the sequencing analysis. Here I adapted that methodology for a LIMS context, so results get written directly to the database through `pipeline_uploader` instead of being reviewed manually. The specifics of that adaptation are in `docs/workflows.md`.

## What this project demonstrates

**Database design.** I designed the relational schema (`patients → samples → orders → variants`) from scratch, including the ER model, the key strategy (readable app generated IDs alongside DB generated surrogate keys), constraint design (no cascading deletes, CHECK constraints on status and classification), and indexing. Full detail is in `docs/db-schema.md`.

**Build.** The schema was implemented and iterated on in Azure SQL Server, with the frontend built in Streamlit against it.

**Test and QA.** I tested against a dedicated test database (`.env.test`) and caught and fixed real defects along the way: a non deterministic computed column that SQL Server rejected as a key, an invalid key column type on a `VARCHAR(MAX)` field, join logic that drifted as the schema evolved, and a race condition in ID generation.

**Deploy path.** Credentials are environment switched between test and prod and built into the database layer from the start, so the same codebase moves from test to QA to production without any code changes, only configuration.

**Pipeline integration.** I designed the hand off between the Nextflow NGS pipeline (FastQC, alignment, variant calling) and the database through a dedicated uploader component, with an Azure Function trigger planned to automate that hand off end to end.

## Documentation

- `docs/db schema.md` covers the schema, the ER relationships, and the reasoning behind the key design decisions.
- `docs/architecture.md` covers the system components, the data flow, and the repo layout.
- `docs/nw.md` covers the database network access strategy (VNet vs. NAT Gateway) for moving pipeline compute onto Azure.
- `docs/workflows.md` walks through every user facing and pipeline workflow, and is honest about what's built versus what's designed but not yet implemented.