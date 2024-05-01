#!/bin/bash
# Provide an absolute path to location of All_Countries.7z
# Get it from: https://geonames.nga.mil/geonames/GNSData/

rm -rf sources
mkdir -p sources
pushd sources
7z x "$1"
for i in *.zip; do
  COUNTRY="$(echo $i | sed s/.zip//g)"
  mkdir -p "$COUNTRY"
  pushd "$COUNTRY"
  unzip "../$i"
  popd
  rm -f "$i"
done
