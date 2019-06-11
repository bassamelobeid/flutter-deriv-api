#!/bin/bash

set -ex

rm -rf /tmp/websockets

git clone git@github.com:binary-com/websockets /tmp/websockets

cd /tmp/websockets
git config --local user.email "sysadmin@binary.com"
git config --local user.name "CircleCI"

rsync /home/git/regentmarkets/binary-websocket-api/config /tmp/websockets/ --delete -a
rm -fvr /tmp/websockets/config/*/change_password
rm -fvr /tmp/websockets/config/*/reset_password
rm -fvr /tmp/websockets/config/*/service_token

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
