v2:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v2

v3:
	forkprove --timer -I./lib  -I./t -r t/BOM/WebsocketAPI/v3

structure:
	forkprove --timer -I./lib  -I./t -t/BOM/*.t
