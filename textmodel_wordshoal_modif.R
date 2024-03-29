
# Modified Wordshoal function 
# Saving word loadings (kappa_ij) and tuning the Bayesian aggregation priors

textmodel_wordshoal_modif <- function(x, groups, authors, dir = c(1,2), tol = 1e-3,
                                      prioralpha = 0.5,
                                      priorbeta  = 0.5,
                                      priortheta = 1,
                                      priortau = 1) {
  UseMethod("textmodel_wordshoal")
}

#' @export
textmodel_wordshoal.dfm <- function(x, groups, authors, dir = c(1,2), tol = 1e-3,
                                    prioralpha = 0.5,
                                    priorbeta  = 0.5,
                                    priortheta = 1,
                                    priortau = 1) {
  
  startTime <- proc.time()
  
  x <- quanteda::as.dfm(x)
  groups <- as.factor(groups)
  authors <- as.factor(authors)
  
  # check that no groups or author partitions are a single row
  if (length(not_enough_rows <- which(lengths(split(quanteda::docnames(x), groups)) < 2)))
    stop("only a single case for the following groups: \n", 
         paste(levels(groups)[not_enough_rows], collapse = "\n"))
  # if (length(not_enough_rows <- which(lengths(split(quanteda::docnames(x), authors)) < 2)))
  #     stop("only a single case for the following authors: \n", 
  #          paste(levels(authors)[not_enough_rows], collapse = "\n"))
  
  S <- quanteda::ndoc(x)
  psi <- rep(NA, S)
  
  N <- nlevels(authors)
  M <- nlevels(groups)
  kappa <- vector("list", length = M)
  
  
  ## FIRST-LEVEL SCALING ##
  
  cat("\nScaling ", M, " document groups", sep="")
  for (j in 1:M) {
    
    # Extract dfm rows for current document group
    groupdfm <- x[groups == levels(groups)[j], ]
    
    # Remove features that do not appear XX_in at leastone document_XX at least twice 
    groupdfm <- quanteda::dfm_trim(groupdfm, min_docfreq = 1)
    
    # Run wordfish on document group
    # wfresult <- wordfishcpp(as.matrix(groupdfm), c(1, 2), c(0, 0, 1/9, 1), c(1e-2, 1e-4), 1L, 0L)
    wfresult <- textmodel_wordfish(groupdfm, tol = c(tol, 1e-8))
    
    # Save the results
    psi[groups == levels(groups)[j]] <- 
      if(isS4(wfresult)){ wfresult@theta } else { wfresult$theta }
    
    if (j %% 20 == 0) 
      cat(j, " ", sep="") 
    else 
      cat(".")
    
    kappa[[j]]$features <- wfresult$features
    kappa[[j]]$beta <- wfresult$beta
  }
  
  ## SECOND-LEVEL SCALING ##
  
  cat("\nFactor Analysis on Debate-Level Scales")	
  
  psi <- replace(psi,is.na(psi),0) # debates that failed to scale
  jVec <- as.integer(groups)
  iVec <- as.integer(authors)
  
  ## Factor Analysis on Debate Score Matrix ##
  
  # prioralpha <- 0.5
  # priorbeta <- 0.5
  # priortheta <- 1
  # priortau <- 1
  
  # Dumb (but deterministic!) initial values
  
  alpha <- rep(0,M)
  beta <- rep(0,M)
  theta <- seq(-2,2,length.out=N)
  tau <- rep(1,N)
  
  # Calculate initial log-posterior...
  
  lastlp <- -Inf
  lp <- sum(dnorm(alpha,0,prioralpha,log=TRUE))
  lp <- lp + sum(dnorm(beta,0,priorbeta,log=TRUE))
  lp <- lp + sum(dnorm(theta,0,priortheta,log=TRUE))
  lp <- lp + sum(dgamma(tau,1,1,log=TRUE))
  for (s in 1:S) {
    lps <- alpha[jVec[s]] + beta[jVec[s]] * theta[iVec[s]]
    lp <- lp + dnorm(psi[s], lps, (tau[iVec[s]])^(-1/2), log=TRUE)
  }
  
  # Until log-posterior stops changing...
  
  while((lp - lastlp) > abs(tol)){	
    
    cat(".")
    
    # Update debate parameters
    
    priordebate <- solve(matrix(c(prioralpha^2,0,0,priorbeta^2),2,2)) 
    
    for (j in 1:M){
      locs <- which(jVec == j)
      Ytmp <- psi[locs]
      Xtmp <- cbind(1,theta[iVec[locs]])
      Wtmp <- diag(tau[iVec[locs]])
      coeftmp <- solve(t(Xtmp) %*% Wtmp %*% Xtmp + priordebate) %*% t(Xtmp) %*% Wtmp %*% Ytmp
      alpha[j] <- coeftmp[1]
      beta[j] <- coeftmp[2] 
    }
    
    # Update speaker parameters
    
    for (i in 1:N){
      locs <- which(iVec == i)
      Ytmp <- matrix(psi[locs] - alpha[jVec[locs]],ncol=1)
      Xtmp <- matrix(beta[jVec[locs]],ncol=1)
      coeftmp <- solve(t(Xtmp) %*% Xtmp + priortheta^(-2)) %*% t(Xtmp) %*% Ytmp
      theta[i] <- coeftmp[1,1]
      mutmp <- solve(t(Xtmp) %*% Xtmp + priortheta^(-2)) %*% t(Xtmp) %*% Xtmp %*% coeftmp
      tau[i] <- (priortau + 0.5 * length(Ytmp)) / 
        (priortau + 0.5 * (sum(Ytmp^2) - mutmp*(priortheta^(-2)) * mutmp))
    }
    
    # Recalculate log-posterior
    
    lastlp <- lp
    lp <- sum(dnorm(alpha,0,prioralpha, log = TRUE))
    lp <- lp + sum(dnorm(beta, 0, priorbeta, log = TRUE))
    lp <- lp + sum(dnorm(theta, 0, priortheta, log = TRUE))
    lp <- lp + sum(dgamma(tau, priortau, priortau, log = TRUE))
    for (s in 1:S){
      lps <- alpha[jVec[s]] + beta[jVec[s]] * theta[iVec[s]]
      lp <- lp + dnorm(psi[s], lps, (tau[iVec[s]])^(-1/2), log = TRUE)
    }  
    
  } # end while  
  
  ## Calculate standard errors for thetas
  
  thetaSE <- rep(NA,N)
  for (i in 1:N){
    locs <- which(iVec == i)
    Xtmp <- matrix(beta[jVec[locs]],ncol=1)
    thetaSE[i] <- sqrt(solve(t(Xtmp) %*% Xtmp + priortheta^(-2)) / tau[i])
  }
  
  ## Return results 
  
  cat("\nElapsed time:", (proc.time() - startTime)[3], "seconds.\n")
  
  result <- list(
    tol = tol,
    authors = authors,
    groups = groups,
    theta = theta,
    beta = beta,
    alpha = alpha,
    psi = psi,
    se.theta = thetaSE,
    call = match.call(),
    kappa = kappa
  )
  
  class(result) <- c("textmodel_wordshoal", "textmodel", "list")
  result
  
}


