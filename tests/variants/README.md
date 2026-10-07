# Test variants

131 variants in ABCC8, GCK and KCNJ11, used as a known set for testing the
annotation steps: ClinVar and gnomAD now, and REVEL once it is added.

## Source

Supplementary Table 1 from a REVEL evaluation on loss of function and gain
of function variants, distributed as
`8857940_f1_gof_lof_variants_list_hg37.pdf`. Its coordinates are GRCh37.
Add the full paper citation here.

## Files

- `revel_gof_lof_variants_hg19.csv`: the table from the PDF, one row per
  variant (chrom, start, end, ref, alt, plus gene, protein change and the
  REVEL score printed in the paper).
- `revel_gof_lof_variants_hg38.csv`, `.bed`, `.vcf`: the same variants
  lifted to GRCh38, the build the pipeline uses. They are committed so
  tests don't need internet access to UCSC.
- `liftover_variants.py`: makes the three hg38 files from the hg19 CSV.
  Needs `pip install pyliftover` and internet on the first run.
- `check_ref_hg38.py`: checks each REF base against the hg38 reference,
  fetched from UCSC.

## Regenerate

```bash
python3 liftover_variants.py revel_gof_lof_variants_hg19.csv
python3 check_ref_hg38.py revel_gof_lof_variants_hg38.csv
```

## Where they are used

- The hg38 VCF is the `--test-vcf` for
  `_scripts/reference_refresh/refresh_clinvar_subset.sh`.
- The hg38 BED can be the `--gene-bed` for a small chr7 and chr11 subset
  test of the refresh scripts.
