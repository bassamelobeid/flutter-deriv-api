v3_1:
	bash -c 'PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib -I/home/git/regentmarkets/bom-websocket-tests/lib -r /home/git/regentmarkets/bom-websocket-tests/v3/{0,1,2,4}*'

v3_2:
	bash -c 'PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib -I/home/git/regentmarkets/bom-websocket-tests/lib -r /home/git/regentmarkets/bom-websocket-tests/v3/{5,6,7}*'

v3_3:
	bash -c 'PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib -I/home/git/regentmarkets/bom-websocket-tests/lib -r /home/git/regentmarkets/bom-websocket-tests/v3/{8,9}*'

json_schema:
	PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib -I/home/git/regentmarkets/bom-websocket-tests/lib /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/suite.t

loadtest:
	bash -c 'prove --timer -I./lib -I/home/git/regentmarkets/bom-websocket-tests/lib /home/git/regentmarkets/bom-websocket-tests/v3/schema_suite/loadtest.t'

structure:
	PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib t/*.t

leaktest:
	PERL5OPT="-MTest::FailWarnings=-allow_deps,1" /etc/rmg/bin/prove --timer -I./lib -r t/leak/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
