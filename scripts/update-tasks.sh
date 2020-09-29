#!/usr/bin/env bash
set -e -u -o pipefail

declare -r SCRIPT_NAME=$(basename "$0")
declare -r SCRIPT_DIR=$(cd $(dirname "$0") && pwd)

log() {
    local level=$1; shift
    echo -e "$level: $@"
}


err() {
    log "ERROR" "$@" >&2
}

info() {
    log "INFO" "$@"
}

die() {
    local code=$1; shift
    local msg="$@"; shift
    err $msg
    exit $code
}

usage() {
  local msg="$1"
  cat <<-EOF
Error: $msg

USAGE:
    $SCRIPT_NAME CATALOG_VERSION DEST_DIR VERSION

Example:
  $SCRIPT_NAME release-v0.7 deploy/resources v0.7.0
EOF
  exit 1
}

#declare -r CATALOG_VERSION="release-v0.7"

declare -r TEKTON_CATALOG="https://raw.githubusercontent.com/openshift/tektoncd-catalog"
declare -A TEKTON_CATALOG_TASKS=(
  ["openshift-client"]="0.1"
  ["git-clone"]="0.2"
  ["buildah"]="0.1"
)

declare -r OPENSHIFT_CATALOG="https://raw.githubusercontent.com/openshift/pipelines-catalog"
declare -A OPENSHIFT_CATALOG_TASKS=(
  ["buildah-pr"]="0.1"
  ["s2i-go"]="0.1"
  ["s2i-java-8"]="0.1"
  ["s2i-java-11"]="0.1"
  ["s2i-python-3"]="0.1"
  ["s2i-nodejs"]="0.1"
  ["s2i-perl"]="0.1"
  ["s2i-php"]="0.1"
  ["s2i-ruby"]="0.1"
  ["s2i-dotnet-3"]="0.1"
  ["s2i-go-pr"]="0.1"
  ["s2i-java-8-pr"]="0.1"
  ["s2i-java-11-pr"]="0.1"
  ["s2i-python-3-pr"]="0.1"
  ["s2i-nodejs-pr"]="0.1"
  ["s2i-perl-pr"]="0.1"
  ["s2i-php-pr"]="0.1"
  ["s2i-ruby-pr"]="0.1"
  ["s2i-dotnet-3-pr"]="0.1"
)


download_task() {
  local task_path="$1"; shift
  local task_url="$1"; shift

  info "downloading ... $t from $task_url"
  # validate url
  curl --output /dev/null --silent --head --fail "$task_url" || return 1


  cat <<-EOF > "$task_path"
# auto generated by script/update-tasks.sh
# DO NOT EDIT: use the script instead
# source: $task_url
#
---
$(curl -sLf "$task_url" |
  sed -e 's|^kind: Task|kind: ClusterTask|g' \
      -e "s|^\(\s\+\)workingdir:\(.*\)|\1workingDir:\2|g"  )
EOF

 # NOTE: helps when the original and the generated need to compared
 # curl -sLf "$task_url"  -o "$task_path.orig"

}

change_task_image() {
  local dest_dir="$1"; shift
  local version="${1//./-}"; shift

  local task="$1"; shift
  local task_path="$dest_dir/${task}/${task}-task.yaml"
  local task_path_version="$dest_dir/${task}/${task}-$version-task.yaml"

  local expr=$1; shift
  local image=$1; shift

  sed \
      -i "s'$expr.*'$image'" \
      $task_path

  sed \
      -i "s'$expr.*'$image'" \
      $task_path_version
}

get_tasks() {
  local dest_dir="$1"; shift
  local version="${1//./-}"; shift

  local catalog="$1"; shift
  local catalog_version="$1"; shift

  local -n tasks=$1


  info "Downloading tasks from catalog $catalog to $dest_dir directory"
  for t in ${!tasks[@]} ; do
    # task filenames do not follow a naming convention,
    # some are taskname.yaml while others are taskname-task.yaml
    # so, try both before failing
    echo  test
    local task_url="$catalog/$catalog_version/task/$t/${tasks[$t]}/${t}.yaml"
    echo "$catalog/$catalog_version/task/$t/${tasks[$t]}/${t}.yaml"
    mkdir -p "$dest_dir/$t/"
    local task_path="$dest_dir/$t/$t-task.yaml"

    download_task  "$task_path" "$task_url"  ||
      die 1 "Failed to download $t"

    create_version "$task_path" "$t" "$version"  ||
      die 1  "failed to convert $t to $t-$version"
  done
}


create_version() {
  local task_path="$1"; shift
  local task="$1"; shift
  local version="$1"; shift
  local task_version_path="$(dirname $task_path)/$task-$version-task.yaml"

  sed \
    -e "s|^\(\s\+name:\)\s\+\($task\)|\1 \2-$version|g"  \
    $task_path  > "$task_version_path"
}



main() {


  local catalog_version=${1:-''}
  [[ -z "$catalog_version"  ]] && usage "missing catalog_version"
  shift

  local dest_dir=${1:-''}
  [[ -z "$dest_dir"  ]] && usage "missing destination directory"
  shift

  local version=${1:-''}
  [[ -z "$version"  ]] && usage "missing task_version"
  shift

  mkdir -p "$dest_dir" || die 1 "failed to create ${dest_dir}"

  dest_dir="$dest_dir/addons/02-clustertasks"
  mkdir -p "$dest_dir" || die 1 "failed to create catalog dir ${catalog_dir}"

  get_tasks "$dest_dir" "$version"  \
    "$TEKTON_CATALOG"   "$catalog_version"  TEKTON_CATALOG_TASKS

  get_tasks "$dest_dir" "$version"  \
    "$OPENSHIFT_CATALOG"   "$catalog_version"  OPENSHIFT_CATALOG_TASKS

  change_task_image "$dest_dir" "$version"  \
    "buildah"  "quay.io/buildah"  \
    "registry.redhat.io/rhel8/buildah"

  change_task_image "$dest_dir" "$version"  \
    "buildah-pr"  "quay.io/buildah"  \
    "registry.redhat.io/rhel8/buildah"

  change_task_image "$dest_dir" "$version"  \
    "openshift-client"  "quay.io/openshift/origin-cli:latest"  \
    "image-registry.openshift-image-registry.svc:5000/openshift/cli:latest"

  # this will do the change for all pipelines catalog tasks except buildah-pr
  for t in ${!OPENSHIFT_CATALOG_TASKS[@]} ; do
    change_task_image "$dest_dir" "$version"  \
      "$t"  "quay.io/openshift-pipeline/s2i"  \
      "registry.redhat.io/ocp-tools-43-tech-preview/source-to-image-rhel8"

    change_task_image "$dest_dir" "$version"  \
      "$t"  "quay.io/buildah"  \
      "registry.redhat.io/rhel8/buildah"

  done

  return $?
}

main "$@"
