# Xcode launched from the Dock hands its build tools a bare PATH — /usr/bin:/bin:/usr/sbin:/sbin —
# so a Homebrew or installer-packaged node is invisible and the build dies with a bare
# `env: node: No such file or directory`. These are the usual install locations, appended rather
# than prepended so a node that is already on PATH still wins.
export PATH := $(PATH):/opt/homebrew/bin:/usr/local/bin

# `build` and `install` are the goals Xcode's legacy target passes as $(ACTION).
build: all

install:

all: ./build/svgo.js

# webpack leaves the bundle alone when its contents would be identical, which keeps the file
# older than its inputs and makes make re-run webpack on every build. The touch settles it.
./build/svgo.js: ./node_modules/.bin/webpack index.js webpack.config.js
	./node_modules/.bin/webpack && touch ./build/svgo.js

# `check-node` is order-only: it is phony, so as a normal prerequisite it would count as
# forever out of date and re-run `npm install` on every single build.
./node_modules/.bin/webpack: package.json | check-node
	npm install && touch -c ./node_modules/.bin/webpack

# A missing toolchain is a setup problem, not a compile error, so say so in as many words.
# The check lives in the recipe because make 3.81 — the one macOS ships — does not export
# variables to `$(shell)` at parse time, only to recipes.
check-node:
	@command -v npm >/dev/null 2>&1 || { \
		echo "error: Node.js is required to build the SVGO tool, and npm was not found on PATH."; \
		echo "note: install it with 'brew install node', or from https://nodejs.org, then build again."; \
		exit 1; \
	}

clean:
	-rm -rf build node_modules

.PHONY: build install all clean check-node
