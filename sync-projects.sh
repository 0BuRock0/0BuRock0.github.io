#!/usr/bin/env bash
#
# sync-projects.sh
#
# Reads projects.conf and, for each listed GitHub repo:
#   1. Creates a Hugo page bundle at content/<type>/<slug>/ if it doesn't exist
#      (type is "projects" or "writeups", set per line in the config)
#   2. Creates a starter index.md with front matter if one doesn't exist yet
#   3. Shallow-clones the repo and copies image files from the specified
#      folder into the page bundle
#
# Usage (run from the root of your Hugo site, e.g. ~/Desktop/Projects/my-portfolio):
#   ./sync-projects.sh
#
# Optional: pass a different config file path as the first argument:
#   ./sync-projects.sh path/to/other.conf

set -euo pipefail

CONFIG_FILE="${1:-projects.conf}"
CONTENT_ROOT="content"
VALID_TYPES=("projects" "writeups")
IMAGE_EXTENSIONS=("png" "jpg" "jpeg" "gif" "webp" "svg")

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: config file '$CONFIG_FILE' not found." >&2
  echo "Run this script from your Hugo site root, or pass a path to your config file." >&2
  exit 1
fi

if [[ ! -d "$CONTENT_ROOT" ]]; then
  echo "Error: '$CONTENT_ROOT' not found. Are you in the root of your Hugo site?" >&2
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

processed=0
skipped=0

is_valid_type() {
  local t="$1"
  for valid in "${VALID_TYPES[@]}"; do
    [[ "$t" == "$valid" ]] && return 0
  done
  return 1
}

while IFS='|' read -r repo_url slug branch image_dir type || [[ -n "$repo_url" ]]; do
  # Skip blank lines and comments
  [[ -z "$repo_url" || "$repo_url" =~ ^[[:space:]]*# ]] && continue

  # Trim whitespace around each field
  repo_url="$(echo "$repo_url" | xargs)"
  slug="$(echo "$slug" | xargs)"
  branch="$(echo "$branch" | xargs)"
  image_dir="$(echo "$image_dir" | xargs)"
  type="$(echo "$type" | xargs)"

  if [[ -z "$repo_url" || -z "$slug" || -z "$branch" || -z "$image_dir" || -z "$type" ]]; then
    echo "⚠️  Skipping malformed line (need 5 fields): $repo_url" >&2
    ((skipped++)) || true
    continue
  fi

  if ! is_valid_type "$type"; then
    echo "⚠️  Skipping '$slug' — type must be 'projects' or 'writeups', got '$type'" >&2
    ((skipped++)) || true
    continue
  fi

  echo "── [$type] $slug ──────────────────────────────"

  bundle_dir="$CONTENT_ROOT/$type/$slug"
  screenshots_dir="$bundle_dir/screenshots"
  mkdir -p "$screenshots_dir"

  # Create a starter index.md only if one doesn't already exist,
  # so re-running this script never overwrites content you've written.
  index_file="$bundle_dir/index.md"
  if [[ ! -f "$index_file" ]]; then
    title="$(echo "$slug" | sed -E 's/-/ /g; s/\b(.)/\u\1/g')"
    if [[ "$type" == "projects" ]]; then
      cat > "$index_file" <<EOF
---
title: "$title"
date: $(date +%Y-%m-%d)
draft: true
repo: "$repo_url"
categories: []
tags: []
---

Write a description of $title here.

<!-- example: ![Screenshot](screenshots/SS1.png) -->
EOF
    else
      cat > "$index_file" <<EOF
---
title: "$title"
date: $(date +%Y-%m-%d)
draft: true
categories: []
tags: []
---

Write your writeup for $title here.
EOF
    fi
    echo "  created $index_file (draft: true — remember to flip it and add content)"
  else
    echo "  $index_file already exists, leaving it alone"
  fi

  # Shallow clone into a temp folder
  clone_dir="$TMP_ROOT/$slug"
  echo "  cloning $repo_url (branch: $branch)..."
  if ! git clone --depth 1 --branch "$branch" --quiet "$repo_url" "$clone_dir" 2>/dev/null; then
    echo "  ⚠️  Failed to clone $repo_url on branch '$branch' — skipping images for this project." >&2
    ((skipped++)) || true
    continue
  fi

  source_image_path="$clone_dir"
  if [[ "$image_dir" != "." ]]; then
    source_image_path="$clone_dir/$image_dir"
  fi

  if [[ ! -d "$source_image_path" ]]; then
    echo "  ⚠️  Image directory '$image_dir' not found in repo — skipping images." >&2
    ((skipped++)) || true
    continue
  fi

  # Copy matching image files (top-level of that folder only)
  copied=0
  for ext in "${IMAGE_EXTENSIONS[@]}"; do
    for f in "$source_image_path"/*."$ext"; do
      [[ -e "$f" ]] || continue
      cp "$f" "$screenshots_dir/"
      copied=$((copied + 1))
    done
  done

  echo "  copied $copied image(s) into $screenshots_dir"
  ((processed++)) || true

done < "$CONFIG_FILE"

echo "────────────────────────────────────────"
echo "Done. $processed entr$([ "$processed" -eq 1 ] && echo y || echo ies) processed, $skipped skipped."
echo "Review any new index.md files, set draft: false when ready, and run:"
echo "  hugo server -D"
