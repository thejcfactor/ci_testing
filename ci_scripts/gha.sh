#! /bin/bash

set -e -u

PROJECT_ROOT="$(
    cd "$(dirname "$0"/..)" >/dev/null 2>&1
    pwd -P
)"

CI_SCRIPTS_PATH="$PROJECT_ROOT/ci_scripts"
echo "PROJECT_ROOT=$PROJECT_ROOT"

PROJECT_PREFIX=""

function display_info {
    echo "Workflow Run ID=$GITHUB_RUN_ID"
    echo "Workflow Event=$GITHUB_EVENT_NAME"
    echo "is_release=${INPUT_IS_RELEASE:-}"
    echo "SHA=${INPUT_SHA:-}"
    echo "version=${INPUT_VERSION:-}"
    echo "cxx_change=${INPUT_CXX_CHANGE:-}"
    echo "build_config=${INPUT_BUILD_CONFIG:-}"
    echo "PROJECT_TYPE=$PROJECT_TYPE"
    echo "DEFAULT_PYTHON=$DEFAULT_PYTHON"
    echo "PYTHON_VERSIONS=$PYTHON_VERSIONS"
    echo "X86_64_PLATFORMS=$X86_64_PLATFORMS"
    echo "ARM64_PLATFORMS=$ARM64_PLATFORMS"
}

function validate_sha {
    sha="${INPUT_SHA:-}"
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
    version="${INPUT_VERSION:-}"
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
        is_release="${INPUT_IS_RELEASE:-}"
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
    project_type="${PROJECT_TYPE:-}"
    if [[ "$project_type" == "OPERATIONAL" || "$project_type" == "PYCBC" ]]; then
        PROJECT_PREFIX="PYCBC"
    elif [[ "$project_type" == "COLUMNAR"  || "$project_type" == "PYCBCC" ]]; then
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
    version="${INPUT_VERSION:-}"
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
    set_project_prefix

    echo "Installing basic build dependencies."
    python -m pip install --upgrade pip setuptools wheel

    build_config="${INPUT_BUILD_CONFIG:-}"
    echo "Parsing build config: $build_config"

    exit_code=0
    config_str=$(python "$CI_SCRIPTS_PATH/pygha.py" "parse_sdist_config" "INPUT_BUILD_CONFIG") || exit_code=$?
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
    ls -alh
    sdist_name=$(find . -name '*.tar.gz' | cut -c 3- | rev | cut -c 8- | rev)
    export $(echo "SDIST_NAME=$sdist_name")
}

function handle_cxx_change {
    cxx_change="${INPUT_CXX_CHANGE:-}"
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
else
    echo "Invalid command: $cmd"
fi
