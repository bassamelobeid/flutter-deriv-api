M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
D=$(CURDIR)
export SKIP_EMAIL=1
I=-I$D/lib -I$D -I/home/git/regentmarkets/cpan/local/lib
P=/etc/rmg/bin/prove -v --timer $I
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) -r t/

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax_lib:
	SYNTAX_CHUNK_NAME=lib /etc/rmg/bin/prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/002_autosyntax.t t/BOM/001_structure.t

