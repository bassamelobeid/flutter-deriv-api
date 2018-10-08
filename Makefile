M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -v --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
