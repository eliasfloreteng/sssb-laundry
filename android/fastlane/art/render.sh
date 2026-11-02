#!/bin/sh
# Renders the Play Store graphics into fastlane/metadata/android/en-US/images/.
# Needs rsvg-convert and ImageMagick (Homebrew), and Google Chrome.
set -eu
cd "$(dirname "$0")"
out=../metadata/android/en-US/images
rsvg-convert -w 512 -h 512 icon.svg -o "$out/icon.png"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
  --hide-scrollbars --allow-file-access-from-files --virtual-time-budget=5000 \
  --window-size=1024,500 --screenshot="$PWD/feature.tmp.png" "file://$PWD/feature-graphic.html" 2>/dev/null
# Play wants no alpha channel on either image.
magick feature.tmp.png -alpha off -strip "$out/featureGraphic.png"
magick "$out/icon.png" -alpha off -strip "$out/icon.png"
rm feature.tmp.png
