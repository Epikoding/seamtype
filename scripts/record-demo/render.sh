#!/bin/zsh
# Makes the README demo (docs/media/demo.gif) from the footage record.sh left in build/demo/,
# and the website's copy (build/demo/web/demo.mp4 and demo-poster.jpg, for araso/ in the
# nyttastudio.com repo):
# crops the page, the input menu and its icon out of the screen recording into film/assets/,
# writes the key times for the film (film/assets/keys.js), renders the HyperFrames film
# (film/index.html) and turns it into a GIF.
#
#   scripts/record-demo/render.sh            # all of it
#   scripts/record-demo/render.sh --assets   # only the assets, for the Studio preview (cd film && npm run dev)
set -euo pipefail
here="${0:A:h}"
root="${here:h:h}"
footage="$root/build/demo"
film="$here/film"
assets="$film/assets"
[[ -f "$footage/demo.mov" && -f "$footage/keys.json" ]] || { echo "no footage: run record.sh first"; exit 1 }

# The recording starts a moment before the clock demo.swift times the keys by: the first letter
# shows up this many seconds before its logged time (measured on the footage).
lead=0.2
# The typing plays this much faster than it was recorded.
speed=1.35
# Where each clip starts in the recording, in seconds of the video.
menu_from=1.67 page_from=6.6

mkdir -p "$assets"
width=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$footage/demo.mov")
read -r s px py pw ph mx my <<<"$(python3 - "$footage/keys.json" $width <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
p, m = d["page"], d["inputMenu"]
# Points to pixels: the recording's width over the screen's, 2 on a Retina screen (1 where a
# remote desktop session has set the screen to fit its window). The page loses its bottom 12 pt:
# the window's rounded corners.
s = round(int(sys.argv[2]) / d["screen"]["w"])
print(s, *(round(v * s) for v in (p["x"], p["y"], p["w"], p["h"] - 12, m["x"] + m["w"] / 2, m["y"] + m["h"] / 2)))
EOF
)"
encode=(-c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -an -movflags +faststart)
# The film is laid out for 2x clips, so a 1x recording is enlarged (and comes out softer).
up="scale=iw*2/${s}:ih*2/${s}:flags=lanczos"
# The page, sped up.
ffmpeg -v error -y -ss $page_from -i "$footage/demo.mov" \
  -vf "crop=$pw:$ph:$px:$py,$up,setpts=PTS/$speed,fps=30" $encode "$assets/page.mp4"
# The input menu with its open menu below it (340 × 300 pt around the icon), at real speed.
ffmpeg -v error -y -ss $menu_from -t 6.4 -i "$footage/demo.mov" \
  -vf "crop=$((340 * s)):$((300 * s)):$((mx - 84 * s)):0,$up,fps=30" $encode "$assets/menu.mp4"
# Just the icon (60 × 32 pt), on the page's clock.
ffmpeg -v error -y -ss $page_from -i "$footage/demo.mov" \
  -vf "crop=$((60 * s)):$((32 * s)):$((mx - 30 * s)):$((my - 16 * s)),$up,setpts=PTS/$speed,fps=30" $encode "$assets/icon.mp4"

# Key times on the page clip's clock.
python3 - "$footage/keys.json" "$assets/keys.js" $lead $speed $page_from <<'EOF'
import json, sys
src, out, lead, speed, start = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:])
keys = [{"k": k["k"], "t": round((k["t"] - lead - start) / speed, 3)} for k in json.load(open(src))["keys"]]
open(out, "w").write("window.DEMO_KEYS = " + json.dumps(keys, ensure_ascii=False) + ";\n")
EOF
ls -lh "$assets"
[[ ${1:-} == --assets ]] && exit 0

# Render losslessly (H.264 noise would cost GIF bytes), then a two-pass palette GIF: 15 fps,
# 1440 px wide (shown at 720, for retina screens), only the changed rectangle per frame.
cd "$film"
npx --yes hyperframes@0.8.147 render -o "$footage/film.mp4" -f 30 --crf 0 --video-frame-format png --quiet
filters="fps=15,scale=1440:-1:flags=lanczos"
ffmpeg -hide_banner -loglevel error -y -i "$footage/film.mp4" -vf "$filters,palettegen=stats_mode=diff:max_colors=128" "$footage/palette.png"
ffmpeg -hide_banner -loglevel error -y -i "$footage/film.mp4" -i "$footage/palette.png" \
  -lavfi "$filters [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" "$root/docs/media/demo.gif"
ls -lh "$root/docs/media/demo.gif"

# The website plays an MP4 (a fraction of the GIF's size), with the finished lines as its poster.
mkdir -p "$footage/web"
ffmpeg -hide_banner -loglevel error -y -i "$footage/film.mp4" \
  -c:v libx264 -preset slow -crf 24 -tune animation -pix_fmt yuv420p -an -movflags +faststart "$footage/web/demo.mp4"
ffmpeg -hide_banner -loglevel error -y -ss 28.9 -i "$footage/film.mp4" -frames:v 1 -q:v 3 "$footage/web/demo-poster.jpg"
ls -lh "$footage/web"
