#!/bin/sh
MAIN_DIR=/home/git/regentmarkets
for d in `ls $MAIN_DIR`
do
    WORKDIR=$MAIN_DIR/$d
    MAKEFILE=$WORKDIR/Makefile
    if [ -d $WORKDIR ] && [ -f $MAKEFILE ] && grep -q '^test:$' $MAKEFILE
    then
        make -C $WORKDIR test
    fi
done
