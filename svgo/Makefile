# `build` and `install` are the goals Xcode's legacy target passes as $(ACTION).
build: all

install:

all: ./build/svgo.js

./build/svgo.js: ./node_modules/.bin/webpack index.js webpack.config.js
	./node_modules/.bin/webpack

./node_modules/.bin/webpack: package.json
	npm install && touch -c ./node_modules/.bin/webpack

clean:
	-rm -rf build node_modules

.PHONY: build install all clean
