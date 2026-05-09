#!/bin/bash
# Генерирует иконку AorusGram (огонёк на тёмном фоне) через SVG → PNG
# Запускать на macOS с установленным Inkscape или rsvg-convert
# На CI запускается автоматически перед сборкой

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/AppIcon.appiconset"

# SVG иконки — огонёк на градиентном фоне
cat > /tmp/aorusgram_icon.svg << 'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <radialGradient id="bg" cx="50%" cy="50%" r="50%">
      <stop offset="0%"   stop-color="#1A1A2E"/>
      <stop offset="100%" stop-color="#0A0A18"/>
    </radialGradient>
    <linearGradient id="flame1" x1="50%" y1="0%" x2="50%" y2="100%">
      <stop offset="0%"   stop-color="#FF6D00"/>
      <stop offset="60%"  stop-color="#FF3D00"/>
      <stop offset="100%" stop-color="#D50000"/>
    </linearGradient>
    <linearGradient id="flame2" x1="50%" y1="0%" x2="50%" y2="100%">
      <stop offset="0%"   stop-color="#FFEA00"/>
      <stop offset="100%" stop-color="#FF6D00"/>
    </linearGradient>
    <filter id="glow">
      <feGaussianBlur stdDeviation="18" result="blur"/>
      <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>

  <!-- Background -->
  <rect width="1024" height="1024" rx="230" fill="url(#bg)"/>

  <!-- Outer flame (orange-red) -->
  <path filter="url(#glow)"
    d="M512 900
       C340 900 220 780 220 620
       C220 520 270 440 330 380
       C310 460 340 510 380 540
       C360 460 380 380 430 310
       C450 430 490 490 512 540
       C534 490 574 430 594 310
       C644 380 664 460 644 540
       C684 510 714 460 694 380
       C754 440 804 520 804 620
       C804 780 684 900 512 900Z"
    fill="url(#flame1)" opacity="0.95"/>

  <!-- Inner flame (yellow) -->
  <path
    d="M512 820
       C420 820 360 750 360 660
       C360 600 390 555 420 520
       C410 570 430 605 455 625
       C445 575 460 530 490 490
       C500 550 508 590 512 625
       C516 590 524 550 534 490
       C564 530 579 575 569 625
       C594 605 614 570 604 520
       C634 555 664 600 664 660
       C664 750 604 820 512 820Z"
    fill="url(#flame2)" opacity="0.9"/>

  <!-- Core glow -->
  <ellipse cx="512" cy="700" rx="60" ry="80"
    fill="#FFFF00" opacity="0.55" filter="url(#glow)"/>
</svg>
SVG

# Генерация всех размеров
sizes=(20 29 40 58 60 80 87 120 152 167 180 1024)
for size in "${sizes[@]}"; do
  if command -v rsvg-convert &>/dev/null; then
    rsvg-convert -w "$size" -h "$size" /tmp/aorusgram_icon.svg -o "$OUT/icon-${size}.png"
  elif command -v inkscape &>/dev/null; then
    inkscape /tmp/aorusgram_icon.svg --export-width="$size" --export-filename="$OUT/icon-${size}.png"
  elif command -v convert &>/dev/null; then
    convert -background none /tmp/aorusgram_icon.svg -resize "${size}x${size}" "$OUT/icon-${size}.png"
  else
    echo "Warning: no SVG converter found (rsvg-convert / inkscape / imagemagick)"
    break
  fi
  echo "Generated icon-${size}.png"
done

echo "App icon generation complete!"
