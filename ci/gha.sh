#! /bin/bash

set -e -u

INPUT_IS_RELEASE="true"

function display_info {
    echo "Workflow Run ID=$GITHUB_RUN_ID"
    echo "Workflow Event=$GITHUB_EVENT_NAME"
    echo "is_release=${INPUT_IS_RELEASE:-}"
    echo "SHA=${INPUT_SHA:-}"
    echo "version=${INPUT_VERSION:-}"
    echo "cxx_change=${INPUT_CXX_CHANGE:-}"
    echo "DEFAULT_PYTHON=$DEFAULT_PYTHON"
    echo "PYTHON_VERSIONS=$PYTHON_VERSIONS"
    echo "X86_64_PLATFORMS=$X86_64_PLATFORMS"
    echo "ARM64_PLATFORMS=$ARM64_PLATFORMS"
}

function validate_input {
    workflow_type="${1:-}"
    if [ "$workflow_type" == "build_wheels" ]; then
        echo "workflow_type: build_wheels, params: $@"
    elif [ "$workflow_type" == "tests" ]; then
        echo "workflow_type: tests, params: $@"
    else
        echo "Invalid workflow type: $workflow_type"
        exit 1
    fi
}

cmd="${1:-empty}"

if [ "$cmd" == "display_info" ]; then
    display_info
elif [ "$cmd" == "validate_input" ]; then
    validate_input "${@:2}"
else
    echo "Invalid command: $cmd"
fi