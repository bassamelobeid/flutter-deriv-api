M=[ -t 1 ] && echo -e 'making \033[01;33m$@\033[00m' || echo 'making $@'
MOJO_LOG_LEVEL?=info
export MOJO_LOG_LEVEL
P=/etc/rmg/bin/prove --timer -v -rl

PROVE=p () { $M; echo '$P' "$$@"; $P "$$@"; }; p

accounts:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/accounts

streams:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/streams

misc:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/misc

json_schemas:
	@$(PROVE) /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite

structure:
	@$(PROVE) t/*.t

test: structure v3_1 v3_2 v3_3 json_schemas

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
