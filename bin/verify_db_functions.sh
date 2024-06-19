#!/bin/bash

set -eo pipefail

prg="${0##*/}"

# html mode is supposed to be piped to mutt in order to send an email
#     verify_db_functions.sh bom-postgres-clientdb mydb |
#     mutt -e 'set content_type=text/html' -s SUBJECT EMAIL...
html=
case "$1" in
    -html | --html)
        html=1; shift
        ;;
esac

repo="$1"; shift                # eg: bom-postgres-clientdb
db=("$@")                       # services

[ "$html" ] && echo "<h1>Verifying manifest in repo $repo against ${db[@]}</h1>"

mkdir -p /dev/shm/"$prg"
cd /dev/shm/"$prg"

trap "rm -rf '/dev/shm/$prg/$repo'" EXIT

tag="$({
        T="$(mktemp -d --tmpdir)" &&
        trap "rm -rf '$T'" EXIT &&
        R="git@github.com:regentmarkets/environment-manifests" &&
        git clone -q --depth 1 -b production "$R" "$T"
       } >/dev/null &&
       cat "$T"/tag_gray)"

echo "${html:+<p>}Checking out $tag${html:+</p>}"
git clone --depth 1 --branch "$tag" git@github.com:regentmarkets/"$repo".git 2>/dev/null
cd "$repo"

for i in "${db[@]}"; do
    echo "${html:+<h2>}Testing $i${html:+</h2><pre style='width:180em'><code>}"
    psql -qXAtF ' ' \
	 -c '\o /dev/null' \
	 -c 'SELECT set_config($$tools.manifest_exclude$$, $${tmp}$$, false);' \
	 -c '\o' \
	 -f tools/manifest.sql service="$i" |
    sed -E 's/^[0-9a-z]{27}/../' |
    # At the time of writing the longest line in manifest is 165
    # characters long. Diff will cut off anything that does not
    # fit into the allotted space. I think it's decipherable
    # nonetheless what the problem is with a total line width of 180.
    (printf '%-85s | %s\n\n' Database Manifest &&
     diff -y --suppress-common-lines -W 180 - \
          <(sed -E 's/^[0-9a-z]{27}/../' manifest) && echo 'no differences') |
    # jq: quick way to html-escape <>& etc
    if [ "$html" ]; then jq -Rr @html; else cat; fi || :
    [ "$html" ] && echo '</code></pre>' || :
done
