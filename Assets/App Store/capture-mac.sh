#!/bin/zsh
# Captures raw Mac App Store screenshots into Raw/Mac/<language>/.
# Usage: ./capture-mac.sh [languages...]   (defaults to en ja)
#
# Each run writes the documents from samples.py, then opens each in a debug
# build of Libretto for Mac, whose screenshot mode draws its window into a
# picture and quits. Run compose.swift afterwards to frame them.
set -e

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h:h}
DERIVED_DATA=/tmp/libretto-mac-screenshots-dd
LANGUAGES=($@)
(( $# )) || LANGUAGES=(en ja)

xcodebuild build -project "$PROJECT_DIR/Libretto.xcodeproj" -scheme "Libretto for Mac" -configuration Debug \
  -destination "platform=macOS" -derivedDataPath $DERIVED_DATA CODE_SIGNING_ALLOWED=NO -quiet
APP=$DERIVED_DATA/Build/Products/Debug/Libretto.app/Contents/MacOS/Libretto

# Opens one document and waits for the app to draw it and quit. The app gives up
# without a picture when its window can't become key, so try a few times.
shoot() {
  local document=$1 output=$2 language=$3 attempt; shift 3
  for attempt in 1 2 3 4 5; do
    "$APP" "$document" -LibrettoScreenshot "$output" -AppleLanguages "($language)" \
      -ApplePersistenceIgnoreState YES "$@" >/dev/null 2>&1 || true
    [[ -f $output ]] && return
  done
  echo "no screenshot for $document" >&2; return 1
}

for language in $LANGUAGES; do
  raw_dir="$SCRIPT_DIR/Raw/Mac/$language"
  mkdir -p "$raw_dir"
  rm -f "$raw_dir/"*.png(N)
  samples="$(python3 "$SCRIPT_DIR/samples.py" Mac $language)"
  if [[ $language == ja ]]; then
    report="シャーレ活動報告書.docx" proposal="合同祭企画書.docx"
  else
    report="Schale Activity Report.docx" proposal="Festival Proposal.docx"
  fi
  shoot "$samples/$report" "$raw_dir/01-document.png" $language
  shoot "$samples/$proposal" "$raw_dir/02-review.png" $language -LibrettoScreenshotTab review
  shoot "$samples/Battle.swift" "$raw_dir/03-code.png" $language
  rm -r "$samples"
  echo "captured Mac/$language"
done
