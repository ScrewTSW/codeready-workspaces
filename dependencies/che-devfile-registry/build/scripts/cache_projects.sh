#!/bin/bash
#
# Copyright (c) 2012-2018 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#
# Arguments
#    $1 - devfiles directory
#    $2 - resources directory, where project zips will be stored.
#
# Only supports downloading projecst from GitHub.

set -e

DEVFILES_DIR="${1%/}"
RESOURCES_DIR="${2%/}"
TEMP_DIR="${RESOURCES_DIR}/devfiles_temp"
TEMP_FILE="${TEMP_DIR}/temp.yaml"
TEMP_REPO="${TEMP_DIR}/cloned"

# Clone a git repository and create an archive zip at a specified location
# Args:
#   $1 - URL of git repo
#   $2 - (optional) branch to archive
#   $3 - destination path for the archived project zip file
function cache_project() {
  local repo="$1"
  local branch="$2"
  local destination="$3"
  git clone "$location" -b "$branch" --depth 1 "$TEMP_REPO" &>/dev/null
  git archive "$branch" --remote="$TEMP_REPO" --format zip --output "$destination"
  rm -rf "$TEMP_REPO"
}

# Update devfile to refer to a locally stored zip instead of a public git repo
# Args:
#   $1 - path to devfile to update
#   $2 - name of project to update within devfile
#   $3 - path to downloaded project zip
function update_devfile() {
  local devfile="$1"
  local project_name="$2"
  local zip_path="$3"
  # The yq script below will rewrite the project with $project_name to be a zip-type
  # project with provided path. The location field contains a placeholder
  # '{{ DEVFILE_REGISTRY_URL }}' which must be filled at runtime (see
  # build/dockerfiles/entrypoint.sh script)
  # shellcheck disable=SC2016
  yq -y \
    '(.projects | map(select(.name != $PROJECT_NAME))) as $projects |
    . + {
      "projects": (
        $projects + [{
          "name": $PROJECT_NAME,
          "source": {
            "type": "zip",
            "location": "{{ DEVFILE_REGISTRY_URL }}/\($PROJECT_PATH)"
          }
        }]
      )
    }' "$devfile" \
    --arg "PROJECT_NAME" "${project_name}" \
    --arg "PROJECT_PATH" "${zip_path}" \
    > "$TEMP_FILE"
  # As a workaround since jq does not support in-place updates, we need to copy
  # to a temp file and then overwrite the original.
  echo "    Copying $TEMP_FILE -> $devfile"
  mv "$TEMP_FILE" "$devfile"

}

function get_devfile_name() {
  devfile=$1
  yq -r '.metadata |
    if has("name") then
      .name
    elif has("generateName") then
      .generateName
    else
      "unnamed-devfile"
    end
  ' $devfile
}

readarray -d '' devfiles < <(find "$DEVFILES_DIR" -name 'devfile.yaml' -print0)
mkdir -p "$TEMP_DIR" "$RESOURCES_DIR"
for devfile in "${devfiles[@]}"; do
  echo "Caching project files for devfile $devfile"
  devfile_name=$(get_devfile_name "$devfile")
  devfile_name=${devfile_name%-}
  for project in $(yq -c '.projects[]?' "$devfile"); do
    project_name=$(echo "$project" | jq -r '.name')
    echo "    Caching project $project_name"

    type=$(echo "$project" | jq -r '.source.type')
    if [ "$type" != "git" ]; then
      echo "    [WARN]: Project type is not 'git'; skipping."
      continue
    fi

    location=$(echo "$project" | jq -r '.source.location')
    branch=$(echo "$project" | jq -r '.source.branch')
    if [ -n $branch ]; then
      branch="master"
    fi
    destination="${RESOURCES_DIR}/${devfile_name}-${project_name}-${branch}.zip"
    echo "    Caching project to $(realpath $destination)"
    cache_project "$location" "$branch" "$(realpath $destination)"

    echo "    Updating devfile $devfile to point at cached project zip $destination"
    update_devfile "$devfile" "$project_name" "$destination"
  done
done

rm -rf "$TEMP_DIR"

