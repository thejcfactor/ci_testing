#! /bin/bash

set -e -u

function display_info {
    echo "Workflow Run ID=$GITHUB_RUN_ID"
    echo "Workflow Event=$GITHUB_EVENT_NAME"
    echo "is_release=${INPUT_IS_RELEASE:-}"
    echo "SHA=${INPUT_SHA:-}"
    echo "version=${INPUT_VERSION:-}"
    echo "cxx_change=${INPUT_CXX_CHANGE:-}"
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
    project_type="${PROJECT_TYPE:-}"
    if [[ "$project_type" == "OPERATIONAL" || "$project_type" == "COLUMNAR" ]]; then
        echo "Invalid project type: $project_type"
        exit 1
    fi
    if [ "$workflow_type" == "build_wheels" ]; then
        echo "workflow_type: build_wheels, params: $@"
        is_release="${INPUT_IS_RELEASE:-}"
        if ! [[ -z "$is_release" && "$is_release" == "true" ]]; then
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

function setup_and_execute_linting {
    project_type="${PROJECT_TYPE:-}"
    version_script=""
    if [ "$project_type" == "OPERATIONAL" ]; then
        # if [ ! -d "venv" ]; then
        #     python -m venv venv
        # fi
        if [ ! -f "couchbase_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_version.py"
    elif [ "$project_type" == "COLUMNAR" ]; then
        if [ ! -f "couchbase_columnar_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_columnar_version.py"
    else
        echo "Invalid project type: $project_type"
        exit 1
    fi
    version="${INPUT_VERSION:-}"
    if ! [ -z "$version" ]; then
        git config user.name "Couchbase SDK Team"
        git config user.email "sdk_dev@couchbase.com"
        git tag -a $version -m "Release of client version $version"
    fi
    python $version_script --mode make
    python -m pip install --upgrade pip setuptools wheel
    python -m pip install -r requirements.txt
    python -m pip install pre-commit
    pre-commit run --all-files
}

cmd="${1:-empty}"

if [ "$cmd" == "display_info" ]; then
    display_info
elif [ "$cmd" == "validate_input" ]; then
    validate_input "${@:2}"
elif [ "$cmd" == "lint" ]; then
    setup_and_execute_linting
else
    echo "Invalid command: $cmd"
fi