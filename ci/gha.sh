#! /bin/bash

set -e -u

function display_info {
    echo "Workflow Run ID=GITHUB_RUN_ID"
    echo "is_release=${INPUT_IS_RELEASE-}"
    echo "SHA=${INPUT_SHA-}"
    echo "version=${INPUT_VERSION-}"
    echo "cxx_change=${INPUT_CXX_CHANGE-}"
    echo "DEFAULT_PYTHON=$DEFAULT_PYTHON"
    echo "PYTHON_VERSIONS=$PYTHON_VERSIONS"
    echo "X86_64_PLATFORMS=$X86_64_PLATFORMS"
    echo "ARM64_PLATFORMS=$ARM64_PLATFORMS"
}

function validate_input {
    echo "validate_input"
}

cmd="${1:-empty}"

if [ "$cmd" == "display_info" ]; then
    display_info
elif [ "$cmd" == "validate_input" ]; then
    validate_input
else
    echo "Invalid command: $cmd"
fi