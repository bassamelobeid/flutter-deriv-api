tidy:
	find . -name '*.p?.bak' -delete
	find v3 t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete

test:
	@echo 'This is a dummy test'
	@echo 'Please run make test under binary-websocket-api'
