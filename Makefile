
FILES = src/stomp.nim
CACHE = .cache

default: development

development: ${FILES}
	nim --debugInfo --assertions:on --profiler:on --stackTrace:on --linedir:on -d:ssl --define:debug --nimcache:${CACHE} c ${FILES}
	@mv src/stomp .

autobuild:
	# find . -depth 1 -name \*.nim | entr -cp make
	echo ${FILES} | entr -c make

debugger: ${FILES}
	nim --debugger:on --nimcache:${CACHE} c ${FILES}

release: ${FILES}
	nim -d:release --opt:speed --panics:on --nimcache:${CACHE} c ${FILES}
	@mv src/stomp .

docs:
	nim doc ${FILES}
	#nim buildIndex ${FILES}

clean:
	cat .hgignore | xargs rm -rf

