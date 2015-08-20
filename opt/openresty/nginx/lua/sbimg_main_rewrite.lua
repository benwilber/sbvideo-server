-- Cache shared dictionary
local imgsrv_cache = ngx.shared.imgsrv_cache
local cjson        = cjson_safe.new()

-- Check if processed path is in cache so we can stop right here
local sd_cache_key = ngx.var.sd_cache_key
local jctx, flags  = imgsrv_cache:get(sd_cache_key)
local ctx          = cjson.decode(jctx)
if ctx then
    ngx.var.processed_path = ctx.processed_path
    ngx.exit(ngx.OK)
else
    -- Not in cache yet, create new ctx
    ctx = {}
end

-- Cache miss, do full processing

-- Localazie modules we will use during this call
local lurl   = url -- net.url imported in init_by_lua
local sbimg = sbimg -- My module imported in init_by_lua
local P      = sbimg.P -- Assign path module from sbimg for conveninence
local string = string
local re     = ngx.re
local log    = ngx.log
local INFO   = ngx.INFO
local WARN   = ngx.WARN
local ERR    = ngx.ERR
-- Localize variables
local http_x_forwarded_proto = ngx.var.http_x_forwarded_proto
local scheme                 = ngx.var.scheme
local args                   = ngx.var.args
local lquery                 = nil
local document_root          = ngx.var.document_root
if args then
    lquery = ngx.decode_args(args)
end

-- Sanitize variables
-- Figureout scheme we should be using to fetch from origin
ctx.origin_proto = string.lower(http_x_forwarded_proto or scheme or "http")

-- Origin host, path and extension to the asset
ctx.origin_host = string.lower(ngx.var.origin_host) -- case-insensitive, normalize
ctx.origin_path = ngx.var.origin_path               -- case-sensitive, leaving it as it is
ctx.origin_ext  = string.lower(ngx.var.origin_ext)  -- not used for fetching, lower for condition checking
-- If webp is requested, origin can be different, grab real extension and modify origin path
if ctx.origin_ext == "webp" then
    local origin_true_ext
    local s, e, err = re.find(ctx.origin_path, "\\.([a-z0-9]{3,})\\.webp$", "joiu")
    if s and e then
        origin_true_ext = string.sub(ctx.origin_path, s+1, e-5)
    end
    if origin_true_ext then
        ctx.origin_ext  = origin_true_ext
        ctx.origin_path = string.sub(ctx.origin_path, 1, -6)
        ctx.origin_req_ext = "webp"
        log(INFO, "Origin is not webp, requested to be converted to webp: [EXT]: ", origin_true_ext, " [PATH]: ", ctx.origin_path)
    end
end

-- Constract URL to fetch original file
local origin_url    = lurl
origin_url.scheme   = ctx.origin_proto
origin_url.host     = ctx.origin_host
origin_url.path     = ctx.origin_path

-- Build query to origin
ctx.origin_url          = origin_url:normalize():build() -- Normalize URL, resolve "../../.." and generaly clean it up
-- We want normalized url to build local path, hence, regex it here; remove any double slashes as well
ctx.origin_cache_path   = re.gsub(document_root .. "origin" .. re.sub(ctx.origin_url, "^(?:http(?:s)?)://", "/", "joui"), "/+", "/", "jou")

log(INFO, "Origin URL: ", ctx.origin_url)

-- Determening what transformation of image is requested
-- Start with filling in defaults
min_width   = tonumber(ngx.var.min_width) or 32
max_width   = tonumber(ngx.var.max_width) or 2500
min_height  = tonumber(ngx.var.min_height) or 32
max_height  = tonumber(ngx.var.max_height) or 2500
min_quality = tonumber(ngx.var.min_quality) or 50
ctx.width   = tonumber(ngx.var.width) or 0
ctx.height  = tonumber(ngx.var.height) or 0
ctx.crop    = tonumber(ngx.var.crop) or 0
ctx.zoom    = tonumber(ngx.var.zoom) or 0
ctx.strip   = tonumber(ngx.var.strip) or 1
ctx.quality = tonumber(ngx.var.quality) or 75
-- Url signature
if lquery then
    -- Width & Height
    local w = tonumber(lquery.w)
    local h = tonumber(lquery.h)
    local z = tonumber(lquery.zoom) or tonumber(lquery.z)
    local q = tonumber(lquery.q) or tonumber(lquery.quality)
    local c = (tonumber(lquery.crop) or tonumber(lquery.c)) and "1" or 0
    local s = tonumber(lquery.strip) or ctx.strip -- Do not care, strip always ... ;-)
    if type(z) ~= "number" or z == 1 or z < 0 or z > 2 then -- No point of zooming beyond 2 or under 0, and if asked to zoom, no need to have dimensions
        if type(w) == "number" and w >= min_width and w <= max_width then
            ctx.width = math.floor(w)
        end
        if type(h) == "number" and h >= min_height and h <= max_height then
            ctx.height = math.floor(h)
        end
        ctx.zoom = 0
    else
        ctx.width  = 0
        ctx.height = 0
        ctx.zoom   = z ~= 1 and z or 0
    end
    ctx.crop    = c
    if s ~= 1 then
        ctx.strip   = 0
    end
    if type(q) == "number" and q >= min_quality and q <= 100 then
        -- Default will be taken if never reached here
        ctx.quality = math.floor(q)
    end
end

-- Building asset path url, maybe better done in a separate function
ctx.processed_path = re.gsub("/processed/"
                            .. ctx.origin_host .. "/"
                            .. ctx.width .. "x" .. ctx.height
                            .. "/crop-" .. ctx.crop
                            .. "/zoom-" .. ctx.zoom
                            .. "/strip-" .. ctx.strip
                            .. "/q-" .. ctx.quality
                            .. "/" .. re.sub(ctx.origin_url, "^http(?:s)?://[^/]+/", "", "joui"), "/+", "/", "jou")
-- Absolute path to save processed image
ctx.processed_cache_path = re.gsub(document_root .. ctx.processed_path, "/+", "/", "jou")

-- If originaly requested file type was different from the one that was fetched, make sure that requested type served
if ctx.origin_req_ext then
    ctx.processed_path = ctx.processed_path .. "." .. ctx.origin_req_ext
end

-- Add entry to cache
local jctx = cjson.encode(ctx)
if jctx then
    local ok, err, forcible = imgsrv_cache:set(sd_cache_key, jctx, ngx.var.sd_default_expire)
    if not ok then
        log(WARN, "Failed to store entry in cache: ", err)
    end
    if forcible then
        log(WARN, "Maybe cache too small? Had to force valid items to store this one: ", sd_cache_key)
    end
else
    log(WARN, "Failed to convert context table into json format for cache id: ", sd_cache_key)
end

-- Return to let nginx serve the file
ngx.exit(ngx.OK)