#!/bin/zsh
# Downloads the sample pages the tests and smoke run use: Pepper&Carrot episode 6 by David Revoy
# (CC-BY 4.0, https://www.peppercarrot.com) in six languages. Images are not committed to git.
set -e
cd "${0:A:h}/.."
base=https://www.peppercarrot.com/0_sources/ep06_The-Potion-Contest/low-res
mkdir -p spike/pages spike/smoke
for lang in ja cn kr es fr pt; do
  for page in 01 03 05; do
    out=spike/pages/${lang}_P$page.jpg
    [[ -f $out ]] || curl -sfL -o $out "$base/${lang}_Pepper-and-Carrot_by-David-Revoy_E06P$page.jpg"
  done
done
# Smoke-run project: the three Japanese pages.
cp spike/pages/ja_P01.jpg spike/smoke/01.jpg
cp spike/pages/ja_P03.jpg spike/smoke/02.jpg
cp spike/pages/ja_P05.jpg spike/smoke/03.jpg
echo "samples: $(ls spike/pages/*.jpg | wc -l | tr -d ' ') pages in spike/pages, 3 in spike/smoke"
