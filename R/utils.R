#' Generate long format hazards data for conditional density estimation
#'
#' @param A The \code{numeric} vector or similar of the observed values of an
#'  intervention for a group of observational units of interest.
#' @param W A \code{data.frame}, \code{matrix}, or similar giving the values of
#'  baseline covariates (potential confounders) for the observed units whose
#'  observed intervention values are provided in the previous argument.
#' @param wts A \code{numeric} vector of observation-level weights. The default
#'  is to weight all observations equally.
#' @param type A \code{character} indicating the strategy to be used in creating
#'  bins along the observed support of the intervention \code{A}. For bins of
#'  equal range, use "equal_range" and consider consulting the documentation of
#'  \code{ggplot2::cut_interval} for more information. To ensure each bins has
#'  the same number of points, use "equal_mass" and consult the documentation of
#'  \code{ggplot2::cut_number} for details.
#' @param n_bins Only used if \code{type} is set to \code{"equal_range"} or
#'  \code{"equal_mass"}. This \code{numeric} value indicates the number of bins
#'  that the support of the intervention \code{A} is to be divided into.
#' @param breaks A \code{numeric} vector of break points to be used in dividing
#'  up the support of \code{A}. This is passed as a \code{...} argument to
#'  \code{base::cut.default} by either \code{cut_interval} or \code{cut_number}.
#'
#' @importFrom data.table as.data.table setnames
#' @importFrom ggplot2 cut_interval cut_number
#' @importFrom future.apply future_lapply
#' @importFrom assertthat assert_that
#
format_long_hazards <- function(A, W, wts = rep(1, length(A)),
                                type = c(
                                  "equal_range", "equal_mass"
                                ),
                                n_bins = NULL, breaks = NULL) {
  # clean up arguments
  type <- match.arg(type)

  # set grid along A and find interval membership of observations along grid
  if (is.null(breaks) & !is.null(n_bins)) {
    if (type == "equal_range") {
      bins <- ggplot2::cut_interval(A, n_bins,
        right = FALSE,
        ordered_result = TRUE, dig.lab = 12
      )
    } else if (type == "equal_mass") {
      bins <- ggplot2::cut_number(A, n_bins,
        right = FALSE,
        ordered_result = TRUE, dig.lab = 12
      )
    }
    # https://stackoverflow.com/questions/36581075/extract-the-breakpoints-from-cut
    breaks_left <- as.numeric(sub(".(.+),.+", "\\1", levels(bins)))
    breaks_right <- as.numeric(sub(".+,(.+).", "\\1", levels(bins)))
    bin_length <- round(breaks_right - breaks_left, 3)
    bin_id <- as.numeric(bins)
    all_bins <- matrix(seq_along(bin_id), ncol = 1)
    # for predict method, only need to assign observations to existing intervals
  } else if (!is.null(breaks)) {
    # NOTE: findInterval() and cut() might return slightly different results...
    bin_id <- findInterval(A, breaks, all.inside = TRUE)
    all_bins <- matrix(seq_along(breaks), ncol = 1)
  } else {
    stop("Combination of arguments `breaks`, `n_bins` incorrectly specified.")
  }


  
  # loop over observations to create expanded set of records for each
  reformat_each_obs <- future.apply::future_lapply(seq_along(A), function(i) {
    # create indicator and "turn on" indicator for interval membership
    bin_indicator <- rep(0, nrow(all_bins))
    bin_indicator[bin_id[i]] <- 1
    id <- rep(i, nrow(all_bins))

    # get correct value of baseline variables and repeat along intervals
    if (is.null(dim(W))) {
      # assume vector
      obs_w <- rep(W[i], nrow(all_bins))
      names_w <- "W"
    } else {
      # assume two-dimensional array
      obs_w <- rep(as.numeric(W[i, ]), nrow(all_bins))
      obs_w <- matrix(obs_w, ncol = ncol(W), byrow = TRUE)

      # use names from array if present
      if (is.null(names(W))) {
        names_w <- paste("W", seq_len(ncol(W)), sep = "_")
      } else {
        names_w <- names(W)
      }
    }

    # get correct value of weights and repeat along intervals
    # NOTE: the weights are always a vector
    obs_wts <- rep(wts[i], nrow(all_bins))

    # create data table with membership indicator and interval limits
    suppressWarnings(
      hazards_df <- data.table::as.data.table(cbind(
        id, bin_indicator,
        all_bins, obs_w,
        obs_wts
      ))
    )

    # trim records to simply end at the failure time for a given observation
    hazards_df_reduced <- hazards_df[seq_len(bin_id[i]), ]

    # give explicit names and add to appropriate position in list
    hazards_df <-
      data.table::setnames(
        hazards_df_reduced,
        c("obs_id", "in_bin", "bin_id", names_w, "wts")
      )
    return(hazards_df)
  })

  # combine observation-level hazards data into larger structure
  reformatted_data <- do.call(rbind, reformat_each_obs)
  out <- list(
    data = reformatted_data,
    breaks =
      if (exists("breaks_left")) {
        breaks_left
      } else {
        NULL
      },
    bin_length =
      if (exists("bin_length")) {
        bin_length
      } else {
        NULL
      }
  )
  return(out)
}

################################################################################

#' Map a predicted hazard to a predicted density for a single observation
#'
#' For a single observation, map a predicted hazard of failure (occurrence in a
#' particular bin, under a given partitioning of the support) to a density.
#'
#' @param hazard_pred_single_obs A \code{numeric} vector of the predicted hazard
#'  of failure in a given bin (under a given partitioning of the support) for a
#'  single observational unit based on a long format data structure (as produced
#'  by \code{\link{format_long_hazards}}). This is simply the probability that
#'  the observed value falls in a corresponding bin, given that it has not yet
#'  failed (fallen in a previous bin), as given in
#'  \insertRef{diaz2011super}{haldensify}.
#'
#' @importFrom assertthat assert_that
#
map_hazard_to_density <- function(hazard_pred_single_obs) {
  # number of records for the given observation
  n_records <- nrow(hazard_pred_single_obs)

  # NOTE: pred_hazard = (1 - pred) if 0 in this bin * pred if 1 in this bin
  if (n_records > 1) {
    hazard_prefailure <- matrix(1 - hazard_pred_single_obs[-n_records, ],
      nrow = (n_records - 1)
    )
    hazard_at_failure <- hazard_pred_single_obs[n_records, ]
    hazard_predicted <- rbind(hazard_prefailure, hazard_at_failure)
    rownames(hazard_predicted) <- NULL
  } else {
    hazard_predicted <- hazard_pred_single_obs
  }

  # sanity check of dimensions
  assertthat::assert_that(all(dim(hazard_pred_single_obs) ==
    dim(hazard_predicted)))

  # multiply hazards across rows to construct the individual-level density
  density_pred_from_hazards <- matrix(apply(hazard_predicted, 2, prod),
    nrow = 1
  )
  return(density_pred_from_hazards)
}
