M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
export PERL5OPT=-MTest::FailWarnings=-allow_deps,1
export SKIP_EMAIL=1
I=-I$D/lib -I$D -I/home/git/regentmarkets/cpan/local/lib
P=/etc/rmg/bin/prove -v --timer $I
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) -r t/

tidy:
	find . -name '*.p?.bak' -delete
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
