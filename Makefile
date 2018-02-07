M=[ -t 1 ] && echo 'making \033[01;33m$@\033[00m' || echo 'making $@'
export PERL5OPT=-MTest::Warnings
P=/etc/rmg/bin/prove -v --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

test:
	@$(PROVE) $$(ls -1d t/BOM) t/999_redis_keys.t

json_schemas:
	@$(PROVE) /home/git/regentmarkets/bom-rpc/t/schema_suite/suite01.t /home/git/regentmarkets/bom-rpc/t/schema_suite/suite02.t

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
