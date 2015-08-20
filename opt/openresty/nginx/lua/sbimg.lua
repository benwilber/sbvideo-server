local _M = {}
 
local P      = require("path")
local lfs    = require("lfs")
local string = string
local math   = math
local os     = os
local cURL   = require("cURL.safe")
local gm     = require("graphicsmagick")
local r_lock = require("resty.lock")
local re     = ngx.re
local log    = ngx.log
local INFO   = ngx.INFO
local WARN   = ngx.WARN
local ERR    = ngx.ERR
 
_M.P = P -- Export for usage inside other lua scripts
 
_M.mkdir = function (absdir)
    -- Creates directory tree recursevely
    local t = absdir
    local dir, base = P.split(t)
    local a = P.isdir(t)
    if a then
        -- Path exists, return
        return true
    end
 
    local d = P.isdir(dir)
    local b = P.isdir(base)
    if d and not b then
        -- Directory exists, basename does not, create and return
        local ok = lfs.mkdir(t)
        return ok
    else
        -- Directory does not exist, recursively call self
        _M.mkdir(dir)
        local ok = lfs.mkdir(t)
        return ok
    end
end
 
_M.fetch_origin = function (ctx)
    -- Localize nginx variables
    local http_host                = ngx.var.http_host
    local http_x_forwarded_for     = ngx.var.http_x_forwarded_for or ""
    local http_x_forwarded_proto   = ngx.var.http_x_forwarded_proto or "Unknown"
    local http_cf_connecting_ip    = ngx.var.http_cf_connecting_ip or ""
    local http_referer             = ngx.var.http_referer or ""
 
    -- To avoid pileup and false presence, use tmp file to download first
    local tmp_file                 = ctx.origin_cache_path .. "~"
 
    -- Create directories if not present yet
    local ok = _M.mkdir(P.dirname(ctx.origin_cache_path))
    if not ok then
        return false
    end
 
    -- Origin file not present, fetch it
    local f = io.open(tmp_file, "w+b")
    if not f then
        log(ERR, "Failed to create a new file: ", tmp_file)
        return false
    end
    log(INFO, "Fetching file [", ctx.origin_cache_path, "] from: ", ctx.origin_url)
    local c = cURL.easy{
        url = ctx.origin_url,
        writefunction = f,
        [cURL.OPT_FAILONERROR]       = true, -- Fail on HTTP 4xx errors.
        [cURL.OPT_FOLLOWLOCATION]    = true, -- Follow 301 and 302 redirects
        [cURL.OPT_AUTOREFERER]       = true, -- Set Referer for 301 and 302 redirects
        [cURL.OPT_MAXREDIRS]         = 5,    -- No more than 5 redirects to follow
        [cURL.OPT_TIMEOUT]           = 16,   -- Timeout downloading file after 14 seconds if not done
        [cURL.OPT_CONNECTTIMEOUT]    = 3,    -- Timeout downloading file after 14 seconds if not done
        [cURL.OPT_HTTP_VERSION]      = cURL.CURL_HTTP_VERSION_2_0, -- Use highest HTTP protocol version
        [cURL.OPT_SSL_VERIFYPEER]    = false,    -- Do not verify SSL certificate of the peer
        [cURL.OPT_SSL_CIPHER_LIST]   = "ecdhe_ecdsa_aes_128_sha,ecdhe_ecdsa_aes_256_sha,ecdhe_ecdsa_3des_sha,rsa_aes_128_sha,rsa_aes_256_sha",
        [cURL.OPT_MAXFILESIZE]       = 20971520, -- Limit download to no larger than 20Mb
        [cURL.OPT_MAXFILESIZE_LARGE] = 20971520, -- Limit download to no larger than 20Mb
    }:setopt_httpheader{
        "X-SBImg-Host: "              .. http_host,
        "X-Forwarded-For: "           .. http_x_forwarded_for,
        "X-Forwarded-Proto: "         .. http_x_forwarded_proto,
        "X-SBImg-Connecting-CF-IP: "  .. http_cf_connecting_ip,
        "Referer: "                   .. http_referer,
        "User-Agent: Mozilla/5.0 (img.streamboat.tv ImageProxy cURL Fetcher)",
    }
    local _, e = c:perform()
 
    -- close connection and output file
    -- (Improvement) Possible connection pooling
    c:close()
    f:close()
 
    if P.isfile(tmp_file) and not e then
        log(WARN, "Successfully fetched file [", ctx.origin_cache_path, "] from: ", ctx.origin_url)
        os.rename(tmp_file, ctx.origin_cache_path)
        return true
    else
        log(WARN, "Failed to fetch file [", ctx.origin_cache_path, "] from: ", ctx.origin_url)
        log(WARN, "cURL error (if any): ", tostring(e))
        os.remove(tmp_file) -- Remove failed temp file
        return false
    end
