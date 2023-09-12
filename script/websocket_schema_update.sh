#!/bin/bash
# This script formats and copies the JSON schema files used for the API Playground
# from binary-websocket-api to the respective repositories. 
# 07/2021 we are currently copying for two sites api.deriv.com and developers.binary.com.
# developers.binary.com will soon be retired and redirect to api.deriv.com.

# developers.binary.com - repo is binary-com/websockets
# api.deriv.com - repo is binary-com/deriv-api-docs

# To test this fork binary-com/websockets and binary-com/deriv-api-docs then supply your git username as an argument

GITORG=${1:-binary-com}
set -ex

rm -rf /tmp/websockets
rm -rf /tmp/deriv-websockets

git clone git@github.com:${GITORG}/websockets /tmp/websockets
git clone git@github.com:${GITORG}/deriv-api-docs /tmp/deriv-websockets

cd /tmp/websockets
git config --local user.email "sysadmin@binary.com"
git config --local user.name "CircleCI"

rsync /home/git/regentmarkets/binary-websocket-api/config /tmp/websockets/ --delete -a

# Generate api list yml file, and remove json files of excluded methods
/home/git/regentmarkets/binary-websocket-api/script/websocket_api_list.pl /tmp/websockets/

cd /tmp/deriv-websockets
rsync /home/git/regentmarkets/binary-websocket-api/config /tmp/deriv-websockets/ --delete -a
/home/git/regentmarkets/binary-websocket-api/script/websocket_api_list.pl /tmp/deriv-websockets/

cd /tmp/websockets
# Show what we're changing - anyone can easily check version control for this,
# but this diff usually is not too long.
git diff | cat
git add -A

# Commit fails if there is nothing to commit. We don't want to commit
# in such cases but we don't want to fail either. So, we catch the
# output and investigate what went wrong with the commit.
# The tee command is added to see the message in the log.
X="$(git commit -m "JSON Schema Update")" ||
tee /dev/stderr <<<"$X" | grep -q 'nothing to commit'
git push origin HEAD


# repeat the push for api.deriv.com 
cd /tmp/deriv-websockets
git diff | cat
git add -A
X="$(git commit -m "JSON Schema Update")" ||
tee /dev/stderr <<<"$X" | grep -q 'nothing to commit'
git push origin master

