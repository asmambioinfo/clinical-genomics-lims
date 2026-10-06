#!/bin/bash
# scripts/refresh_gnomad_subset.sh
#
# Quarterly refresh of the gnomAD subset used by main.nf's ANNOTATE step.
# Downloads the latest gnomAD exomes release (or a version you specify),
# subsets it to your gene panel, diffs it against the current subset
# chr-by-chr on position + AF, and only promotes it to "current" if the
# change is under threshold. Otherwise it's left for human review.
#
# The pipeline-facing blob path never changes name (gnomad_current.vcf.gz)
# -- only its content changes after a successful refresh. Version is
# tracked separately in current_version.txt, not in the path itself, so
# nextflow.config never needs editing after a refresh.
#
# Usage:
#   ./refresh_gnomad_subset.sh --gene-bed /path/to/gene_bed.bed
#   ./refresh_gnomad_subset.sh --gene-bed /path/to/gene_bed.bed --version 4.1.2
#   ./refresh_gnomad_subset.sh --gene-bed /path/to/gene_bed.bed --threshold 0.05

set -euo pipefail

# ---------- defaults ----------
THRESHOLD_PCT="0.01"     # max allowed %% of positions changed to auto-pass
GENE_BED=""
VERSION=""                # empty = auto-detect latest available
BLOB_ACCOUNT="genomicsngs"
BLOB_CONTAINER="reference-data"
BLOB_PREFIX="reference"
AF_EPSILON="0.000001"     # ignore AF differences smaller than this (float noise)
WORKDIR="./gnomad_refresh_$(date +%Y%m%d_%H%M%S)"

usage() {
    echo "Usage: $0 --gene-bed FILE [--version X.Y[.Z]] [--threshold PCT]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gene-bed)  GENE_BED="$2"; shift 2 ;;
        --version)   VERSION="$2"; shift 2 ;;
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

# ---------- 1. determine version ----------
# The bucket has some inconsistent folder naming (e.g. both "4.0/" and
# "v4.0/" exist for the same release), and not every listed version
# actually has a vcf/exomes/ folder (e.g. 4.1.2 only has constraint/ data
# as of this writing). This checks both naming forms and skips any
# version that doesn't actually have exomes VCFs, rather than assuming
# the newest-looking folder name is usable.
detect_latest_version() {
    local candidates
    candidates=$(aws s3 ls s3://gnomad-public-us-east-1/release/ --no-sign-request \
        | awk '{print $2}' | sed 's#/##' \
        | grep -E '^v?[0-9]+\.[0-9]+(\.[0-9]+)?$' \
        | sed 's/^v//' \
        | sort -t. -k1,1nr -k2,2nr -k3,3nr -u)

    local v
    for v in $candidates; do
        for prefix in "$v" "v$v"; do
            if aws s3 ls "s3://gnomad-public-us-east-1/release/${prefix}/vcf/exomes/" --no-sign-request 2>/dev/null | grep -q '\.vcf\.bgz$'; then
                echo "$v"
                return
            fi
        done
    done
    echo "Error: no version with vcf/exomes/ data found." >&2
    exit 1
}

if [[ -z "$VERSION" ]]; then
    echo "No --version given, detecting latest available release with exomes data..."
    VERSION=$(detect_latest_version)
fi
echo "Using gnomAD version: $VERSION"

# ---------- 2. chromosomes covered by the gene panel ----------
CHROMS=$(cut -f1 "$GENE_BED" | sort -u)
echo "Gene panel covers: $CHROMS"

