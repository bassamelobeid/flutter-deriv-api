#################### Makefile Command Documentation ####################
## https://github.com/regentmarkets/development-workflow/blob/master/Makefile.md
########################################################################

M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
P=/etc/rmg/bin/prove -v --timer -rl
PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

syntax:
	@$(PROVE) t/BOM/*.t t/999_redis_keys.t

test:
	@$(PROVE) $$(ls -1d t/BOM/RPC/) t/000_async_await.t t/999_redis_keys.t

pod_test:
	@$(PROVE) t/BOM/*pod*.t

json_schemas:
	@$(PROVE) /home/git/regentmarkets/bom-rpc/t/schema_suite/suite01.t /home/git/regentmarkets/bom-rpc/t/schema_suite/suite02.t

tidy:
	find . -name '*.p?.bak' -delete
	find bin lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

cover:
	cover -delete
	HARNESS_PERL_SWITCHES=-MDevel::Cover DEVEL_COVER_OPTIONS=-'ignore,^t/' /etc/rmg/bin/prove --timer -rl --norc -MBOM::Test -It/lib t/BOM/RPC/
	cover -report coveralls

