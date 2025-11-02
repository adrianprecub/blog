#!/bin/bash

set -e

docker run --rm \
  -v "$PWD":/data \
  --init \
  -t \
  -p 5173:5173 \
  -p 24678:24678 \
  -e CHOKIDAR_USEPOLLING=1 \
  -e CHOKIDAR_INTERVAL=200 \
  likec4/likec4 \
  start