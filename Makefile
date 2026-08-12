EMACS ?= $(shell command -v emacs 2>/dev/null)

ifeq ($(strip $(EMACS)),)
ifneq ($(wildcard /Applications/Emacs.app/Contents/MacOS/Emacs),)
EMACS := /Applications/Emacs.app/Contents/MacOS/Emacs
endif
endif

EL_FILES := $(sort $(wildcard bv*.el))
ELC_FILES := $(EL_FILES:.el=.elc)
TEST_FILES := $(sort $(wildcard tests/*.el))
PACKAGE_FILE ?= bv.el
PACKAGE_USER_DIR ?= $(CURDIR)/.packages
PREFIX ?= $(HOME)/.emacs.d
INSTALL_DIR ?= $(PREFIX)/site-lisp/bv-emacs
GIT_HOOKS_DIR := $(shell git rev-parse --git-path hooks 2>/dev/null)

.PHONY: all build test check checkdoc lint install clean \
	install-dev-dependencies install-pre-commit-hook pre-commit check-emacs

all: check

check-emacs:
	@test -n "$(EMACS)" || { \
		printf '%s\n' 'Emacs was not found; set EMACS=/path/to/emacs.' >&2; \
		exit 1; \
	}

build: check-emacs
	$(EMACS) --batch -Q -L . \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(EL_FILES)

test: build
	$(EMACS) --batch -Q -L . -L tests \
		--eval "(setq byte-compile-error-on-warn t)" \
		-f batch-byte-compile $(TEST_FILES)
	$(EMACS) --batch -Q -L . -L tests -l ert \
		$(foreach file,$(TEST_FILES),-l $(file)) \
		-f ert-run-tests-batch-and-exit

checkdoc: check-emacs
	$(EMACS) --batch -Q -L . -l checkdoc \
		--eval "(setq warning-minimum-level :error)" \
		$(foreach file,$(EL_FILES),--eval '(checkdoc-file "$(file)")')

lint: check-emacs
	@if $(EMACS) --batch -Q \
		--eval '(progn (setq package-user-dir "$(PACKAGE_USER_DIR)") \
			(require (quote package)) (package-initialize) \
			(kill-emacs (if (locate-library "package-lint") 0 1)))'; then \
		$(EMACS) --batch -Q -L . \
			--eval '(progn (setq package-user-dir "$(PACKAGE_USER_DIR)") \
				(require (quote package)) (package-initialize))' \
			-l package-lint \
			-f package-lint-batch-and-exit $(PACKAGE_FILE); \
	else \
		printf '%s\n' 'package-lint is not installed; skipping optional lint.'; \
	fi

install-dev-dependencies: check-emacs
	$(EMACS) --batch -Q \
		--eval '(setq package-user-dir "$(PACKAGE_USER_DIR)")' \
		--eval '(require (quote package))' \
		--eval '(add-to-list (quote package-archives) \
			(quote ("melpa" . "https://melpa.org/packages/")) t)' \
		--eval '(package-initialize)' \
		--eval '(unless package-archive-contents (package-refresh-contents))' \
		--eval '(unless (package-installed-p (quote package-lint)) \
			(package-install (quote package-lint)))'

check: checkdoc lint test

install: build
	install -d "$(DESTDIR)$(INSTALL_DIR)"
	install -m 644 $(EL_FILES) $(ELC_FILES) "$(DESTDIR)$(INSTALL_DIR)"

clean:
	$(RM) $(ELC_FILES) $(TEST_FILES:.el=.elc)

install-pre-commit-hook:
	@test -n "$(GIT_HOOKS_DIR)" || { \
		printf '%s\n' 'Not inside a Git working tree.' >&2; \
		exit 1; \
	}
	@mkdir -p "$(GIT_HOOKS_DIR)"
	@printf '%s\n' '#!/bin/sh' 'exec make check' \
		> "$(GIT_HOOKS_DIR)/pre-commit"
	@chmod +x "$(GIT_HOOKS_DIR)/pre-commit"
	@printf 'Installed %s\n' "$(GIT_HOOKS_DIR)/pre-commit"

pre-commit: install-pre-commit-hook
