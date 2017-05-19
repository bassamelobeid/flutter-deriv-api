#!/usr/bin/sh
MAIN_DIR=/home/git/regentmarkets
for d in `ls $MAIN_DIR`
do
    if [ -f $MAIN_DIR/$d/Makefile && grep '^test:$']
    then
        (cd $d; make test)
    fi
done
