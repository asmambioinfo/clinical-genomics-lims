#!/usr/bin/env nextflow
/*
 * nextflow-run/main.nf
 *
 * DSL2 port of the MedEx clinical NGS pipeline (ported from medex_process.txt).
 * Each external tool runs in its own Docker container -- see
 * nextflow.config for image/version pinning, matched to the versions
 * documented in the original script's own comments.
 */

nextflow.enable.dsl = 2

params.fastq_dir      = null
params.outdir         = 'results'
params.genome         = null
params.genome_dict    = null
params.gene_bed       = null
params.gene_panel_bed = null
params.clinvar_vcf    = null   // bgzipped + tabix-indexed ClinVar VCF
params.gnomad_vcf     = null   // bgzipped + tabix-indexed gnomAD VCF (population AF)
params.min_freq       = 0.01   // variants at or above this gnomAD AF are filtered out

if (!params.fastq_dir || !params.genome || !params.genome_dict || !params.gene_bed || !params.gene_panel_bed || !params.clinvar_vcf || !params.gnomad_vcf) {
    error "Missing required params. See nextflow.config for the full list (fastq_dir, genome, genome_dict, gene_bed, gene_panel_bed, clinvar_vcf, gnomad_vcf)."
}

workflow {

    // The original bash script looped over one sample's fastq pair at a
    // time; Nextflow parallelizes this automatically across samples.
    read_pairs_ch = Channel
        .fromFilePairs("${params.fastq_dir}/*_R{1,2}_001.fastq.gz")
        .map { sample, reads -> tuple(sample, reads[0], reads[1]) }

    clinvar_ch      = file(params.clinvar_vcf)
    clinvar_idx_ch  = file("${params.clinvar_vcf}.tbi")
    gnomad_ch       = file(params.gnomad_vcf)
    gnomad_idx_ch   = file("${params.gnomad_vcf}.tbi")

    genome_ch          = file(params.genome)
    // bwa/samtools/gatk index files (.amb/.ann/.bwt/.pac/.sa/.fai) are
    // expected to sit alongside the fasta with matching prefix, same as
    // the original script assumed.
    genome_index_ch     = file("${params.genome}.*")
    dict_ch             = file(params.genome_dict)
    gene_bed_ch          = file(params.gene_bed)
    panel_bed_ch         = file(params.gene_panel_bed)

    // Step 2: adapter trimming
    FASTP(read_pairs_ch)

    // Step 3: alignment
    BWA_MEM(FASTP.out.trimmed, genome_ch, genome_index_ch)

    // Step 4: convert / sort / index
    PICARD_SORT_INITIAL(BWA_MEM.out.sam)

    // Step 5: indel realignment, then sort / index
    ABRA2(PICARD_SORT_INITIAL.out.bam, genome_ch, genome_index_ch, gene_bed_ch)
    PICARD_SORT_ABRA(ABRA2.out.bam)

    // Step 6: mark/remove duplicates, then sort / index
    MARK_DUPLICATES(PICARD_SORT_ABRA.out.bam)
    PICARD_SORT_DEDUP(MARK_DUPLICATES.out.bam)

    // Equivalent of the original "*.picard.rdups.bam" -- the analysis-ready bam
    final_bam_ch = PICARD_SORT_DEDUP.out.bam

    // Step 7: subset bam for IGV viewing (side output; doesn't feed variant calling)
    SUBSET_BAM(final_bam_ch, panel_bed_ch)

    // Step 8a: HaplotypeCaller
    HAPLOTYPECALLER(final_bam_ch, genome_ch, genome_index_ch, dict_ch, gene_bed_ch)

    // Step 8b: VarScan. The original pipes samtools mpileup directly into
    // varscan; split into two single-tool processes here so each keeps its
    // own container rather than needing one image with both tools installed.
    SAMTOOLS_MPILEUP(final_bam_ch, genome_ch, genome_index_ch, gene_bed_ch)
    VARSCAN_CALL(SAMTOOLS_MPILEUP.out.pileup)

    // Step 9: consensus -- keep only calls both GATK and VarScan agree on.
    // .join() pairs up the two channels by sample name automatically.
    consensus_input_ch = HAPLOTYPECALLER.out.join(VARSCAN_CALL.out)
    CONSENSUS_VCF(consensus_input_ch)

    // Step 10: annotate with ClinVar (clinical significance) and gnomAD
    // (population frequency), then drop anything at or above min_freq.
    ANNOTATE(CONSENSUS_VCF.out.vcf, clinvar_ch, clinvar_idx_ch, gnomad_ch, gnomad_idx_ch)
    FREQ_FILTER(ANNOTATE.out.vcf)
}

