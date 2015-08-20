-- General Variables
local allowed_origin     = ngx.var.allowed_origin
local allowed_origin_ext = ngx.var.allowed_origin_ext
local url_signing_key    = ngx.var.url_signing_key
local origin_host        = ngx.var.origin_host
local origin_host_ext    = ngx.var.origin_host_ext
local args               = ngx.var.args
local http_x_picms_host  = ngx.var.http_x_picms_host
local request_uri        = ngx.var.request_uri
local http_referer       = ngx.var.http_referer

-- Crypto signing arguments
local sigv1          = ngx.var.arg_sigv1 -- Signature in URL
local expires        = ngx.var.arg_expires -- Expires timestamp in URL
-- General Functions
local exit   = ngx.exit
local log    = ngx.log
local re     = ngx.re
local say    = ngx.say
local os     = os
local string = string
-- Hashing functions
local encode_base64 = ngx.encode_base64
local hmac_sha1     = ngx.hmac_sha1
local md5           = ngx.md5
-- Logging levels
local WARN = ngx.WARN
-- HTTP Codes
local OK             = ngx.OK
local HTTP_FORBIDDEN = ngx.HTTP_FORBIDDEN

if http_x_sbimg_host ~= nil then
    log(WARN, "Looping, saw X-SBImg-Host header: ", http_x_sbimg_host)
    exit(HTTP_FORBIDDEN)
end
if allowed_origin == "0" and not sigv1 then -- Allow to proxy for disallowed domain as long as URL is signed, signature will be checked for validity
    log(WARN, "Attempt to proxy for unknown origin: ", origin_host)
    exit(HTTP_FORBIDDEN)
end
if allowed_origin_ext == "0" then
    log(WARN, "Attempt to proxy for unknown file extension: ", origin_ext)
    exit(HTTP_FORBIDDEN)
end
if url_signing_key == "0" then
    -- If key is not set we are good and can allow access to anyone
    exit(OK)
end
if args then
    -- Only perform signature verification if args are present and processing is required
    local params_to_sign = "" -- Initiate signable string

    -- Validate hostname for sanity
    if origin_host:len() > 255
    or not re.match(origin_host, "^(?:(?:[a-z0-9]|[a-z0-9][a-z0-9\\\\-]*[a-z0-9])[\\\\.]{1,1})+(?:[a-z0-9]|[a-z0-9][a-z0-9\\\\-]*[a-z0-9]){2,}$", "joui")
    then
        -- Reject request to
        log(WARN, "Attempt to proxy for invalid hostname: ", origin_host)
        exit(HTTP_FORBIDDEN)
    end
    -- Make sure that signature is present in URL
    if sigv1 == nil then
        -- Reject request without signature
        log(WARN, "Attempt to proxy without signature for: ", origin_host)
        exit(HTTP_FORBIDDEN)
    end
    -- Remove signature from parameters before generating verification hash
    -- This is a full request URL with all of the arguments present
    params_to_sign = re.gsub(request_uri, "(?:sigv1)=[^&]+&?", "", "joui")
    -- Update sd_cache_key with clean URL hash, increase cache hit rate
    -- TODO: sort these params for better caching
    ngx.var.sd_cache_key = md5(params_to_sign)

    -- Lets hash the string and check if it is authorized
    local signature = encode_base64(hmac_sha1(url_signing_key, params_to_sign))
    local utcnow    = os.time(os.date("!*t"))
    -- If you desire to have fixed expiration on assets, we will check its validity
    if expires and expires < utcnow then
        -- Reject expired URLs
        ngx.status = HTTP_FORBIDDEN
        say("URL Expired")
        log(WARN, "Attempt to proxy for with expired URL, expired on: ", expires)
        exit(HTTP_FORBIDDEN)
    end
    -- Lastly, check validity of the supplied signature and reject if it doesn't match
    if sigv1 ~= signature then
        -- Reject invalid signature URLs
        ngx.status = HTTP_FORBIDDEN
        say("Invalid Signature")
        log(WARN, "Attempt to proxy for with invalid signature for: ", origin_host)
        exit(HTTP_FORBIDDEN)
    end
end