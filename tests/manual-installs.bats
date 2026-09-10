#!/usr/bin/env bats
# Guards the hand-maintained MANUAL INSTALLS list (default.config.yml) and the
# "Decommissioning the old Mac" checklist (NEW-MAC.md) against silently
# losing items. See GitHub issue #14.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CONFIG="$REPO_ROOT/default.config.yml"
NEW_MAC="$REPO_ROOT/NEW-MAC.md"

# Print only the MANUAL INSTALLS comment block (from its header to the closing rule).
manual_installs_block() {
  sed -n '/^# MANUAL INSTALLS/,/^# -\{10,\}/p' "$CONFIG"
}

@test "MANUAL INSTALLS lists apps found on the old Mac that no cask/mas covers" {
  block="$(manual_installs_block)"
  for item in \
    "Autodesk Fusion" \
    "Steam" \
    "SkillVault Desktop" \
    "ChatGPT Classic" \
    "Photoshop 2024" \
    "Photoshop 2025" \
    "Acrobat DC" \
    "Google Docs" \
    "Google Sheets" \
    "Google Slides"; do
    grep -qF -- "$item" <<<"$block" || { echo "missing from MANUAL INSTALLS: $item"; return 1; }
  done
}

@test "MANUAL INSTALLS reminds the reader to check ~/Applications as well as /Applications" {
  # A per-app "(installs to ~/Applications)" aside is not enough; there must be
  # an explicit instruction to check that folder when auditing the old Mac.
  manual_installs_block | grep -qiE '(check|look in|audit).*~/Applications'
}

# Print only the "Decommissioning the old Mac" section of NEW-MAC.md.
decommission_section() {
  sed -n '/^## Decommissioning the old Mac/,/^## /p' "$NEW_MAC"
}

@test "Decommissioning checklist covers every account/device the old Mac is enrolled in" {
  section="$(decommission_section)"
  for item in \
    "Dropbox" \
    "Google Drive" \
    "Steam" \
    "Adobe Creative Cloud" \
    "Panic Sync" \
    "Tailscale" \
    "Syncthing" \
    "SSH key"; do
    grep -qF -- "$item" <<<"$section" || { echo "missing from decommission checklist: $item"; return 1; }
  done
}

@test "Decommissioning checklist revokes the old SSH key only after the new one works" {
  decommission_section | grep -iE 'SSH key' | grep -qiE 'after .*new'
}
