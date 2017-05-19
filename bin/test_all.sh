#!/bin/sh
MAIN_DIR=/home/git/regentmarkets
for d in `ls $MAIN_DIR`
do
    WORKDIR=$MAIN_DIR/$d
    MAKEFILE=$WORKDIR/Makefile
    if [ -f $MAKEFILE ] && grep -q '^test:$' $MAKEFILE
    then
        (cd $WORKDIR && make test)
    fi
done
