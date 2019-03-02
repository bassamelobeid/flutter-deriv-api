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
git checkout translations
git pull --rebase

# This is the build itself - note that Redis may
# need to be running, since we load various modules
# that may have init requirements
( cd /home/git/regentmarkets/bom-backoffice && make i18n )

# Now sync up both the translations and the master
# branches, ensuring everything is committed and pushed
git commit -am 'i18n'
git checkout master
git pull --rebase
git merge translations
git push --all

# At this point we can unlock Weblate and get things moving again
echo '{"lock":false}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/lock/
echo '{"operation":"pull"}' | curl -X POST -d '@-' -H "Content-Type: application/json" -H "Authorization: Token $WEBLATE_TOKEN" https://hosted.weblate.org/api/components/binary-websocket/translations/repository/

