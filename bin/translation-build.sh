#!/bin/bash
set -e

cd /home/git/binary-com/translations-websockets-api

# This script will merge translations from the translations branch to master - the translations are
# added to the translations branch via an integration in crowdin 

# Pull current status - this should give us a clean
# starting point from which to run a build
git config user.name "Automated translations build"
git config user.email "sysadmin@binary.com"
git checkout master
git pull --rebase
git remote set-branches --add origin translations
# fetch whole history for translations
# else it will lead to
# fatal: refusing to merge unrelated histories error
git fetch origin translations
git checkout translations
git pull --rebase
git merge origin/master

# Crowdin can not read and write to the same branch. It reads from translations, and writes to 
# l10n_translations (this is configured as an integration in crowdin).
git remote set-branches --add origin l10n_translations
git fetch origin l10n_translations
git remote -v
git branch -a
git fetch --prune
git branch -a
git merge origin/l10n_translations

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
