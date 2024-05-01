#!/bin/bash
COUNTRY="$1"

mkdir -p "output/$COUNTRY"
echo "* Started: $COUNTRY"
bundle exec ruby test.rb --output="output/$COUNTRY/result.txt" --error-file="output/$COUNTRY/errors.tsv" "sources/$COUNTRY/$COUNTRY.txt"
echo "* Finished: $COUNTRY"
