TESTS=test unit syntax 

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
export SKIP_EMAIL=1
P=/etc/rmg/bin/prove -lvr --timer 
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test_all: $(TESTS)

test:
	@$(PROVE) t/BOM

tidy:
	find . -name '*.p?.bak' -delete
	# Account type modules are excluded temporarily, because perltidy doesn't recognize Object::Pad field attributes like ':reader'.
	find . -not -path "./.git*" -name '*.p[lm]' -o -name '*.t' | xargs perltider -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

syntax_diff:
	@$(PROVE) --norc $$(ls t/*.t | grep -v syntax_all)

syntax:
	@$(PROVE) --norc t/*.t

pod_test:
	@$(PROVE) --norc t/*pod*.t

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc t/BOM t/unit
	cover -report coveralls

unit:
	@$(PROVE) t/unit/
