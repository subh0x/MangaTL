#!/bin/zsh
# Runs the test suite with the allocator setting the app uses, so memory assertions match the app.
cd "${0:A:h}/.."
MallocSpaceEfficient=1 swift test --no-parallel "$@"