end
 
_M.locked_execution = function(lockid, func, ctx)
    -- This function will attempt to lock the lockid (should be path to a dir/file)
    -- execute func (passing ctx as an argument), and unlock the path
    -- To be successful, create temp file (on the same filesystem) and work with that,
    -- once done, move (rename file) to a target "lockid" filename.
    -- This will ensure atomicity of the lock and file access.
    -- Check if original file already in cache and return if present:
    if P.exists(lockid) then
        log(INFO, "To be locked file/dir is present, aborting: ", lockid)
        return true
    end
 
    -- cache miss!
    -- Acquire lock:
    -- Make sure that nginx.conf has something like "lua_shared_dict imgsrv_locks 10m;"
    -- Set lock timeout to 20 seconds, cURL 16 seconds for download and 3 for connection timeout
    local lock         = r_lock:new("imgsrv_locks", {timeout=20})
    local elapsed, err = lock:lock(lockid)
    if not elapsed then
        log(ERR, "Failed to acquire the lock: ", err)
        return false
    end
    -- lock successfully acquired!
    log(INFO, "Acquired lock after [", elapsed, "] seconds: ", lockid)
 
    -- while waiting for a lock other process might created the file already
    -- check for its existance again and act accordingly
    if P.exists(lockid) then
        local ok, err = lock:unlock()
        if not ok then
            log(ERR, "Failed to unlock: ", err)
            -- Should we care? Maybe just silently ignore this error?
            return false
        end
 
        log(INFO, "To be locked file/dir was created while waiting for lock: ", lockid)
        return true
    end
 
    -- Acquired exclusive lock, work on the file/dir creation
    -- Expecting to get true/false back from func
    local fok = func(ctx) -- Execute function to populate lockid file/dir
    if not fok then
        local ok, err = lock:unlock()
        if not ok then
            log(ERR, "Failed to unlock: ", err)
            -- Should we care? Maybe just silently ignore this error?
            return false
        end
 
        log(WARN, "Failed to populate file/dir: ", lockid)
        return fok
    end
 
    local ok, err = lock:unlock()
    if not ok then
        log(ERR, "Failed to unlock: ", err)
        -- Should we care? Maybe just silently ignore this error?
        return false
    end
    return fok
end
 
_M.get_origin = function(ctx)
    -- Pass fetch_origin to be executed safely, make target local path a lockid
    return _M.locked_execution(ctx.origin_cache_path, _M.fetch_origin, ctx)
end
 
_M.imgoptim = function(img_path, ctx)
    -- We pass image path here in case we are dealing with temp file name of which is not in context table
    local origin_ext = ctx.origin_ext -- Use extension to identify what command to use for optimization
    local img_fmt    = origin_ext:lower() -- Maybe already in a lower case, do it again to make sure
    local quality    = ctx.quality or 75 -- If for some reasons quality prameter is not in context, default to 75%
    -- List of optimizers to use with their options and path concatinated to the command
    -- local jpeg_exec  = "/usr/bin/jpegoptim -q -P -p --all-progressive --max=" .. quality .. " " .. img_path
    local jpeg_exec  = "/opt/openresty/bin/jpegtran -copy none -optimize -progressive -outfile " .. img_path .. "~ " .. img_path
    local png_exec   = "/usr/bin/optipng -o7 -fix -preserve -q -zm9 -strip all " .. img_path
    local gif_exec   = "/opt/openresty/bin/gifsicle -b -O3 " .. img_path
 
    if origin_ext and (img_fmt == "jpg" or img_fmt == "jpeg") then
        log(INFO, "Optimizing JPEG: ", jpeg_exec)
        local ok = 0 == os.execute(jpeg_exec)
        os.rename(img_path .. "~", img_path)
        return true
    elseif origin_ext and img_fmt == "png" then
        log(INFO, "Optimizing PNG: ", png_exec)
        return 0 == os.execute(png_exec)
    elseif origin_ext and img_fmt == "gif" then
        log(INFO, "Optimizing GIF: ", gif_exec)
        return 0 == os.execute(gif_exec)
    end
    log(INFO, "Not Optimizing: ", img_fmt)
    return true -- Just pass through
