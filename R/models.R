# elipsis passed to ranger
build_model <- function(views, target, seed = 42, cv.folds = 10, cached = TRUE, ...) {
  set.seed(seed)

  cache.location <- paste0(
    ".misty.temp", .Platform$file.sep,
    views[["misty.uniqueid"]]
  )

  if (!dir.exists(cache.location)) {
    dir.create(cache.location, recursive = TRUE, showWarnings = TRUE)
  }

  expr <- views[["intraview"]][["data"]]

  target.vector <- expr %>% dplyr::pull(target)


  # merge ellipsis with default algorithm arguments
  algo.arguments <- list(
    num.trees = 100, importance = "impurity",
    verbose = FALSE, num.threads = 1, seed = seed,
    dependent.variable.name = target
  )

  if (!length(list(...)) == 0) {
    algo.arguments <- rlist::list.merge(algo.arguments, list(...))
  }

  # returns a list of models
  model.views <- views %>%
    rlist::list.remove(c("misty.uniqueid")) %>%
    purrr::map(function(view) {
      model.view.cache.file <-
        paste0(
          cache.location, .Platform$file.sep,
          "model.", view[["abbrev"]], ".", target, ".rds"
        )

      if (file.exists(model.view.cache.file) & cached) {
        model.view <- readr::read_rds(model.view.cache.file)
      } else {
        model.view <- do.call(
          ranger::ranger,
          c(
            list(data = (view[["data"]] %>%
              dplyr::mutate(!!target := target.vector))),
            algo.arguments
          )
        )
        if (cached) {
          readr::write_rds(model.view, model.view.cache.file)
        }
      }

      return(model.view)
    })

  # make oob predictions
  oob.predictions <- model.views %>%
    purrr::map(~ .x$predictions) %>%
    rlist::list.cbind() %>%
    tibble::as_tibble() %>%
    dplyr::mutate(!!target := target.vector)

  # train lm on above
  combined.views <- stats::lm(stats::as.formula(paste0(target, "~.")), oob.predictions)

  # cv performance estimate
  test.folds <- caret::createFolds(target.vector, k = cv.folds)

  intra.view.only <- 
    model.views[["intraview"]]$predictions %>%
    tibble::enframe(name = NULL) %>%
    dplyr::mutate(!!target := target.vector)

  performance.estimate <- test.folds %>% purrr::map_dfr(function(test.fold) {
    meta.intra <- stats::lm(
      stats::as.formula(paste0(target, "~.")),
      intra.view.only %>% dplyr::slice(-test.fold)
    )
    meta.multi <- stats::lm(
      stats::as.formula(paste0(target, "~.")),
      oob.predictions %>% dplyr::slice(-test.fold)
    )

    intra.prediction <- stats::predict(meta.intra, intra.view.only %>%
      dplyr::slice(test.fold))
    multi.view.prediction <- stats::predict(meta.multi, oob.predictions %>%
      dplyr::slice(test.fold))

    intra.RMSE <- caret::RMSE(intra.prediction, target.vector[test.fold])
    intra.R2 <- caret::R2(intra.prediction, target.vector[test.fold],
      formula = "traditional"
    )

    multi.RMSE <- caret::RMSE(multi.view.prediction, target.vector[test.fold])
    multi.R2 <- caret::R2(multi.view.prediction, target.vector[test.fold],
      formula = "traditional"
    )

    tibble::tibble(
      intra.RMSE = intra.RMSE, intra.R2 = intra.R2,
      multi.RMSE = multi.RMSE, multi.R2 = multi.R2
    )
  })


  # make final.model an object from class misty.model?
  final.model <- list(
    meta.model = combined.views,
    model.views = model.views,
    performance.estimate = performance.estimate
  )

  return(final.model)
}
