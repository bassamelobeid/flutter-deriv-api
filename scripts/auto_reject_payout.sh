#!/bin/bash

logging_level=${LOG_LEVEL:-info}
sleep_duration=${SLEEP_DURATION_IN_SECONDS:-900}
enable_auto_reject=${ENABLE_AUTO_REJECT:-0}

while true
do
    perl -Ilib /home/git/regentmarkets/bom-platform/scripts/auto_reject_payout.pl -l $logging_level --reject $enable_auto_reject
    status=$?
    if [ $status -eq 0 ]
    then
        echo "Sleeping for $sleep_duration seconds"
        sleep $sleep_duration
    else
        exit 1
    fi
done