process FASTP {
    tag "$sample"
    publishDir "${params.outdir}/trimmed", mode: 'copy', pattern: '*.{html,json}'

    input:
    tuple val(sample), path(r1), path(r2)

    output:
    tuple val(sample), path("${sample}_R1_001_trimmed.fastq.gz"), path("${sample}_R2_001_trimmed.fastq.gz"), emit: trimmed
    tuple path("${sample}.html"), path("${sample}.json"), emit: report

    script:
    """
    fastp -h ${sample}.html -j ${sample}.json -w ${task.cpus} -l 25 \
        -i $r1 -I $r2 \
        -o ${sample}_R1_001_trimmed.fastq.gz -O ${sample}_R2_001_trimmed.fastq.gz
    """
}

process BWA_MEM {
    tag "$sample"

    input:
    tuple val(sample), path(r1), path(r2)
    path genome
    path genome_index

    output:
    tuple val(sample), path("${sample}.sam"), emit: sam

    script:
    """
    bwa mem -aM -R "@RG\\tID:${sample}\\tSM:${sample}\\tPL:ILLUMINA\\tPI:330" \
        -t ${task.cpus} $genome $r1 $r2 > ${sample}.sam
    """
}

process PICARD_SORT_INITIAL {
    tag "$sample"

    input:
    tuple val(sample), path(sam)

    output:
    tuple val(sample), path("${sample}.trim.align.sort.index.bam"), path("${sample}.trim.align.sort.index.bai"), emit: bam

    script:
    """
    picard SortSam I=$sam O=${sample}.trim.align.sort.index.bam \
        SORT_ORDER=coordinate CREATE_INDEX=true
    """
}

process ABRA2 {
    tag "$sample"

    input:
    tuple val(sample), path(bam), path(bai)
    path genome
    path genome_index
    path gene_bed

    output:
    tuple val(sample), path("${sample}.trim.align.sort.index.abra.pre.bam"), emit: bam

    script:
    """
    abra2 --in $bam --out ${sample}.trim.align.sort.index.abra.pre.bam \
        --ref $genome --threads ${task.cpus} --mer .10 --targets $gene_bed
    """
}

process PICARD_SORT_ABRA {
    tag "$sample"

    input:
    tuple val(sample), path(bam)

    output:
    tuple val(sample), path("${sample}.trim.align.sort.index.abra.bam"), path("${sample}.trim.align.sort.index.abra.bai"), emit: bam

    script:
    """
    picard SortSam I=$bam O=${sample}.trim.align.sort.index.abra.bam \
        SORT_ORDER=coordinate CREATE_INDEX=true
    """
}

process MARK_DUPLICATES {
    tag "$sample"
    publishDir "${params.outdir}/qc", mode: 'copy', pattern: '*.metrics.txt'

    input:
    tuple val(sample), path(bam), path(bai)

    output:
    tuple val(sample), path("${sample}.trim.align.sort.index.abra.rdups.bam"), emit: bam
    path "${sample}.trim.align.sort.index.abra.rdups.metrics.txt", emit: metrics

    script:
    """
    picard MarkDuplicates REMOVE_DUPLICATES=true \
        I=$bam O=${sample}.trim.align.sort.index.abra.rdups.bam \
        M=${sample}.trim.align.sort.index.abra.rdups.metrics.txt
    """
}

process PICARD_SORT_DEDUP {
    tag "$sample"
    publishDir "${params.outdir}/bam", mode: 'copy'

    input:
    tuple val(sample), path(bam)

    output:
    tuple val(sample), path("${sample}.trim.align.sort.index.abra.picard.rdups.bam"), path("${sample}.trim.align.sort.index.abra.picard.rdups.bai"), emit: bam

    script:
    """
    picard SortSam I=$bam O=${sample}.trim.align.sort.index.abra.picard.rdups.bam \
        SORT_ORDER=coordinate CREATE_INDEX=true
    """
}

process SUBSET_BAM {
    tag "$sample"
    publishDir "${params.outdir}/igv", mode: 'copy'

    input:
    tuple val(sample), path(bam), path(bai)
    path panel_bed

    output:
    tuple path("${sample}.trim.align.sort.index.abra.picard.rdups.eplcom.subset.bam"), path("${sample}.trim.align.sort.index.abra.picard.rdups.eplcom.subset.bam.bai")

    script:
    """
    samtools view -L $panel_bed -b $bam > ${sample}.trim.align.sort.index.abra.picard.rdups.eplcom.subset.bam
    samtools index ${sample}.trim.align.sort.index.abra.picard.rdups.eplcom.subset.bam
    """
}

