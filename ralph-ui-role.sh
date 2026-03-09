#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$WORKSPACE_ROOT"

collect_changed_files() {
  git diff --name-only --diff-filter=ACMRTUXB HEAD || true
  git ls-files --others --exclude-standard || true
}

files="$(collect_changed_files | sed '/^$/d' | sort -u)"
if [ -z "$files" ]; then
  echo "recommended_role=Player"
  echo "reason=no_changed_files_detected"
  exit 0
fi

has_admin=0
has_dm=0
has_auth=0
while IFS= read -r f; do
  case "$f" in
    *admin*|*roles*|*users*|*authorization*|*auth-role*|*auth/role*|*authz*) has_admin=1 ;;
  esac
  case "$f" in
    *dm-tools*|*encounter*|*runtime-state*|*session-effects*|*bestiary*|*monster*|*npc*) has_dm=1 ;;
  esac
  case "$f" in
    *login*|*logout*|*session*|*auth*|*navigation*|*navbar*|*profile*) has_auth=1 ;;
  esac
done <<< "$files"

if [ "$has_auth" -eq 1 ]; then
  echo "recommended_role_matrix=Player,DM,Admin"
  echo "reason=auth_or_navigation_surface_changed"
  exit 0
fi

if [ "$has_admin" -eq 1 ]; then
  echo "recommended_role=Admin"
  echo "reason=admin_or_role_management_surface_changed"
  exit 0
fi

if [ "$has_dm" -eq 1 ]; then
  echo "recommended_role=DM"
  echo "reason=dm_or_encounter_surface_changed"
  exit 0
fi

echo "recommended_role=Player"
echo "reason=general_user_surface_changed"
