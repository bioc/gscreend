# This method is adapted from Li et al. and others. But I have
# to write it from scratch because there is no available R package
# on CRAN or Bioconductor

# helper functions, according to definition in Li et al.
# probability needs to be transformed by beta distribution

alphaBeta <- function(p_test) {
    p_test <- sort(p_test)
    n <- length(p_test)
    min(stats::pbeta(p_test, seq_len(n), n - seq_len(n) + 1))
}

# calculate rho value
makeRhoNull <- function(n, p, nperm) {
    # if perm_genes = 10 we want to split the permutations into 5 processes
    n_processes <- 4
    rhonull <- BiocParallel::bplapply(seq_len(n_processes),
            function(x) { vapply(seq_len(nperm/n_processes), function(x) {alphaBeta(sample(p, n, replace = FALSE))},
                FUN.VALUE = numeric(1)) }
        )
   unlist(rhonull)
}


calculateGenePval <- function(pvals, genes, alpha_cutoff,
    # permutations = perm_genes * genes
    perm_genes = 8) {
    cut.pvals <- pvals <= alpha_cutoff
    # ranking and scoring according to pvalues
    score_vals <- rank(pvals)/length(pvals)
    score_vals[!cut.pvals] <- as.numeric(1)

    # calculate rho for every count gene

    rho <- unsplit(vapply(split(score_vals, genes),
                                FUN = alphaBeta,
                                FUN.VALUE = numeric(1)),
                                genes)

    guides_per_gene <- sort(unique(table(genes)))

    # store this as model parameter
    permutations <- perm_genes * nrow(unique(genes))

    # this does not need to be parallelized because its calling
    # a function that is already serialized

    # this is the step that takes longest to complete
    rho_nullh <- vapply(guides_per_gene,
                        FUN = makeRhoNull,
                        p = score_vals,
                        nperm = permutations,
                        FUN.VALUE = numeric(permutations))

    # Split by gene, make comparison with null model
    # from makeRhoNull, and unsplit by gene

    # this is faster than using the Bioc::Parallel option
    pvalue_gene <- vapply(split(rho, genes), function(x) {
        n_sgrnas = length(x)
        mean(rho_nullh[, guides_per_gene == n_sgrnas] <= x[[1]])
    }, FUN.VALUE = numeric(1))


    pvalue_gene
}


calculateGeneLFC <- function(lfcs_sgRNAs, genes) {
    # Gena LFC : mean LFC of sgRNAs
    vapply(split(lfcs_sgRNAs, genes), FUN = mean, FUN.VALUE = numeric(1))
}

#' Calculate gene rank
#'
#' @param object PoolScreenExp object
#' @param alpha_cutoff alpha cutoff for alpha-RRA (default: 0.05)
#'
#' @return object
#' @keywords internal

assignGeneData <- function(object, alpha_cutoff) {
    message("Ranking genes...")
    # p-values for neg LFC were calculated from model
    pvals_neg <- samplepval(object)
    # p-values for pos LFC: 1 - neg.pval
    pvals_pos <- 1 - samplepval(object)

    # genes (append gene list as many times as replicates)
    n_repl <- dim(pvals_neg)[2]
    genes <- do.call("rbind", replicate(n_repl,
                        data.frame(gene = rowData(sgRNAData(object))$gene),
                        simplify = FALSE))

    # calculate pvalues
    message("... for positive fold changes")
    gene_pval_neg <- calculateGenePval(pvals_neg, genes, alpha_cutoff)
    message("... for negative fold changes")
    gene_pval_pos <- calculateGenePval(pvals_pos, genes, alpha_cutoff)

    # calculate fdrs from pvalues
    fdr_gene_neg <- stats::p.adjust(gene_pval_neg, method = "fdr")
    fdr_gene_pos <- stats::p.adjust(gene_pval_pos, method = "fdr")

    # calculate gene lfc
    lfcs_sgRNAs <- samplelfc(object)
    gene_lfc <- calculateGeneLFC(lfcs_sgRNAs, genes)

    # build new summarized experiment for the GeneData slot
    # assuming that gene order is same in neg and pos
    rowData <- data.frame(gene = names(gene_pval_neg))
    colData <- data.frame(samplename = c("T1"), timepoint = c("T1"))

    # build a summarized experiment that contains p values and fdrs
    GeneData(object) <- SummarizedExperiment(
        assays = list(pvalue_neg = as.matrix(gene_pval_neg),
            fdr_neg = as.matrix(fdr_gene_neg),
            pvalue_pos = as.matrix(gene_pval_pos),
            fdr_pos = as.matrix(fdr_gene_pos),
            lfc = as.matrix(gene_lfc)),
        rowData = rowData, colData = colData)

    message("gscreend analysis has been completed.")
    object

}
