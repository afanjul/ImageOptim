build: all

all: guetzli/src .patched opencl/clba_kernels.h

guetzli/src: ../.gitmodules
	../scripts/fetch-submodule guetzli && touch guetzli/src

# The OpenCL port lives in opencl/, but it needs three hooks inside butteraugli
# itself. They are carried as a patch so the submodule stays pinned to pristine
# google/guetzli 214f2bb; the header of the patch says what each hunk is for.
.patched: opencl/butteraugli-opencl.patch guetzli/src
	cd guetzli && if git apply -R --check ../opencl/butteraugli-opencl.patch >/dev/null 2>&1; then \
		echo "guetzli: butteraugli-opencl.patch already applied"; \
	else \
		git apply --verbose ../opencl/butteraugli-opencl.patch; \
	fi
	touch .patched

# Part of the kernel source is lifted verbatim out of butteraugli.cc, so the
# header that embeds it is generated at build time rather than committed: it
# cannot then drift away from the code it was lifted from.
opencl/clba_kernels.h: opencl/gen_kernels.py opencl/kernels.cl .patched
	python3 opencl/gen_kernels.py

clean:
	rm -f .patched guetzli/src opencl/clba_kernels.h opencl/kernels_gen.cl

.PHONY: build all install clean
