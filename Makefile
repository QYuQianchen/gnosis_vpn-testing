# Makefile -- one-line wrappers, in the order docs/run.md uses them.  `make help`

SHELL  := /bin/bash
STATE  ?= $(HOME)/gvpn-state
STUDY  ?=
ARM    ?= pin-planner
FLOOR  ?=
VM     ?= vm
ORIGIN ?= origin
BRANCH ?= main
RUN    ?= $(shell ls -1dt $(STATE)/runs/*/ 2>/dev/null | head -1)
need_study = $(if $(STUDY),,$(error set STUDY=<name from studies/>))

.PHONY: help hooks test push status diagnose restore-config backup fix-perms \
        arms count dry trial preflight launch smoke report publish clean-runs

help:
	@echo "Mac"
	@echo "  make hooks                 pre-commit secret scan (once per clone)"
	@echo "  make test                  all test suites"
	@echo "  make push                  push to $(ORIGIN) and the VM"
	@echo "VM -- set up and check"
	@echo "  make status                what is installed; is a run in progress"
	@echo "  make diagnose              why the service is (not) running   [sudo]"
	@echo "  make restore-config        put the packaged network config back [sudo]"
	@echo "  make backup                encrypted identity backup           [sudo]"
	@echo "  make arms                  render the arms                     [sudo]"
	@echo "  make count ARM=<arm>       install an arm, count its routes    [sudo]"
	@echo "VM -- run a study"
	@echo "  make dry    STUDY=<name>   print the schedule and wall clock"
	@echo "  make trial  STUDY=<name>   rehearse: 1 cycle x 5 MB            [sudo]"
	@echo "  make preflight STUDY=<name>  checks + trial + floor calibration [sudo]"
	@echo "  make launch STUDY=<name>   preflight, then the real run, detached [sudo]"
	@echo "  make report                analyse the newest run"
	@echo "  make publish STUDY=<name>  copy the report into results/ to commit"
	@echo ""
	@echo "newest run: $(if $(RUN),$(RUN),<none>)"

hooks:
	@./tools/install-hooks.sh

test:
	@for t in tests/run-*-tests.sh; do bash "$$t" || exit 1; echo; done

# && on purpose: if GitHub rejects the push, the VM must not run unshared code.
push:
	git push $(ORIGIN) $(BRANCH) && git push $(VM) $(BRANCH)

status:
	@[ -e "$(STATE)/run.lock" ] && echo "RUN IN PROGRESS: $$(readlink $(STATE)/run.lock) (deploys blocked)" \
	  || echo "no run in progress"
	@echo "arms:    $$(ls $(STATE)/arms 2>/dev/null | tr '\n' ' ')"
	@echo "runs:    $$(ls -1 $(STATE)/runs 2>/dev/null | wc -l)"
	@echo "service: $$(systemctl is-active gnosisvpn)   config -> $$(readlink -f /etc/gnosisvpn/config.toml)"

diagnose:
	sudo -E ./tools/diagnose.sh

restore-config:
	sudo -E ./tools/restore-config.sh --apply

backup:
	sudo -E ./tools/backup-identity.sh

fix-perms:
	./tools/fix-worktree-ownership.sh --apply

arms:
	sudo -E ./setup/02-make-arms.sh

count:
	sudo -E ./bench/use-arm.sh $(ARM) --count

dry:
	$(need_study)
	GVPN_STUDY=$(STUDY) ./bench/gvpn-bench.sh --dry-run

trial:
	$(need_study)
	GVPN_STUDY=$(STUDY) sudo -E ./bench/gvpn-bench.sh --trial

preflight:
	$(need_study)
	sudo -E ./bench/preflight.sh --study $(STUDY)

launch:
	$(need_study)
	sudo -E ./bench/preflight.sh --study $(STUDY) --launch -y

smoke:
	sudo -E ./bench/gvpn-bench.sh --profile smoke

report:
	$(if $(RUN),,$(error no runs under $(STATE)/runs))
	python3 ./bench/gvpn-analyze.py "$(RUN)" $(if $(FLOOR),--floor-mbps $(FLOOR)) \
	        --markdown "$(RUN)/report.md" --csv "$(RUN)/sessions.csv"

# Raw logs stay on the VM; the findings are what must outlive it.
publish:
	$(need_study)
	$(if $(RUN),,$(error no runs under $(STATE)/runs))
	@mkdir -p results/$(STUDY)
	@cp "$(RUN)/report.md" "$(RUN)/summary.csv" "$(RUN)/manifest.json" results/$(STUDY)/
	@cp "$(RUN)/finished.json" results/$(STUDY)/ 2>/dev/null || true
	@echo "results/$(STUDY)/ ready -- review, then: git add results/$(STUDY) && git commit"

clean-runs:
	@find $(STATE)/runs -maxdepth 1 -mindepth 1 -type d -mtime +30 -print
	@echo "delete: find $(STATE)/runs -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +"
