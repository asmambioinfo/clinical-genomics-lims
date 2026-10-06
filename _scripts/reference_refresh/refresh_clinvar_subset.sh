#!/bin/bash
# scripts/refresh_clinvar_subset.sh
#
# Refresh of the ClinVar subset used by main.nf's ANNOTATE step. Downloads
# the current ClinVar VCF, subsets it to your gene panel, diffs it against
# the current subset on position + CLNSIG (clinical significance), runs an
# E2E annotation check against a known test VCF, and only promotes to
# "current" if both the diff is under threshold and the E2E check passes.
# Otherwise it's left in a dated staging folder for human review.
#
# Unlike gnomAD, ClinVar has no numbered releases -- it's a single rolling
# file, so "recent" is labeled by download date, not a version number.
#
# The pipeline-facing blob path never changes name (clinvar_current.vcf.gz)
# -- same pattern as the gnomAD script. Version/date is tracked separately
# in current_version.txt, not in the path, so nextflow.config never needs
# editing after a refresh.
#
# Usage:
#   ./refresh_clinvar_subset.sh --gene-bed /path/to/gene_bed.bed --test-vcf /path/to/known_sample.vcf.gz
#   ./refresh_clinvar_subset.sh --gene-bed /path/to/gene_bed.bed --threshold 0.05

set -euo pipefail

# ---------- defaults ----------
THRESHOLD_PCT="0.01"     # max allowed %% of positions with a changed CLNSIG to auto-pass
GENE_BED=""
TEST_VCF=""               # a known-good sample VCF for the E2E annotation check
BLOB_ACCOUNT="genomicsngs"
BLOB_CONTAINER="reference-data"
BLOB_PREFIX="reference"
DATESTAMP=$(date +%Y%m%d)
WORKDIR="./clinvar_refresh_${DATESTAMP}_$(date +%H%M%S)"

usage() {
    echo "Usage: $0 --gene-bed FILE [--test-vcf FILE] [--threshold PCT]"
    echo "  --test-vcf enables the E2E annotation check. Without it, that"
    echo "  step is skipped with a warning -- add it before relying on this"
    echo "  for a real promotion decision."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gene-bed)  GENE_BED="$2"; shift 2 ;;
        --test-vcf)  TEST_VCF="$2"; shift 2 ;;
        --threshold) THRESHOLD_PCT="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown argument: $1"; usage ;;
    esac
done

[[ -z "$GENE_BED" ]] && { echo "Error: --gene-bed is required."; usage; }
[[ ! -f "$GENE_BED" ]] && { echo "Error: gene bed file not found: $GENE_BED"; exit 1; }

mkdir -p "$WORKDIR"
cd "$WORKDIR"
echo "Working directory: $(pwd)"

STORAGE_KEY="$(az keyvault secret show --vault-name genomics-secrets --name storage-account-key --query value -o tsv)"

# ---------- 1. download the current ClinVar release ----------
mkdir -p "recent_${DATESTAMP}_to_test"
echo "Downloading current ClinVar release..."
curl -sO https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz
curl -sO https://ftp.ncbi.nlm.nih.gov/pub/clinvar/vcf_GRCh38/clinvar.vcf.gz.tbi

# ---------- 2. subset to the gene panel ----------
echo "Subsetting to gene panel regions..."
bcftools view -R "$GENE_BED" clinvar.vcf.gz -Oz -o "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz"
tabix -p vcf "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz"

# ---------- 3. pull the current subset from blob for comparison ----------
mkdir -p current
echo "Downloading current subset from blob for comparison..."
CURRENT_EXISTS=1
az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
    -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/clinvar_current.vcf.gz" -f current/clinvar_current.vcf.gz 2>/dev/null || CURRENT_EXISTS=0
CURRENT_VERSION="unknown"
if [[ "$CURRENT_EXISTS" == "1" ]]; then
    az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/clinvar_current.vcf.gz.tbi" -f current/clinvar_current.vcf.gz.tbi
    if az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/clinvar_current_version.txt" -f current/current_version.txt 2>/dev/null; then
        CURRENT_VERSION=$(cat current/current_version.txt)
    fi
fi
echo "Current blob version on record: $CURRENT_VERSION"

# ---------- 4. diff on position + CLNSIG ----------
# Same isec pattern as the gnomAD script: 0002.vcf.gz and 0003.vcf.gz hold
# the same shared sites in the same order, sourced from current and recent
# respectively, so their CLNSIG columns can be pasted and compared directly.
# CLNSIG is a string field (Pathogenic/Benign/VUS/etc.), so this is a plain
# string inequality check, not a numeric tolerance like gnomAD's AF diff.
ADDED=0; DELETED=0; CHANGED=0; UNCHANGED=0

mkdir -p report

if [[ "$CURRENT_EXISTS" == "0" ]]; then
    echo "No current ClinVar subset found in blob -- treating everything as added (first run)."
    ADDED=$(bcftools view -H "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz" | wc -l | tr -d ' ')
