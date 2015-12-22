v2:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v2

v3:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v3

structure:
	forkprove --timer -I./lib  -I./t t/BOM/*.t

load:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/load/v3

tidy:
	find . -name '*.p?.bak' -delete
	find lib t -name '*.p[lm]' -o -name '*.t' | xargs perltidy -pro=/home/git/regentmarkets/cpan/rc/.perltidyrc --backup-and-modify-in-place -bext=tidyup
	find . -name '*.tidyup' -delete
