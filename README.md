# HLS/DASH MP4 Proxy Server
## Basic usage
####Request a Master Playlist
```
GET http://video.streamboat.tv/hls/master.m3u8?source=http://example.com/video.mp4
```
```
#EXTM3U
#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=1283488,RESOLUTION=640x360,CODECS="avc1.42c01e,mp4a.40.2"
http://video.streamboat.tv/hls/index-v1-a1.m3u8?source=http://example.com/video.mp4
```
This video only has a single variant.
```
GET http://video.streamboat.tv/hls/index-v1-a1.m3u8?source=http://example.com/video.mp4
```
```
#EXTM3U
#EXT-X-TARGETDURATION:10
#EXT-X-ALLOW-CACHE:YES
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-VERSION:3
#EXT-X-MEDIA-SEQUENCE:1
#EXTINF:10.000,
http://video.streamboat.tv/hls/seg-1-v1-a1.ts?source=http://example.com/video.mp4
#EXTINF:10.000,
http://video.streamboat.tv/hls/seg-2-v1-a1.ts?source=http://example.com/video.mp4
#EXTINF:10.000,
http://video.streamboat.tv/hls/seg-3-v1-a1.ts?source=http://example.com/video.mp4
#EXTINF:10.000,
http://video.streamboat.tv/hls/seg-4-v1-a1.ts?source=http://example.com/video.mp4
#EXTINF:4.821,
http://video.streamboat.tv/hls/seg-5-v1-a1.ts?source=http://example.com/video.mp4
#EXT-X-ENDLIST
```