else
    bcftools isec -p isec_out -O z current/clinvar_current.vcf.gz "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz" >/dev/null

    ADDED=$(zcat isec_out/0001.vcf.gz | grep -vc '^#' || true)
    DELETED=$(zcat isec_out/0000.vcf.gz | grep -vc '^#' || true)

    if [[ -s isec_out/0002.vcf.gz ]]; then
        paste \
            <(bcftools query -f '%CHROM\t%POS\t%INFO/CLNSIG\n' isec_out/0002.vcf.gz) \
            <(bcftools query -f '%INFO/CLNSIG\n' isec_out/0003.vcf.gz) \
            > isec_out/clnsig_compare.tsv
        CHANGED=$(awk -F'\t' '$3 != $4 {c++} END{print c+0}' isec_out/clnsig_compare.tsv)
        UNCHANGED=$(awk -F'\t' '$3 == $4 {c++} END{print c+0}' isec_out/clnsig_compare.tsv)
    fi
fi

TOTAL=$((ADDED + DELETED + CHANGED + UNCHANGED))
TOTAL_DIFFERENT=$((ADDED + DELETED + CHANGED))
if [[ "$TOTAL" -eq 0 ]]; then
    PCT_CHANGE="0"
else
    PCT_CHANGE=$(awk -v d="$TOTAL_DIFFERENT" -v t="$TOTAL" 'BEGIN{printf "%.6f", (d/t)*100}')
fi

{
echo "# ClinVar subset refresh report"
echo ""
echo "Current version: $CURRENT_VERSION"
echo "New version (download date): $DATESTAMP"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "## Diff (position + CLNSIG)"
echo ""
echo "- Added: $ADDED"
echo "- Deleted: $DELETED"
echo "- Changed CLNSIG: $CHANGED"
echo "- Unchanged: $UNCHANGED"
echo "- Total positions compared: $TOTAL"
echo "- Percent changed: ${PCT_CHANGE}%"
echo "- Threshold: ${THRESHOLD_PCT}%"
} > report/summary.md

# ---------- 5. E2E annotation check ----------
E2E_PASSED=1
if [[ -n "$TEST_VCF" ]]; then
    echo "Running E2E annotation check against $TEST_VCF..."
    if bcftools annotate -a "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz" \
        -c INFO/CLNSIG,INFO/CLNDN -O z -o report/e2e_test_output.vcf.gz "$TEST_VCF" 2>report/e2e_error.log; then
        ANNOTATED_COUNT=$(bcftools view -H report/e2e_test_output.vcf.gz | grep -c 'CLNSIG' || true)
        echo "E2E check passed: annotation ran without error, $ANNOTATED_COUNT records annotated." | tee -a report/summary.md
    else
        E2E_PASSED=0
        echo "E2E check FAILED -- see report/e2e_error.log" | tee -a report/summary.md
    fi
else
    echo "" >> report/summary.md
    echo "**E2E check skipped** -- no --test-vcf given. Add one before relying" >> report/summary.md
    echo "on this script's output for a real promotion decision." >> report/summary.md
    echo "Warning: no --test-vcf given, skipping E2E annotation check."
fi

echo ""
cat report/summary.md
echo ""

# ---------- 6. pass/fail decision ----------
DIFF_PASSED=$(awk -v pct="$PCT_CHANGE" -v thresh="$THRESHOLD_PCT" 'BEGIN{print (pct<thresh) ? "1" : "0"}')

if [[ "$DIFF_PASSED" == "1" && "$E2E_PASSED" == "1" ]]; then
    echo "PASSED: diff ${PCT_CHANGE}% < ${THRESHOLD_PCT}% threshold, E2E check ok (or skipped)."
    echo "Archiving current and promoting new version."

    if [[ "$CURRENT_VERSION" != "unknown" ]]; then
        az storage blob copy start --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
            --destination-container "$BLOB_CONTAINER" \
            --destination-blob "${BLOB_PREFIX}/archive_clinvar_${CURRENT_VERSION}/clinvar_${CURRENT_VERSION}.vcf.gz" \
            --source-container "$BLOB_CONTAINER" \
            --source-blob "${BLOB_PREFIX}/clinvar_current.vcf.gz"
        echo "Archived previous version ($CURRENT_VERSION) to archive_clinvar_${CURRENT_VERSION}/"
    fi

    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz" \
        -n "${BLOB_PREFIX}/clinvar_current.vcf.gz" --overwrite
    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f "recent_${DATESTAMP}_to_test/clinvar_subset.vcf.gz.tbi" \
        -n "${BLOB_PREFIX}/clinvar_current.vcf.gz.tbi" --overwrite
    echo "$DATESTAMP" > current_version.txt
    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f current_version.txt -n "${BLOB_PREFIX}/clinvar_current_version.txt" --overwrite

    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f report/summary.md \
        -n "${BLOB_PREFIX}/reports/clinvar_refresh_${DATESTAMP}.md" --overwrite

    echo "Done. clinvar_current.vcf.gz now holds the $DATESTAMP release."
else
    echo "FAILED."
    [[ "$DIFF_PASSED" == "0" ]] && echo "  - Diff ${PCT_CHANGE}% >= ${THRESHOLD_PCT}% threshold -- needs human review."
    [[ "$E2E_PASSED" == "0" ]] && echo "  - E2E annotation check failed -- see report/e2e_error.log."
    echo "current/ is untouched. recent_${DATESTAMP}_to_test/ and report/ are"
    echo "left in $(pwd) for review. Nothing was archived or promoted."
    exit 1
fi