end
 
_M.process_image = function (ctx)
    local src     = ctx.origin_cache_path
    local dst     = ctx.processed_cache_path
    local dst_tmp = dst .. "~"
    local width   = ctx.width ~= 0 and ctx.width or nil -- Need to nil'ify for easier dealings with gm
    local height  = ctx.height ~= 0 and ctx.height or nil -- Need to nil'ify for easier dealings with gm
    local crop    = ctx.crop
    local zoom    = ctx.zoom
    local strip   = ctx.strip -- We will actualy strip all metadata in final optimization
    local quality = ctx.quality
 
    log(INFO, "Transforming image: w:", width or "(none)", " h:", height or "(none)", " crop:", crop, " zoom:", zoom, " quality:", quality)
    -- Origin should be present
    -- Instanciate GraphicsMagickWand
    local image = gm.Image()
    -- If width or height specified and smaller than origin, load speed may increase
    if width or height then
        image:load(src, width, height)
    else
        image:load(src)
    end
 
    -- Original W&H
    local src_w, src_h = image:size()
 
    -- Zoom?
    if type(zoom) == "number" and zoom > 0 then
        -- If zooming, we will figure-out sizes and scale accordingly
        width  = math.floor(src_w * zoom)
        height = math.floor(src_h * zoom)
    end
 
    -- Crop or resize
    -- Preserve aspect ration, no one likes stretched images
    local resize_filter = "Undefined" -- GM will select one for us
    if width and height then
        -- Borrowed from lua imagemagick bindings
        local ar_src = src_w / src_h
        local ar_dest = width / height
        if ar_dest > ar_src then
            -- Landscape orientation
            local new_height = width / ar_src
            image:size(width, new_height, resize_filter)
            if crop == "1" then
                -- Crop image after we are resized, keep centered
                image:crop(width, height, 0, (new_height - height) / 2)
            end
        else
            -- Portrait orientation
            local new_width = height * ar_src
            image:size(new_width, height, resize_filter)
            if crop == "1" then
                -- Crop image after we are resized, keep centered
                image:crop(width, height, (new_width - width) / 2, 0)
            end
        end
        -- Some fancy logging for ya...
        log(INFO, "Cropping: ", (crop == "1" and "[yes]" or "[no]"), "; Resizing to: ", width, "x", height)
    elseif width or height then
        image:size(width, height, resize_filter)
    end
 
    image:depth(8) -- Make image 8bit in depth, we are optimizing for web
    -- Need to lock path before doing any saving.
    _M.mkdir(P.dirname(dst))
    -- Finally save image to a temp file
    image:save(dst_tmp, quality)
    -- Run optimization on a newly created image, WEBP is already optimized so we do not touch it
    _M.imgoptim(dst_tmp, ctx)
 
    -- (Improvement) To save space we could hardlink new file to other permutations, i.e., 0x0 will also be the same as original image WxH
 
    -- Finaly rename files to the target name
    os.rename(dst_tmp, dst)
 
    -- Save in WEBP format if requested
    if tonumber(ngx.var.create_webp) ~= 0 then
        image:save(dst .. "~.webp", quality)
        os.rename(dst .. "~.webp", dst .. ".webp")
    end
 
    return true
end
 
_M.transform_image = function (ctx)
    -- Pass process_image to be executed safely, make target local path a lockid
    return _M.locked_execution(ctx.processed_cache_path, _M.process_image, ctx)
end
 
return _M