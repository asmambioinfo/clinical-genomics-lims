# Todo / Roadmap

Forward-looking items not yet built. For known limitations in what's
already built, see the "Known limitations" sections in `db-schema.md` and
`workflows.md` instead — this file is for what's planned next, not what's
wrong with what exists.

## Reference database maintenance

- gnomAD quarterly refresh is built: `scripts/refresh_gnomad_subset.sh`
  (auto-detects latest release, subsets to the gene panel, diffs
  chr-by-chr against current, archives + promotes only if under
  threshold). See `workflows.md` workflow 7 for the two things it still
  needs before it can run unattended (blob account/container
  confirmation, Key Vault role for a non-human identity).
- ClinVar quarterly refresh: not built yet. Same shape as the gnomAD
  script, but diffs on `CLNSIG` (clinical significance) instead of `AF`,
  since that's ClinVar's field.

## EHR / LIMS integration

- A plugin to pull MRN (and likely name/DOB) directly from an external EHR
  system such as Epic, instead of a user retyping it. Epic's standard
  integration path is their FHIR API (via App Orchard / Epic on FHIR) —
  worth scoping against that rather than a custom integration, since it's
  the path most hospital IT departments will actually approve.
- Not started. Would slot into the existing patient-lookup flow in
  `frontend/app.py` (tab 2's MRN field) as an additional source alongside
  manual entry.

## FASTQ ingestion

Two related but distinct needs, worth keeping separate:

**Triggering the pipeline.** Two different trigger sources are worth
planning for, not just one:
- Order placed in the LIMS (already noted in `architecture.md` — planned
  Azure Function trigger)
- A sequencer finishing a run and writing FASTQ directly to blob storage
  (a separate trigger: Azure Event Grid + Function reacting to a new blob
  landing in the container, no LIMS order needed to kick it off)

**No physical sequencer available right now**, so FASTQ has to get into
blob storage some other way in the meantime. Two options, neither built:
1. Manual upload — via the Azure Portal directly, or the CLI
   (`az storage blob upload`) for a user who has an Azure account and
   knows the destination container/path.
2. Through the Streamlit UI — extend `frontend/app.py` with a FASTQ
   upload widget, plus letting the user choose panel vs. full exome at
   upload time (ties into the pricing tiers in `iteragen.md`).

Either way, once a FASTQ lands in blob storage, the sequencer-trigger
mechanism above is what would actually kick off `main.nf` — these two
pieces are meant to work together, not as separate features.
