M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
MOJO_LOG_LEVEL?=info
export MOJO_LOG_LEVEL
P=/etc/rmg/bin/prove --timer -v -rl

PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

accounts:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/accounts

security:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/security

streams:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/streams

misc:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/misc

structure_and_schemas:
	@$(PROVE) t /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite

test: structure_and_schemas accounts security streams misc

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
