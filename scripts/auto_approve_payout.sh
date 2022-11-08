#!/bin/bash

logging_level=${LOG_LEVEL:-info}
sleep_duration=${SLEEP_DURATION_IN_SECONDS:-900}
enable_auto_approve=${ENABLE_AUTO_APPROVE:-0}

while true
do
    perl -Ilib /home/git/regentmarkets/bom-platform/scripts/auto_approve_payout.pl -l $logging_level --approve $enable_auto_approve
    status=$?
    if [ $status -eq 0 ]
    then
        echo "Sleeping for $sleep_duration seconds"
        sleep $sleep_duration
    else
        exit 1
    fi
done
