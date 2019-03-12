M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -v --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@$(PROVE) -r t/BOM/

syntax:
	SYNTAX_CHUNK_NAME=lib /etc/rmg/bin/prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/001_structure.t t/003_autosyntax.t
