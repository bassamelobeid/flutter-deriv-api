#!/bin/bash
set -e

cd /home/git/binary-com/translations-websockets-api

# First we sync the state of Weblate to ensure we
# have all current translations in place
echo '{"operation":"commit"}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/repository/
echo '{"operation":"push"}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/repository/
echo '{"lock":true}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/lock/

# Pull current status - this should give us a clean
# starting point from which to run a build
git config user.name "Automated translations build"
git config user.email "sysadmin@binary.com"
git checkout master
git pull --rebase
git remote set-branches --add origin translations
git fetch --depth 1 -v origin translations
git checkout translations
git pull --rebase
git merge origin/master

# This is the build itself - note that Redis may
# need to be running, since we load various modules
# that may have init requirements
( cd /home/git/regentmarkets/bom-backoffice && make i18n )

# Now sync up both the translations and the master
# branches, ensuring everything is committed and pushed.
# Some builds may not have any work to do, so we guard this
# with an `if` rather than letting it cause a failure.
if git commit -am 'i18n'; then
    git checkout master
    git pull --rebase
    git merge translations
    git push --all
fi

# At this point we can unlock Weblate and get things moving again
echo '{"lock":false}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/lock/
echo '{"operation":"pull"}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/repository/

