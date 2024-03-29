#' FB Search API Querying
#' @inheritParams fbad_request
#' @param q string that is being searched for
#' @param type describes the type of search eg: adinterest, adeducationmajor etc
#' @param ... other optional parameters accepted by the endpoint as key = value pairs eg: \code{limit = 5000}.
#' @return \code{data.frame} containing results
#' @examples \dontrun{
#' fbad_get_search(q = 'r programming language', type = 'adinterest')
#' fbad_get_search(q = c('dog', 'cat'), type = 'adinterestvalid')
#' }
#' @references \url{https://developers.facebook.com/docs/marketing-api/audiences/reference/targeting-search}
#' @export
fbad_get_search <- function(
    fbacc, q,
    type = c(
        'adeducationschool', 'adeducationmajor',
        'adgeolocation', 'adcountry', 'adzipcode', 'adgeolocationmeta', 'adradiussuggestion',
        'adinterest', 'adinterestsuggestion', 'adinterestvalid',
        'adlocale', 'adTargetingCategory', 'adworkemployer', 'targetingsearch'), ... ) {

    type  <- match.arg(type)
    fbacc <- fbad_check_fbacc()

    ## default params
    params <- list(limit = 500, list  = 'GLOBAL')

    ## targetingsearch is a bit different than the other searches
    if (type != 'targetingsearch') {
        params$type <- type
    }

    ## merge other params
    if (length(list(...)) > 0) {
        params <- c(params, list(...))
    }

    ## handle term input variation in API
    if (type %in% c('adinterestvalid', 'adinterestsuggestion')) {

        params <- c(params, list(interest_list = toJSON((q))))

    } else {

        if (length(q) > 1) {
            stop('Multiple keywords not allowed')
        }

        params$q <- as.character(q)

    }

    ## get results
    properties <- fbad_request(
        fbacc,
        path   = ifelse(type == 'targetingsearch',
                        paste0(fbacc$acct_path, 'targetingsearch'),
                        'search'),
        method = 'GET',
        params = params)

    ## transform data into data frame
    res <- fromJSONish(gsub('\n', '', properties))$data

    ## list to data.frame with know colnames
    if (type %in% c(
        "adinterestvalid",
        "adinterestsuggestion",
        "adinterest")) {

        if (inherits(res, 'list')) {
            res  <- sapply(res, function(x) c(
                id            = x$id,
                name          = x$name,
                audience_size = x$audience_size))
        }
    }

    if (!inherits(res, 'data.frame')) {
        res <- ldply(res, as.data.frame)
    }

    ## return
    res

}
