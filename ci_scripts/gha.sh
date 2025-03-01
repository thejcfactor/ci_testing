#! /bin/bash

set -e -u

PROJECT_ROOT="$(
    cd "$(dirname "$0"/..)" >/dev/null 2>&1
    pwd -P
)"

CI_SCRIPTS_PATH="$PROJECT_ROOT/ci_scripts"
PROJECT_PREFIX=""

function log_message {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $1"
}

function display_info {
    echo "Workflow Run ID=$GITHUB_RUN_ID"
    echo "Workflow Event=$GITHUB_EVENT_NAME"
    echo "is_release=${CBCI_IS_RELEASE:-}"
    echo "SHA=${CBCI_SHA:-}"
    echo "version=${CBCI_VERSION:-}"
    echo "cxx_change=${CBCI_CXX_CHANGE:-}"
    echo "build_config=${CBCI_CONFIG:-}"
    echo "PROJECT_TYPE=$CBCI_PROJECT_TYPE"
    echo "DEFAULT_PYTHON=$CBCI_DEFAULT_PYTHON"
    echo "SUPPORTED_PYTHON_VERSIONS=$CBCI_SUPPORTED_PYTHON_VERSIONS"
    echo "SUPPORTED_X86_64_PLATFORMS=$CBCI_SUPPORTED_X86_64_PLATFORMS"
    echo "DEFAULT_LINUX_PLATFORM=$CBCI_DEFAULT_LINUX_PLATFORM"
    echo "DEFAULT_MACOS_X86_64_PLATFORM=$CBCI_DEFAULT_MACOS_X86_64_PLATFORM"
    echo "DEFAULT_WINDOWS_PLATFORM=$CBCI_DEFAULT_WINDOWS_PLATFORM"
    echo "DEFAULT_LINUX_CONTAINER=$CBCI_DEFAULT_LINUX_CONTAINER"
    echo "DEFAULT_ALPINE_CONTAINER=$CBCI_DEFAULT_ALPINE_CONTAINER"
}

function validate_sha {
    sha="${CBCI_SHA:-}"
    if [ -z "$sha" ]; then
        echo "Must provide SHA"
        exit 1
    fi
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Invalid SHA: $sha"
        exit 1
    fi
}

function validate_version {
    version="${CBCI_VERSION:-}"
    if [ -z "$version" ]; then
        echo "Must provide version"
        exit 1
    fi
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc|dev|post)[0-9]+)?$ ]]; then
        echo "Invalid version: $version"
        exit 1
    fi
}

function validate_input {
    workflow_type="${1:-}"
    set_project_prefix
    if [ "$workflow_type" == "build_wheels" ]; then
        echo "workflow_type: build_wheels, params: $@"
        is_release="${CBCI_IS_RELEASE:-}"
        if [[ ! -z "$is_release" && "$is_release" == "true" ]]; then
            validate_sha
            validate_version
        fi
    elif [ "$workflow_type" == "tests" ]; then
        echo "workflow_type: tests, params: $@"
    else
        echo "Invalid workflow type: $workflow_type"
        exit 1
    fi
}

function set_project_prefix {
    if [ ! -z "$PROJECT_PREFIX" ]; then
        return
    fi
    project_type="${CBCI_PROJECT_TYPE:-}"
    if [[ "$project_type" == "OPERATIONAL" || "$project_type" == "PYCBC" ]]; then
        PROJECT_PREFIX="PYCBC"
    elif [[ "$project_type" == "COLUMNAR" || "$project_type" == "PYCBCC" ]]; then
        PROJECT_PREFIX="PYCBCC"
    else
        echo "Invalid project type: $project_type"
        exit 1
    fi
}

