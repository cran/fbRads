#' Insights
#' @inheritParams fbad_request
#' @param target ad account id(s) (default), campaign id(s), adset id(s) or ad id(s)
#' @param job_type synchronous or asynchronous request. If the prior fails with "please reduce the amount of data", it will fall back to async request. Async query is possible with only one target.
#' @param retries number of times this query has been sent to Facebook previously and failed -- to be used internally for error handling
#' @param simplify return a list of \code{data.frame} or \code{list} objects
#' @param ... named arguments passed to the API, like time range, fields, filtering etc.
#' @references \url{https://developers.facebook.com/docs/marketing-api/insights}
#' @return \code{list} of \code{data.frame} or \code{list} objects depending on the \code{simplify} argument
#' @export
#' @importFrom utils URLdecode
#' @examples \dontrun{
#' fb_insights(fbacc)
#'
#' ## get default fields and filter for a few metrics
#' l <- fb_insights(date_preset = 'today', level = 'ad')
#' ## merge pages into tabular data
#' data.table::rbindlist(l)
#'
#' ## sometimes more advanced list selections are needed
#' l <- fb_insights(date_preset = 'today', level = 'ad', fields = 'unique_actions', simplify = FALSE)
#'
#' ## filter for ACTIVE Ads
#' l <- fb_insights(date_preset = 'today', level = 'ad',
#'   filtering = "[{'field':'adset.effective_status','operator':'IN','value':['ACTIVE']}]")
#' }
fb_insights <- function(fbacc, target = fbacc$acct_path, job_type = c('sync', 'async'), retries = 0, simplify = TRUE, ...) {

    fbacc <- fbad_check_fbacc()

    ## update args
    job_type <- match.arg(job_type)

    ## batched query with multiple targets
    if (length(target) > 1) {

        ## this should fail with async query
        if (job_type == 'async') {
            stop('Batched queries are not possible with async call. Please query only one item at a time.')
        }

        ## get all provided params
        l <- list(...)

        ## remove internal 'retries' param
        l$retries <- NULL

        ## URL encode params
        l <- paste(names(l),
                   sapply(l, paste, collapse = ','),
                   sep = '=',
                   collapse = '&')

        ## hit the API & return
        return(lapply(
            split(target, 1:length(target) %/% 50),
            function(batch) {

                ## query FB by 50 ids at a time
                res <- fbad_request(
                    fbacc,
                    path   = '',
                    params = list(
                        batch  = toJSON(
                            data.frame(
                                method = 'GET',
                                relative_url = paste0(
                                    'v', fbacc$api_version,
                                    '/', batch, '/insights?',
                                    l))
                        )),
                    method = 'POST')

                res <- lapply(fromJSONish(res)$body, function(x) fromJSONish(x)$data)

                ## transform data part of the list to data.frame
                if (simplify == TRUE) {
                    res <- rbindlist(res, fill = TRUE)
                }

                res

            }))

    }

    params <- list(...)
    params$fields <- paste(params$fields, collapse = ',')

    ## start sync or async report generation
    res <- tryCatch(fbad_request(fbacc,
        path   = file.path(sub('/$', '', target), 'insights'),
        method = switch(job_type,
            'sync'  = 'GET',
            'async' = 'POST'),
        params = params, log = FALSE), error = function(e) e)

    ## sync request
    if (job_type == 'sync') {

        ## if it was a sync job and failed
        if (inherits(res, 'error')) {

            ## let's try an async query for larger data
            log_debug('Sync request failed, starting async request.')
            mc <- match.call()
            mc$job_type <- 'async'
            return(eval(mc))

        }

    ## async request
    } else {

        if (inherits(res, 'error')) {
            stop(res$message)
        }

        ## we have an async job, we need the job ID
        id <- fromJSONish(res)[[1]]

        ## capture current call with the number of (no) retrues
        mc <- match.call()
        if (is.null(mc$retries)) {
            mc$retries <- 0
        }

        ## get results & pass the current call for possible future retries
        res <- fbad_insights_get_async_results(id = id,
                                               original_call = mc,
                                               original_env  = sys.frame())

    }

    ## we got results from a retry of a previously failed async query
    if (inherits(res, 'list')) {
        return(res)
    }

    ## otherwise parse the JSON
    res <- fromJSONish(res)

    ## save data as list
    l <- list(res$data)

    ## get all pages (if any)
    while (!is.null(res$paging$'next')) {
        res <- fbad_request_next_page(res$paging$`next`)
        l   <- c(l, list(res$data))
    }

    ## return list
    l

}


