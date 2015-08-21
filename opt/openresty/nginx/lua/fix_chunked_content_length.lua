--  https://github.com/kaltura/nginx-vod-module/issues/131
if not ngx.header.content_length and ngx.header.content_range then
  local start_byte, end_byte = ngx.header.content_range:match("bytes (%d+)-(%d+)/%d+")
  if start_byte and end_byte then
    ngx.header.Content_Length = (end_byte - start_byte) + 1
  end
end