# ---------- 3. build the "recent" subset for this version ----------
build_subset() {
    local outdir=$1
    mkdir -p "$outdir"
    local chr
    for chr in $CHROMS; do
        echo "  Pulling $chr..."
        bcftools view -R "$GENE_BED" \
            "https://gnomad-public-us-east-1.s3.amazonaws.com/release/${VERSION}/vcf/exomes/gnomad.exomes.v${VERSION}.sites.${chr}.vcf.bgz" \
            -Oz -o "$outdir/${chr}.vcf.gz"
        tabix -p vcf "$outdir/${chr}.vcf.gz"
    done
    bcftools concat "$outdir"/*.vcf.gz -Oz -o "$outdir/gnomad_subset.vcf.gz"
    tabix -p vcf "$outdir/gnomad_subset.vcf.gz"
}

echo "Building subset for version $VERSION..."
build_subset "recent_v${VERSION}_to_test"

# ---------- 4. pull the current subset from blob for comparison ----------
mkdir -p current
echo "Downloading current subset from blob for comparison..."
az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
    -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/gnomad_current.vcf.gz" -f current/gnomad_current.vcf.gz
az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
    -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/gnomad_current.vcf.gz.tbi" -f current/gnomad_current.vcf.gz.tbi
CURRENT_VERSION="unknown"
if az storage blob download --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
    -c "$BLOB_CONTAINER" -n "${BLOB_PREFIX}/current_version.txt" -f current/current_version.txt 2>/dev/null; then
    CURRENT_VERSION=$(cat current/current_version.txt)
fi
echo "Current blob version on record: $CURRENT_VERSION"

# ---------- 5. compare chr by chr on position + AF ----------
# bcftools isec's 0002.vcf and 0003.vcf hold the *same* shared sites, in
# the same order -- 0002 sourced from the current file, 0003 from the
# recent file -- so their AF columns can be pasted and diffed directly.
mkdir -p report
TOTAL_ADDED=0
TOTAL_DELETED=0
TOTAL_CHANGED=0
TOTAL_UNCHANGED=0

{
echo "# gnomAD subset refresh report"
echo ""
echo "Current version: $CURRENT_VERSION"
echo "New version: $VERSION"
echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""
echo "| Chrom | Added | Deleted | Changed AF | Unchanged |"
echo "|---|---|---|---|---|"
} > report/summary.md

for chr in $CHROMS; do
    current_chr="current/${chr}.vcf.gz"
    recent_chr="recent_v${VERSION}_to_test/${chr}.vcf.gz"

    # current subset may not have this chromosome at all yet (e.g. first run)
    if [[ ! -f "$current_chr" ]]; then
        bcftools view -r "$chr" current/gnomad_current.vcf.gz -Oz -o "$current_chr" 2>/dev/null || true
        [[ -f "$current_chr" ]] && tabix -p vcf "$current_chr"
    fi

    if [[ ! -f "$current_chr" ]]; then
        added=$(bcftools view -H "$recent_chr" | wc -l | tr -d ' ')
        deleted=0
        changed=0
        unchanged=0
    else
        isec_dir="isec_${chr}"
        bcftools isec -p "$isec_dir" -O z "$current_chr" "$recent_chr" >/dev/null

        added=$(zcat "$isec_dir/0001.vcf.gz" | grep -vc '^#' || true)
        deleted=$(zcat "$isec_dir/0000.vcf.gz" | grep -vc '^#' || true)

        if [[ -s "$isec_dir/0002.vcf.gz" ]]; then
            paste \
                <(bcftools query -f '%CHROM\t%POS\t%INFO/AF\n' "$isec_dir/0002.vcf.gz") \
                <(bcftools query -f '%INFO/AF\n' "$isec_dir/0003.vcf.gz") \
                > "$isec_dir/af_compare.tsv"
            changed=$(awk -v eps="$AF_EPSILON" '{diff=$3-$4; if (diff<0) diff=-diff; if (diff>eps) c++} END{print c+0}' "$isec_dir/af_compare.tsv")
            unchanged=$(awk -v eps="$AF_EPSILON" '{diff=$3-$4; if (diff<0) diff=-diff; if (diff<=eps) c++} END{print c+0}' "$isec_dir/af_compare.tsv")
        else
            changed=0
            unchanged=0
        fi
    fi

    echo "| $chr | $added | $deleted | $changed | $unchanged |" >> report/summary.md
    TOTAL_ADDED=$((TOTAL_ADDED + added))
    TOTAL_DELETED=$((TOTAL_DELETED + deleted))
    TOTAL_CHANGED=$((TOTAL_CHANGED + changed))
    TOTAL_UNCHANGED=$((TOTAL_UNCHANGED + unchanged))
done

TOTAL_POSITIONS=$((TOTAL_ADDED + TOTAL_DELETED + TOTAL_CHANGED + TOTAL_UNCHANGED))
TOTAL_DIFFERENT=$((TOTAL_ADDED + TOTAL_DELETED + TOTAL_CHANGED))

if [[ "$TOTAL_POSITIONS" -eq 0 ]]; then
    PCT_CHANGE="0"
else
    PCT_CHANGE=$(awk -v d="$TOTAL_DIFFERENT" -v t="$TOTAL_POSITIONS" 'BEGIN{printf "%.6f", (d/t)*100}')
fi

{
echo ""
echo "## Totals"
echo ""
echo "- Added: $TOTAL_ADDED"
echo "- Deleted: $TOTAL_DELETED"
echo "- Changed AF: $TOTAL_CHANGED"
echo "- Unchanged: $TOTAL_UNCHANGED"
echo "- Total positions compared: $TOTAL_POSITIONS"
echo "- Percent changed: ${PCT_CHANGE}%"
echo "- Threshold: ${THRESHOLD_PCT}%"
} >> report/summary.md

echo ""
cat report/summary.md
echo ""

# ---------- 6. pass/fail decision ----------
PASSED=$(awk -v pct="$PCT_CHANGE" -v thresh="$THRESHOLD_PCT" 'BEGIN{print (pct<thresh) ? "1" : "0"}')

if [[ "$PASSED" == "1" ]]; then
    echo "PASSED: ${PCT_CHANGE}% < ${THRESHOLD_PCT}% threshold. Archiving current and promoting new version."

    # Archive the current version under its own version-labeled folder,
    # but only now, having confirmed the new one is good -- never before.
    if [[ "$CURRENT_VERSION" != "unknown" ]]; then
        az storage blob copy start --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
            --destination-container "$BLOB_CONTAINER" \
            --destination-blob "${BLOB_PREFIX}/archive_v${CURRENT_VERSION}/gnomad_v${CURRENT_VERSION}.vcf.gz" \
            --source-container "$BLOB_CONTAINER" \
            --source-blob "${BLOB_PREFIX}/gnomad_current.vcf.gz"
        echo "Archived previous version ($CURRENT_VERSION) to archive_v${CURRENT_VERSION}/"
    fi

    # Promote: the stable "current" name gets overwritten with the new
    # content. nextflow.config's --gnomad_vcf path never changes.
    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f "recent_v${VERSION}_to_test/gnomad_subset.vcf.gz" \
        -n "${BLOB_PREFIX}/gnomad_current.vcf.gz" --overwrite
    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f "recent_v${VERSION}_to_test/gnomad_subset.vcf.gz.tbi" \
        -n "${BLOB_PREFIX}/gnomad_current.vcf.gz.tbi" --overwrite
    echo "$VERSION" > current_version.txt
    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f current_version.txt -n "${BLOB_PREFIX}/current_version.txt" --overwrite

    az storage blob upload --account-name "$BLOB_ACCOUNT" --auth-mode key --account-key "$STORAGE_KEY" \
        -c "$BLOB_CONTAINER" -f report/summary.md \
        -n "${BLOB_PREFIX}/reports/gnomad_refresh_${VERSION}_$(date +%Y%m%d).md" --overwrite

    echo "Done. gnomad_current.vcf.gz now holds version $VERSION."
else
    echo "FAILED: ${PCT_CHANGE}% >= ${THRESHOLD_PCT}% threshold."
    echo "Change is larger than expected -- this needs human review before promoting."
    echo "current/ is untouched. recent_v${VERSION}_to_test/ and report/summary.md are"
    echo "left in $(pwd) for review. Nothing was archived or promoted."
    exit 1
fi