# base R methods -----------

#' Print method for textmodel_wordshoal
#' 
#' Provides a print method for this class of object.
#' @param x for print method, the object to be printed
#' @param ... additional arguments passed to \code{\link{print}}
#' @method print textmodel_wordshoal
#' @keywords internal
#' @export
print.textmodel_wordshoal <- function(x, ...) {
  #cat("Fitted wordshoal model:\n")
  cat("Call:\n\t")
  print(x$call)
  cat("\n",
      length(unique(x$authors)), " authors; ",
      length(unique(x$groups)), " groups.",
      "\n",
      sep = "")
  # cat("\nEstimated author positions:\n\n")
  # results <- data.frame(theta = x$theta,
  #                       SE = x$se.theta,
  #                       lower = x$theta - 1.96*x$se.theta,
  #                       upper = x$theta + 1.96*x$se.theta)
  # rownames(results) <- levels(x$authors)
  # print(results,...)
}

# setMethod("show", signature(object = "textmodel_wordshoal_fitted"), 
#           function(object) print(object))
# 
# setMethod("show", signature(object = "textmodel_wordshoal_predicted"), 
#           function(object) print(object))


#' Summarize a fitted textmodel_wordshoal object.
#' 
#' \code{summary} method for a fitted \code{\link{textmodel_wordshoal}} object.
#' @param object results of \code{\link{textmodel_wordshoal}} to be summarized
#' @param ... additional arguments passed to \code{print}
#' @export
#' @method summary textmodel_wordshoal
summary.textmodel_wordshoal <- function(object, ...) {
  # cat("Call:\n\t")
  # print(object$call)
  # 
  # cat("\nEstimated document positions:\n")
  stat <- data.frame(
    theta = object$theta,
    se = object$se.theta,
    row.names = levels(object$authors),
    check.rows = FALSE,
    stringsAsFactors = FALSE
  )
  # results <- data.frame(theta = object$theta,
  #                       SE = object$se.theta,
  #                       lower = object$theta - 1.96*object$se.theta,
  #                       upper = object$theta + 1.96*object$se.theta)
  # 
  # rownames(results) <- levels(object$authors)
  result <- list(
    'call' = object$call,
    'estimated.author.positions' = as.statistics_textmodel(stat)#,
    #      'estimated.feature.scores' = as.coefficients_textmodel(head(coef(object)$features, n))
  )
  return(as.summary.textmodel(result))
  # print(results, ...)
  # invisible(results)
}