#!/bin/bash
set -eu

: ${CI_REPOSITORY}
: ${CI_LOG_NAME}

LOG_DIR=src/testdir/log
LOG_FILE=log.tgz

[[ -d "${LOG_DIR}" ]] || exit 0

tar -zcf "${LOG_FILE}" -C "${LOG_DIR%/*}" "${LOG_DIR##*/}"

aws s3 cp "${LOG_FILE}" "s3://${AWS_ARTIFACT_BUCKET}/${CI_REPOSITORY}/${CI_LOG_NAME}"
