#!/bin/bash

set -eo pipefail

SCRIPT="$(realpath "$0")"
D="${SCRIPT%/*}"

R="$(date +prof-%Y-%m-%dT%H:%M:%S)"
mkdir "$R"
cd $R
echo "The result will be in $R"
perl "$D"/extract_pricer_shortcodes.pl |
    NYTPROF=start=no perl -d:NYTProf "$D"/profile_price_timing.pl