process HAPLOTYPECALLER {
    tag "$sample"
    publishDir "${params.outdir}/vcf/gatk", mode: 'copy'

    input:
    tuple val(sample), path(bam), path(bai)
    path genome
    path genome_index
    path dict
    path gene_bed

    output:
    tuple val(sample), path("${sample}.gatk.fullgene.vcf.gz")

    script:
    """
    gatk --java-options "-Xmx${task.memory.toGiga()}g" HaplotypeCaller \
        -R $genome -I $bam -L $gene_bed -mbq 13 \
        --native-pair-hmm-threads ${task.cpus} --min-pruning 4 \
        --sequence-dictionary $dict \
        -O ${sample}.gatk.fullgene.vcf.gz
    """
}

process SAMTOOLS_MPILEUP {
    tag "$sample"

    input:
    tuple val(sample), path(bam), path(bai)
    path genome
    path genome_index
    path gene_bed

    output:
    tuple val(sample), path("${sample}.mpileup"), emit: pileup

    script:
    """
    samtools mpileup -Q 13 -q 1 -B -l $gene_bed -f $genome $bam > ${sample}.mpileup
    """
}

process VARSCAN_CALL {
    tag "$sample"
    publishDir "${params.outdir}/vcf/varscan", mode: 'copy'

    input:
    tuple val(sample), path(pileup)

    output:
    tuple val(sample), path("${sample}.varscan.fullgene.vcf")

    script:
    """
    varscan mpileup2cns $pileup --output-vcf 1 --strand-filter 0 \
        --min-var-freq 0.10 --min-coverage 20 --variants > ${sample}.varscan.fullgene.vcf
    """
}

process CONSENSUS_VCF {
    tag "$sample"
    publishDir "${params.outdir}/vcf/consensus", mode: 'copy'

    input:
    tuple val(sample), path(gatk_vcf), path(varscan_vcf)

    output:
    tuple val(sample), path("${sample}.consensus.vcf.gz"), emit: vcf

    script:
    // GATK's output is already bgzipped; VarScan's plain .vcf needs
    // bgzip + an index before bcftools isec can compare the two.
    // isec's 0002.vcf holds records from gatk_vcf that also appear in
    // varscan_vcf -- i.e. the calls both callers agree on.
    """
    tabix -f -p vcf $gatk_vcf
    bgzip -c $varscan_vcf > varscan.vcf.gz
    tabix -p vcf varscan.vcf.gz
    bcftools isec -p isec_out -O z $gatk_vcf varscan.vcf.gz
    mv isec_out/0002.vcf.gz ${sample}.consensus.vcf.gz
    """
}

process ANNOTATE {
    tag "$sample"
    publishDir "${params.outdir}/vcf/annotated", mode: 'copy'

    input:
    tuple val(sample), path(vcf)
    path clinvar_vcf
    path clinvar_idx
    path gnomad_vcf
    path gnomad_idx

    output:
    tuple val(sample), path("${sample}.annotated.vcf.gz"), emit: vcf

    script:
    // Two-pass bcftools annotate: pull CLNSIG/CLNDN from ClinVar, then AF
    // from gnomAD. bcftools annotate is used instead of a full VEP setup
    // here since it needs no cache download -- worth upgrading to VEP
    // later if richer annotation (consequence, gene impact, etc.) is needed.
    """
    tabix -f -p vcf $vcf
    bcftools annotate -a $clinvar_vcf -c INFO/CLNSIG,INFO/CLNDN -O z -o step1.vcf.gz $vcf
    tabix -p vcf step1.vcf.gz
    bcftools annotate -a $gnomad_vcf -c INFO/AF -O z -o ${sample}.annotated.vcf.gz step1.vcf.gz
    """
}

process FREQ_FILTER {
    tag "$sample"
    publishDir "${params.outdir}/vcf/final", mode: 'copy'

    input:
    tuple val(sample), path(vcf)

    output:
    tuple val(sample), path("${sample}.final.vcf.gz")

    script:
    // Drops anything at or above min_freq in gnomAD -- keeps rarer,
    // more clinically interesting variants; common polymorphisms are cut.
    """
    tabix -f -p vcf $vcf
    bcftools view -e 'INFO/AF>=${params.min_freq}' -O z -o ${sample}.final.vcf.gz $vcf
    """
}