#' Wait for and get asynchronous report results
#' @inheritParams fbad_request
#' @param id job ID
#' @param original_call original call of \code{fb_insights} for future retries
#' @param original_env original environment of \code{fb_insights}
#' @return JSON
#' @keywords internal
fbad_insights_get_async_results <- function(fbacc, id, original_call, original_env) {

    fbacc <- fbad_check_fbacc()

    ## get status
    res <- fbad_request(fbacc,
        path   = id,
        method = "GET")

    ## parse JSON
    res <- fromJSONish(res)

    ## default polling interval (in seconds)
    wait_time  <- 2/5
    ## and percentage
    percentage <- res$async_percent_completion

    ## record time of first query so that we can stop doing
    ## any further lookups after 45 mins as per
    ## https://developers.facebook.com/bugs/811986068934782/
    job_started_at <- as.numeric(Sys.time())

    ## job still running
    while (res$async_status %in% c('Job Not Started', 'Job Started', 'Job Running')) {

        ## stop with an error after 45 mins even if job is still running
        if (as.numeric(Sys.time()) - job_started_at > 45*60) {
            stop(sprintf('Async query took more than 45 mins for job ID %s', id))
        }

        ## update polling interval
        dpercentage <- res$async_percent_completion - percentage
        wait_time   <- wait_time * ifelse(dpercentage > 10,
                                          ifelse(dpercentage > 25, 0.5,
                                                 ifelse(dpercentage > 15, 0.75, 1)),
                                          ifelse(dpercentage > 5, 2, 5))
        percentage  <- res$async_percent_completion

        ## hard limit (5 minutes) for wait time
        wait_time <- min(wait_time, 300)

        ## log
        log_debug(paste0(id, ' Async ',
                         res$async_status, ' (',
                         res$async_percent_completion,
                         '%). Waiting ', round(wait_time, 1), ' seconds...'))

        ## wait a bit
        Sys.sleep(wait_time)

        ## instead of a recursive call, let's specify the query again
        ## as nested calls was likely to cause segfault in R :(
        res <- fromJSONish(fbad_request(fbacc,
            path   = id,
            method = "GET"))

    }

    ## job completed
    if (res$async_status == 'Job Completed') {

        ## get the report
        return(fbad_request(fbacc,
            path   = file.path(id, 'insights'),
            method = "GET"))

    }

    ## job failed with error message, so let's retry this a few times
    ## after waiting for some time to allow FB to recover
    if (res$async_status == 'Job Failed') {

        ## capture parent call (starting the async query)
        mc <- original_call

        ## update number of tries in parent call's environment
        original_call$retries <- original_call$retries + 1

        ## fail on 3rd error
        if (original_call$retries > 3) {
            log_error(toJSON(res))
            stop('Tried this query too many times, this is a serious issue.')
        }

        ## log this error
        log_error(toJSON(res))
        log_info(paste('Retrying query for the', original_call$retries, 'st/nd/rd time'))

        ## give some chance for the system/network to recover
        Sys.sleep(60)

        ## retry the query for no more than 3 times
        return(eval(original_call, envir = original_env))

    }

    ## other error?
    log_error(toJSON(res))
    stop('Unexpected response for the asynchronous job.')

}
