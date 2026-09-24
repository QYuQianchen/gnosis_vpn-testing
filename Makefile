# Makefile -- the commands that would otherwise be retyped and mistyped.
#
#   make help
#
# Every target is a one-liner you could run by hand; the point is that the
# version everyone runs is the one in the repo, not the one in someone's history.

SHELL   := /bin/bash
KIT     := $(shell pwd)
STATE   ?= $(HOME)/gvpn-state
STUDY   ?=
FLOOR   ?=
VM      ?= vm
ORIGIN  ?= origin
BRANCH  ?= main

# Newest run in the state directory -- what `make report` reads by default.
RUN ?= $(shell ls -1dt $(STATE)/runs/*/ 2>/dev/null | head -1)

.PHONY: help push test hooks smoke dry trial preflight soak report publish arms status clean-runs backup fix-perms codes

help:
	@echo "make hooks         install the pre-commit secret scan (once per clone)"
	@echo "make test          run the scanner and analyzer tests"
	@echo "make push          push $(BRANCH) to $(ORIGIN) and $(VM)"
	@echo "make status        what is installed and whether a run is in progress"
	@echo "make backup        encrypted, verified identity backup      [VM, sudo]"
	@echo "make codes         faucet codes: how many left, what was spent [VM]"
	@echo "make fix-perms     clear root-owned leftovers blocking a deploy [VM]"
	@echo "make arms          render arm templates into $(STATE)/arms   [VM, sudo]"
	@echo "make dry           print the schedule without running it     [VM]"
	@echo "make smoke         10-minute rig check                       [VM, sudo]"
	@echo "make trial STUDY=<name>    this study at 1 cycle x 5 MB      [VM, sudo]"
	@echo "make preflight STUDY=<name>  checks + trial + calibrate      [VM, sudo]"
	@echo "make launch STUDY=<name>     preflight, then run it for real [VM, sudo]"
	@echo "make soak STUDY=<name>   the real run, detached              [VM, sudo]"
	@echo "make report        analyse the newest run (floor from the study's manifest)"
	@echo "                   FLOOR=<n> overrides it, and the report says so"
	@echo "make publish STUDY=<name>  copy that report into results/ to commit"
	@echo ""
	@echo "newest run: $(if $(RUN),$(RUN),<none>)"

# --------------------------------------------------------------- local side --

hooks:
	@./tools/install-hooks.sh

test:
	@./tests/run-scan-tests.sh
	@echo
	@./tests/run-analyze-tests.sh

# One command, two remotes. `&&` rather than `;` on purpose: if GitHub rejects the
# push, the VM must not end up running code that is not in the shared history.
push:
	git push $(ORIGIN) $(BRANCH) && git push $(VM) $(BRANCH)

# ------------------------------------------------------------------ VM side --

status:
	@echo "kit:   $(KIT)"
	@echo "state: $(STATE)"
	@if [ -e "$(STATE)/run.lock" ]; then \
	  echo "RUN IN PROGRESS: $$(readlink $(STATE)/run.lock)"; \
	  echo "  (deploys are blocked until it finishes)"; \
	else echo "no run in progress"; fi
	@echo "arms:  $$(ls $(STATE)/arms 2>/dev/null | tr '\n' ' ')"
	@echo "runs:  $$(ls -1 $(STATE)/runs 2>/dev/null | wc -l) recorded"
	@gnosis_vpn-ctl info 2>/dev/null | head -2 || true

backup:
	sudo -E ./tools/backup-identity.sh

codes:
	@./tools/faucet-codes.sh

fix-perms:
	./tools/fix-worktree-ownership.sh --apply

arms:
	sudo -E ./setup/02-make-arms.sh

# No --profile here: the study file's GVPN_PROFILE decides, so the dry run
# prints the schedule the real run will use. Hardcoding soak made every study
# dry-run as a 36-hour matrix regardless of what it had asked for.
dry:
	$(if $(STUDY),GVPN_STUDY=$(STUDY) )./bench/gvpn-bench.sh --dry-run

smoke:
	sudo -E ./bench/gvpn-bench.sh --profile smoke

# The study you are about to run, shrunk to one cycle of 5 MB transfers. Same
# arms, same exits: a rehearsal of THIS study rather than a different, smaller
# one. The analyzer marks the result un-scoreable so it cannot be quoted.
trial:
	$(if $(STUDY),,$(error set STUDY=<name from studies/>))
	GVPN_STUDY=$(STUDY) sudo -E ./bench/gvpn-bench.sh --trial

# Everything before the long run: static checks, a route count per arm, the
# trial, and the floor calibration. Stops without launching.
preflight:
	$(if $(STUDY),,$(error set STUDY=<name from studies/>))
	sudo -E ./bench/preflight.sh --study $(STUDY)

# The same, and then launches the full study detached.
launch:
	$(if $(STUDY),,$(error set STUDY=<name from studies/>))
	sudo -E ./bench/preflight.sh --study $(STUDY) --launch -y

soak:
	$(if $(STUDY),,$(error set STUDY=<name from studies/>))
	GVPN_STUDY=$(STUDY) sudo -E ./bench/gvpn-bench.sh --detach

# ------------------------------------------------------------------- output --

report:
	$(if $(RUN),,$(error no runs under $(STATE)/runs))
	python3 ./bench/gvpn-analyze.py "$(RUN)" $(if $(FLOOR),--floor-mbps $(FLOOR)) \
	        --markdown "$(RUN)/report.md" --csv "$(RUN)/sessions.csv"

# Promote a finished run's small, durable part into the repo. Raw logs stay on the
# VM and get deleted when the disk fills; the findings are what must outlive it.
publish:
	$(if $(STUDY),,$(error set STUDY=<name from studies/>))
	$(if $(RUN),,$(error no runs under $(STATE)/runs))
	@mkdir -p results/$(STUDY)
	@cp "$(RUN)/report.md" "$(RUN)/summary.csv" "$(RUN)/manifest.json" results/$(STUDY)/
	@cp "$(RUN)/finished.json" results/$(STUDY)/ 2>/dev/null || true
	@./tools/scan-secrets.sh --tracked >/dev/null || true
	@echo "results/$(STUDY)/ ready -- review, then: git add results/$(STUDY) && git commit"

clean-runs:
	@echo "runs older than 30 days under $(STATE)/runs:"
	@find $(STATE)/runs -maxdepth 1 -mindepth 1 -type d -mtime +30 -print
	@echo "delete them with: find $(STATE)/runs -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +"
