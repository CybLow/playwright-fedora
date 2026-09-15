# H.264 fixture

`h264.mp4` is a generated, silent 64×64 red video used to verify WebKit decoding.
Regenerate with an FFmpeg build that supports libx264:

```sh
ffmpeg -f lavfi -i color=c=red:s=64x64:r=10 -t 1 -c:v libx264 \
    -pix_fmt yuv420p -movflags +faststart h264.mp4
```
