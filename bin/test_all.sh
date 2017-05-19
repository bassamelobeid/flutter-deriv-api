#!/bin/sh
MAIN_DIR=/home/git/regentmarkets
for d in `ls $MAIN_DIR`
do
    MAKEFILE=$MAIN_DIR/$d/Makefile
    if [ -f $MAKEFILE ] && grep '^test:$' $MAKEFILE
    then
        (cd $d; make test)
    fi
done
