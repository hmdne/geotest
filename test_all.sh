#!/bin/bash
find sources -mindepth 1 -maxdepth 1 -type d -print0 | cut -z -d/ -f2 | xargs -0 -P`nproc` -n1 ./test_single.sh
