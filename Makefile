TESTS=unit_test_platform_client \
      unit_test_platform_all \
      unit_test_system
M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
export SKIP_EMAIL=1
P=/etc/rmg/bin/prove -v --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test: $(TESTS)

test_all: test

unit_test_platform_client:
	@$(PROVE) -r t/BOM/Platform/Client/

unit_test_platform_all:
	@$(PROVE) -r $$(ls -1d t/BOM/Platform/* | grep -v -e /Client)

unit_test_system:
	@$(PROVE) -r t/BOM/System/

leaktest:
	$(PROVE) -r t/BOM/leaks

tidy:
	find . -name '*.p?.bak' -delete
	. /etc/profile.d/perl5.sh;find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax_lib:
	SYNTAX_CHUNK_NAME=lib /etc/rmg/bin/prove -I./lib -I/home/git/regentmarkets/bom-postgres/lib t/002_autosyntax.t t/BOM/001_structure.t