function set_client_version {
    set_project_prefix
    version_script=""
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        if [ ! -f "couchbase_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_version.py"
    elif [ "$PROJECT_PREFIX" == "PYCBCC" ]; then
        if [ ! -f "couchbase_columnar_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_columnar_version.py"
    else
        echo "Invalid project prefix: $PROJECT_PREFIX"
        exit 1
    fi
    version="${CBCI_VERSION:-}"
    if ! [ -z "$version" ]; then
        git config user.name "Couchbase SDK Team"
        git config user.email "sdk_dev@couchbase.com"
        git tag -a $version -m "Release of client version $version"
    fi
    python $version_script --mode make
}

function setup_and_execute_linting {
    set_client_version
    python -m pip install --upgrade pip setuptools wheel
    python -m pip install -r requirements.txt
    python -m pip install pre-commit
    pre-commit run --all-files
}

function build_sdist {
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    set_project_prefix

    echo "Installing basic build dependencies."
    python -m pip install --upgrade pip setuptools wheel

    build_config="${CBCI_CONFIG:-}"
    echo "Parsing build config: $build_config"

    exit_code=0
    config_str=$(python "$CI_SCRIPTS_PATH/pygha.py" "parse_sdist_config" "CBCI_CONFIG") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "config_str=$config_str"
        echo "Failed to parse build config."
        exit 1
    fi
    export $(echo $config_str)
    # export $(echo "$config_str" | jq -r '. | to_entries[] | join("=")')

    env_vars=$(env | grep $PROJECT_PREFIX)
    echo "Environment variables:"
    echo "$env_vars"
    cd $PROJECT_ROOT
    echo "Building C++ core CPM Cache."
    python setup.py configure_ext
    set_client_version

    rm -rf ./build
    echo "Building source distribution."
    python setup.py sdist
    cd dist
    echo "ls -alh $PROJECT_ROOT/dist"
    ls -alh
}

function get_sdist_name {
    sdist_dir="$PROJECT_ROOT/dist"
    if [ ! -d "$sdist_dir" ]; then
        echo "sdist_dir does not exist."
        exit 1
    fi
    cd dist
    sdist_name=$(find . -name '*.tar.gz' | cut -c 3- | rev | cut -c 8- | rev)
    echo "$sdist_name"
}

function get_stage_matrices {
    exit_code=0
    stage_matrices=$(python "$CI_SCRIPTS_PATH/pygha.py" "get_stage_matrices" "CBCI_CONFIG") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "stage_matrices=$stage_matrices"
        echo "Failed to generate stage matrices."
        exit 1
    fi
    echo "$stage_matrices"
}

function handle_cxx_change {
    cxx_change="${CBCI_CXX_CHANGE:-}"
    if [[ ! -z "$cxx_change" && "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
        if [[ "$cxx_change" == "PR_*" ]]; then
            pr=$(echo "$cxx_change" | cut -d'_' -f 2)
            echo "Attempting to checkout C++ core PR#$pr."
            cd deps/couchbase-cxx-client
            git fetch origin pull/$pr/head:tmp
            git checkout tmp
            git log --oneline -n 10
        elif [[ "$cxx_change" == "BR_*" ]]; then
            branch=$(echo "$cxx_change" | cut -d'_' -f 2)
            echo "Attempting to checkout C++ core branch."
            cd deps/couchbase-cxx-client
            git fetch origin
            git --no-pager branch -r
            git checkout $branch
            git log --oneline -n 10
        elif [[ "$cxx_change" == "CP_*" ]]; then
            echo "Attempting to cherry-pick C++ core SHA."
        else
            echo "No CXX change detected."
        fi
    fi
}

cmd="${1:-empty}"

if [ "$cmd" == "display_info" ]; then
    display_info
elif [ "$cmd" == "validate_input" ]; then
    validate_input "${@:2}"
elif [ "$cmd" == "lint" ]; then
    setup_and_execute_linting
elif [ "$cmd" == "sdist" ]; then
    build_sdist
elif [ "$cmd" == "get_sdist_name" ]; then
    get_sdist_name
elif [ "$cmd" == "get_stage_matrices" ]; then
    get_stage_matrices
else
    echo "Invalid command: $cmd"
fi
