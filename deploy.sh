#!/bin/bash
#
# deploy.sh — three-attempt Ansible runner with hybrid retry scope.
#
# Attempt 1: full site.yml against every host
# Attempt 2: --limit @retry-file (failed hosts only) if a retry file exists
# Attempt 3: full playbook again (safety net if retry-scoped attempt didn't cover
#            a cross-host dependency)
#
# --forks 40 (up from Ansible default 5) so full sweeps parallelize
# aggressively across the ~30-host PowerPlant fleet. Controller has enough
# headroom (2-4 vCPU on the SimSpace VM); 40 concurrent workers is a
# comfortable middle ground and matches the airfield-range deploy.sh.

# site.yml is a WRAPPER, not a play in its own right. It imports
# playbooks/00-baseline.yml (the range baseline, phase 0) and then the nine
# Security Onion phases: 05-time, 10-mirror, 20-vyos, 30-prereqs,
# 40-manager, 50-nodes, 60-verify, 70-analyst, 75-endpoint.
#
# Setting this to playbooks/00-baseline.yml would still run and still report
# success -- while silently skipping every SO phase, including the mirror
# the SO nodes fetch their source and container images from. Keep it
# pointed at the wrapper.
#
# Run a single phase directly during development; re-running the full range
# playbook to test an SO change is slow:
#     ansible-playbook playbooks/40-manager.yml
PLAYBOOK="site.yml"
# Ansible names the retry file after the playbook with the EXTENSION STRIPPED
# (site.yml -> site.retry), so this has to strip it too. Built as
# "$PLAYBOOK.retry" it yields site.yml.retry, which never exists -- and the
# `[ -f "$RETRY_FILE" ]` guard below then reads that as "no retry file was
# produced" and silently falls through to a full sweep. Attempt 2 had never
# once been retry-scoped. Caught on airfield 2026-09-15.
RETRY_FILE="retry/$(basename "${PLAYBOOK%.*}").retry"
MAX_ATTEMPTS=3
# FORKS is DERIVED, not chosen: it is the largest single play target plus a
# small margin. Recomputed 2026-09-08.
#
#   largest play target : 53  (windows,linux)  -- 54 once pp-ot-malcolm lands
#   FORKS               : 56
#
# Recounted 2026-09-12 on re-sync from ss-pp-so. Splunk removal took
# pp-splunk out of [ubuntu22] -> [linux], dropping the target to 53;
# pp-ot-malcolm will join [linux] and take it to 54. 56 leaves margin for
# both. RECOUNT when pp-ot-malcolm actually lands, do not assume.
#
# Sized so the widest play runs in ONE batch. At 40 forks a 54-host play
# ran two rounds -- the second only 14 wide -- and those are the long plays.
# The margin is free: Ansible never spawns more workers than the play has
# hosts, so excess forks cost nothing, while being one short costs a whole
# extra round.
#
# TRADEOFF: each fork is a separate Python process, so this is a memory
# question rather than a CPU one -- workers are almost always blocked on
# WinRM/SSH I/O, not computing. The controller has ~32 GB; 56 forks is a
# few GB resident. If it starts swapping during a full sweep, drop this
# rather than assuming the deploy is slow for another reason.
#
# RECOUNT, do not increment, when hosts are added or removed. Adding a host
# to [windows] or [linux] moves the target this is derived from.
FORKS=56

# --- Speed knobs -------------------------------------------------------------
# Trims 5-10 minutes off a full-fleet run vs Ansible defaults.
#   ANSIBLE_PIPELINING=True     — one SSH exec per task on Linux instead of
#                                 three (open/exec/close). Safe on SimSpace
#                                 images (requiretty is off by default).
#                                 No effect on Windows/WinRM.
#   ANSIBLE_GATHERING=smart     — Gather facts once per host per run; skip
#                                 subsequent plays that also gather. Ansible
#                                 remembers what it already gathered.
#   ANSIBLE_CACHE_PLUGIN=jsonfile + fact_cache dir + 24h TTL — persist facts
#                                 across runs, so back-to-back deploys don't
#                                 re-gather on unchanged hosts.
export ANSIBLE_PIPELINING=True
export ANSIBLE_GATHERING=smart
export ANSIBLE_CACHE_PLUGIN=jsonfile
export ANSIBLE_CACHE_PLUGIN_CONNECTION="$HOME/.ansible/fact_cache"
export ANSIBLE_CACHE_PLUGIN_TIMEOUT=86400
mkdir -p "$ANSIBLE_CACHE_PLUGIN_CONNECTION"

# --- Unattended prerequisites -------------------------------------------------
# This deploy is driven by the range BLUEPRINT: the platform spins the images,
# pulls the tarball from GitHub and extracts it, then runs this script. Nobody
# is at a keyboard. Anything that would previously have been a "now run these
# three commands by hand" instruction has to be done here instead.
#
# Two things the extraction leaves wrong:
#   * /etc/ansible/retry — the tarball extracts as root, so the ansible user
#     cannot write retry files. Previously every failed run printed
#     "Could not create retry file ... Permission denied" and attempt 2 lost
#     its retry-file scope, silently degrading to a full sweep.
#   * /home/simspace/.vault_pass — the password file and its value are placed
#     by the platform, but not necessarily with ownership and mode the ansible
#     user can read. 0600 root:root is unreadable to simspace, and every
#     vaulted variable in the repo resolves through it.
#
# `sudo -n` throughout: non-interactive, so a sudo password prompt FAILS
# immediately rather than hanging a headless deploy forever waiting on stdin.
ANSIBLE_OWNER="${ANSIBLE_OWNER:-simspace}"
VAULT_PASS_FILE="${VAULT_PASS_FILE:-/home/simspace/.vault_pass}"
RETRY_DIR="${RETRY_DIR:-/etc/ansible/retry}"

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	else
		sudo -n "$@"
	fi
}

# ASSERT THE END STATE UNCONDITIONALLY. An earlier version skipped the chown
# when the path merely looked fine for the CURRENT user -- and a
# blueprint-driven deploy runs as root, for whom everything is writable. The
# chown was therefore skipped on exactly the run it was written for, leaving
# /etc/ansible/retry as root:root (observed 2026-08-05).
#
# The requirement is an end state -- owned by the ansible user -- not "writable
# by whoever happens to be running". chown/chmod are idempotent and cost
# milliseconds; there is no reason to guess whether they are needed.
owner_of() {
	# GNU first (the controller is Ubuntu), BSD fallback so this is testable
	# on a developer Mac.
	stat -c %U "$1" 2>/dev/null || stat -f %Su "$1" 2>/dev/null || echo "unknown"
}

# --- Elapsed-time accounting -------------------------------------------------
# Reported through an EXIT trap rather than at the bottom of the script, because
# the bottom is only reached on two of the three ways this ends. The third --
# someone killing a run that has stopped making progress -- is the one where
# knowing the elapsed time matters most, and it never reaches the last line.
#
# Two clocks, because they answer different questions:
#   ansible elapsed   what was asked for: first attempt start -> finish
#   pre-ansible       galaxy install + BOOT_DELAY, several minutes of wall clock
#                     that is not Ansible and should not be blamed on it
SCRIPT_START=$(date +%s)
ANSIBLE_START=""
DEPLOY_RESULT="interrupted before Ansible started"

fmt_elapsed() {
	local s=$1
	printf '%dh %02dm %02ds' $((s / 3600)) $(((s % 3600) / 60)) $((s % 60))
}

report_elapsed() {
	rc=$?
	now=$(date +%s)
	echo
	echo "================== deploy.sh timing =================="
	if [ -n "$ANSIBLE_START" ]; then
		printf '  ansible elapsed  : %s\n' "$(fmt_elapsed $((now - ANSIBLE_START)))"
		printf '  pre-ansible      : %s   (galaxy + BOOT_DELAY)\n' \
			"$(fmt_elapsed $((ANSIBLE_START - SCRIPT_START)))"
	else
		printf '  ansible elapsed  : never started\n'
	fi
	printf '  total wall clock : %s\n' "$(fmt_elapsed $((now - SCRIPT_START)))"
	printf '  outcome          : %s\n' "$DEPLOY_RESULT"
	echo "====================================================="

	# Printed for EVERY attempt that produced failures, including on a run that
	# ultimately succeeded. A build that passes on attempt 3 still failed twice,
	# and those two failures are the only evidence of what is not yet reliable.
	# Suppressing them on success is how "succeeds on attempt 3" became normal.
	#
	# Runs inside the EXIT trap, so it also prints when a run is interrupted --
	# which is the case where knowing what had already gone wrong matters most
	# and where the summary would otherwise never be reached.
	if [ -d "${ATTEMPT_LOG_DIR:-/nonexistent}" ]; then
		summary="$(summarize_failures 2>/dev/null)"
		if [ -n "$summary" ]; then
			echo
			echo "================== failures by attempt =============="
			printf '%s\n' "$summary"
			echo
			echo "  Full output per attempt: $ATTEMPT_LOG_DIR/deploy-attempt-N.log"
			echo "====================================================="
		fi
	fi
	exit $rc
}
trap report_elapsed EXIT
trap 'DEPLOY_RESULT="INTERRUPTED by signal"; exit 130' INT TERM

echo "=== Asserting prerequisites the platform is responsible for ==="

# retry dir — the tarball extracts as root, so this lands root-owned. Without
# the fix a failed attempt 1 cannot write its retry file, and attempt 2 loses
# retry-file scope and silently degrades to a full sweep.
as_root mkdir -p "$RETRY_DIR" 2>/dev/null || true
# Failures are deliberately silent here: what matters is the END STATE,
# checked immediately below. Reporting "chown failed" when the ownership was
# already correct is the same proxy-versus-claim mistake catalogued all
# through this log.
as_root chown -R "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$RETRY_DIR" 2>/dev/null || true
as_root chmod 0755 "$RETRY_DIR" 2>/dev/null || true

# Verify the END STATE, not that the commands ran.
retry_owner="$(owner_of "$RETRY_DIR")"
if [ "$retry_owner" = "$ANSIBLE_OWNER" ]; then
	echo "  $RETRY_DIR owned by $ANSIBLE_OWNER"
else
	echo "  WARN: $RETRY_DIR still owned by '$retry_owner', wanted '$ANSIBLE_OWNER'"
	echo "        Retry-file scoping will be lost on a failed attempt; deploy continues."
fi

# vault password file — placed by the blueprint with its value, but not
# necessarily with ownership and mode the ansible user can read.
if [ -f "$VAULT_PASS_FILE" ]; then
	as_root chown "$ANSIBLE_OWNER:$ANSIBLE_OWNER" "$VAULT_PASS_FILE" 2>/dev/null || true
	as_root chmod 0600 "$VAULT_PASS_FILE" 2>/dev/null || true
	vault_owner="$(owner_of "$VAULT_PASS_FILE")"
	if [ "$vault_owner" = "$ANSIBLE_OWNER" ]; then
		echo "  $VAULT_PASS_FILE owned by $ANSIBLE_OWNER, mode 0600"
	else
		echo "  WARN: $VAULT_PASS_FILE still owned by '$vault_owner'"
	fi
fi

# --- Vault guard -------------------------------------------------------------
# Refuse to deploy if the vault is missing or plaintext. Written FAIL-CLOSED on
# purpose: the equivalent guard in so-ansible was
#   if [ -f <path> ] && ! head -1 <path> | grep -q '^$ANSIBLE_VAULT'
# and a MISSING file short-circuited the whole test to false, so it passed on
# every run and had never once fired. A plaintext vault would have shipped
# silently. Two separate checks here, both fatal.
VAULT_FILE="group_vars/all/vault.yml"

if [ ! -f "$VAULT_FILE" ]; then
	echo "ERROR: $VAULT_FILE not found. Refusing to deploy."
	echo "       Every credential in this repo resolves through it."
	exit 1
fi

if ! head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT'; then
	echo "ERROR: $VAULT_FILE is plaintext. Refusing to deploy."
	echo "       Re-encrypt: ansible-vault encrypt $VAULT_FILE"
	exit 1
fi

if [ ! -f "$VAULT_PASS_FILE" ]; then
	echo "ERROR: $VAULT_PASS_FILE not found. Refusing to deploy."
	echo "       The range blueprint is responsible for placing this file and"
	echo "       its value on the controller; it does NOT persist across"
	echo "       spin-ups. If the blueprint is not doing that, fix it there —"
	echo "       a hands-off deploy cannot prompt for it."
	exit 1
fi

# READABILITY, not existence. The chown/chmod above may have failed (sudo -n
# is deliberately non-interactive), and a file that exists but cannot be read
# fails later as a confusing vault decrypt error on the first vaulted variable
# rather than here. Test what actually matters: can THIS process read it?
if ! head -c1 "$VAULT_PASS_FILE" >/dev/null 2>&1; then
	echo "ERROR: $VAULT_PASS_FILE exists but is not readable by $(id -un)."
	echo "       Ownership/mode could not be corrected — check that the"
	echo "       deploy account has passwordless sudo, or have the blueprint"
	echo "       place the file as $ANSIBLE_OWNER:$ANSIBLE_OWNER mode 0600."
	ls -l "$VAULT_PASS_FILE" 2>&1 | sed 's/^/       /'
	exit 1
fi

# And that it is not empty -- an empty password file decrypts nothing and the
# error surfaces far from here.
if [ ! -s "$VAULT_PASS_FILE" ]; then
	echo "ERROR: $VAULT_PASS_FILE is empty. Refusing to deploy."
	exit 1
fi

# --- Install Galaxy collections (idempotent — skips already-installed ones) ---
# Required for the pfsensible.core collection that drives the pp-ot-firewall
# pfSense play. Pulled through the corp proxy because the Ansible VM doesn't
# have direct internet. Failure here doesn't abort the deploy — ansible-playbook
# will surface a clear "collection not found" error if anything's actually missing.
#
# NOTE: a `sleep 120` here was removed 2026-07-02 in a speed pass, reasoning
# that the retry loop already handles a VM that is not ready yet. RESTORED
# 2026-08-05 at 180s, because that reasoning did not survive contact with a
# fresh range: the first two attempts of a from-scratch deploy both failed on
# hosts that had not finished booting, and "the retry loop handles it" meant
# paying for two full multi-hour sweeps to discover that. A three-minute wait
# is cheap against a ~5-hour deploy; two wasted passes are not.


#
# BOOT_DELAY is overridable so iterative deploys need not pay it -- which was
# the legitimate half of the 2026-07-02 argument:
#     BOOT_DELAY=0 ./deploy.sh
# THE COLLECTIONS PATH IS PINNED AND EXPORTED, so ansible-galaxy and
# ansible-playbook cannot disagree about where collections live.
#
# ss-pp-stacked 2026-09-02, on a fresh controller. galaxy reported success:
#     Installing 'pfsensible.core:0.7.1' to
#     '/root/.ansible/collections/ansible_collections/pfsensible/core'
# and then all three deploy attempts died in two seconds with
#     ERROR! couldn't resolve module/action 'pfsensible.core.pfsense_setup'
#
# The install WORKED and the collection was still unusable, because the
# directory it landed in is not one the playbook run searches -- and is not
# readable by the deploy account anyway. "Installed" and "resolvable" are two
# different claims and only the second one matters here. requirements.yml's
# own header used to recommend `sudo ansible-galaxy ...`, which is precisely
# how a collection ends up in root's home; that line is corrected too.
#
# The other four collections masked the fault for months: they ship inside the
# ansible package in site-packages, so galaxy says "already installed,
# skipping" and they resolve at runtime regardless of this path.
# pfsensible.core is the only one that must actually be fetched, so it was the
# only one that could break.
#
# /usr/share/ansible/collections is kept on the path so a site-wide install
# still counts. Collections bundled in site-packages are found by the loader
# independently of this variable.
COLLECTIONS_DIR="${HOME}/.ansible/collections"
export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_DIR}:/usr/share/ansible/collections"

echo "=== Checking for Ansible Galaxy collections ==="

# VENDORED ARTIFACTS FIRST. Galaxy is a FALLBACK, not the primary path.
#
# Every deploy used to fetch pfsensible.core from galaxy.ansible.com through
# the corp proxy. That is a bet re-placed on every single deploy: if galaxy is
# unreachable, or ships a different version with changed module behaviour, the
# deploy fails or behaves differently -- and the controller is rebuilt fresh
# for every range, so the bet is never amortised.
#
# It already cost three attempts on 2026-09-02, when the fetch SUCCEEDED and
# installed into a directory the playbook could not read.
#
# collections/ ships pinned artifacts in the tarball. Installing from a local
# file is offline, version-locked and reproducible. The galaxy call below still
# runs for anything not vendored; on a healthy controller that is a no-op
# ("already installed, skipping") because vyos.vyos, ansible.netcommon and
# ansible.posix come with the ansible package itself.
if compgen -G "collections/*.tar.gz" > /dev/null 2>&1; then
	echo "=== Installing VENDORED collections (offline, version-pinned) ==="
	for _c in collections/*.tar.gz; do
		echo "    $_c"
		ansible-galaxy collection install "$_c" -p "$COLLECTIONS_DIR" 2>&1 \
			|| echo "WARN: could not install $_c; continuing"
	done
fi

if [ -f requirements.yml ]; then
	echo "=== Galaxy fallback for anything not vendored ==="
	echo "    target: $COLLECTIONS_DIR"
	HTTPS_PROXY="http://10.255.240.1:3128" \
		ansible-galaxy collection install -r requirements.yml -p "$COLLECTIONS_DIR" 2>&1 \
		|| echo "WARN: galaxy install returned non-zero; continuing"
fi

# --- Prove the playbook PARSES before spending hours on it -------------------
# This is the exact operation that failed on 2026-09-02, run here as a gate
# instead of being discovered three attempts later. A parse failure is
# deterministic -- it fails identically on attempts 2 and 3 -- so retrying it
# is pure waste. That run burned three attempts plus a 180s BOOT_DELAY to
# learn nothing, and the log could not even say what had gone wrong.
#
# Note the ordering: BEFORE the boot delay, so a broken tree costs seconds
# rather than three minutes.
echo "=== Syntax check ==="
if ! ansible-playbook "$PLAYBOOK" --syntax-check 2>&1; then
	cat <<-ERRMSG

	ERROR: $PLAYBOOK does not parse. No hosts were touched, and retrying
	       would fail identically, so this stops here.

	If the message above is "couldn't resolve module/action", a collection
	this repo needs is missing FROM THE SEARCH PATH -- which is not the same
	as missing from the machine. Compare where it landed against where
	ansible actually looks:

	    ansible-galaxy collection list
	    ansible-config dump | grep -i collections_path
	    echo "\$ANSIBLE_COLLECTIONS_PATH"

	requirements.yml lists every collection this repo needs.
	ERRMSG
	exit 1
fi

# --- Let a freshly provisioned range finish booting --------------------------
BOOT_DELAY="${BOOT_DELAY:-180}"
if [ "$BOOT_DELAY" -gt 0 ]; then
	echo "=== Waiting ${BOOT_DELAY}s for range VMs to finish booting ==="
	echo "    (override with BOOT_DELAY=0 ./deploy.sh on an already-up range)"
	sleep "$BOOT_DELAY"
fi

# --- Per-attempt logs and the end-of-run failure summary ---------------------
# WHY. Every failed build so far has ended with a PLAY RECAP that names which
# hosts failed and nothing about why, so diagnosing one costs a round trip to
# grep /var/log/playbook_run.log -- after an 8-hour deploy. The information was
# in the log the whole time. This puts it in the output.
#
# Written to a directory proven writable first. deploy.sh runs as root from
# cron via /tmp/deploy-script.sh, where /var/log is fine, but it is also run by
# hand as simspace, where it is not -- and a tee that cannot open its file
# would spray errors through the whole run.
ATTEMPT_LOG_DIR="${ATTEMPT_LOG_DIR:-/var/log}"
if ! { mkdir -p "$ATTEMPT_LOG_DIR" 2>/dev/null && [ -w "$ATTEMPT_LOG_DIR" ]; }; then
	ATTEMPT_LOG_DIR="${TMPDIR:-/tmp}"
fi
rm -f "$ATTEMPT_LOG_DIR"/deploy-attempt-*.log

# Groups identical (task, kind, message) across hosts, so 13 Create Users items
# failing the same way are one line and not thirteen. UNREACHABLE is called out
# separately from FAILED because they are different faults: an unreachable host
# left the play and never ran the task, a failed one ran it and it did not
# work, and `until:` retries only ever help the second.
summarize_failures() {
	local f attempt
	for f in "$ATTEMPT_LOG_DIR"/deploy-attempt-*.log; do
		[ -f "$f" ] || continue
		attempt="${f##*-attempt-}"; attempt="${attempt%.log}"
		awk -v att="$attempt" '
			# Handlers too, not just TASK. A handler failure printed under the
			# last TASK name is actively misleading: on 2026-09-22 a win_reboot
			# timeout in the shared Reboot Windows handler was reported as
			#   [FAILED] secpol : Set secpol
			# and secpol cannot time out waiting for a boot. That name sends you
			# to the wrong role, the same defect as a task name naming the wrong
			# host. Prefixed "handler: " so the two are never confused.
			/^TASK \[/ { t=$0; sub(/^TASK \[/,"",t); sub(/\].*$/,"",t) }
			/^RUNNING HANDLER \[/ { t=$0; sub(/^RUNNING HANDLER \[/,"handler: ",t); sub(/\].*$/,"",t) }
			/^fatal:|^failed:/ {
				h=$0; sub(/^[a-z]+: \[/,"",h); sub(/ *->.*/,"",h); sub(/\].*/,"",h)
				k=(index($0,"UNREACHABLE")>0)?"UNREACHABLE":"FAILED"
				m=""
				if (match($0, /"msg": "[^"]*/)) m=substr($0, RSTART+8, RLENGTH-8)
				key=k "\t" t "\t" substr(m,1,160)
				if (!(key in hosts)) { ord[++n]=key; hosts[key]=h }
				else if (index(" " hosts[key] " ", " " h " ")==0) hosts[key]=hosts[key] ", " h
			}
			END {
				if (n==0) exit
				printf "\n  --- attempt %s ---\n", att
				for (i=1;i<=n;i++) {
					split(ord[i], p, "\t")
					printf "  [%s] %s\n", p[1], p[2]
					printf "        hosts: %s\n", hosts[ord[i]]
					if (p[3] != "") printf "        msg  : %s\n", p[3]
				}
			}' "$f"
	done
}

ANSIBLE_START=$(date +%s)
DEPLOY_RESULT="INCOMPLETE — interrupted mid-run"

for i in $(seq 1 $MAX_ATTEMPTS); do
	ATTEMPT_START=$(date +%s)
	# Attempt 2 gets the retry-file scope IF the previous attempt actually
	# produced one. If the file is missing (e.g. deploy exited on a global
	# error before writing it), fall through to the full sweep.
	# STDERR IS MERGED INTO STDOUT DELIBERATELY.
	#
	# ss-pp-stacked 2026-09-02: all three attempts failed in ~2 seconds and
	# /var/log/playbook_run.log contained nothing but "Attempt N failed after
	# 0h 00m 02s". Every ansible-playbook startup error -- a role that cannot
	# be found, an unparsable play, a vault secret that is missing, a bad
	# --limit -- is written to STDERR, and the log is produced by piping this
	# script's STDOUT into tee. So the log faithfully recorded THAT a deploy
	# failed while structurally being unable to record WHY.
	#
	# Merging here rather than taking over logging with `exec > >(tee ...)`:
	# the caller already owns the redirect, and a second writer to the same
	# file interleaves badly.

	# A CLEAN REPAIR PASS IS NOT A DEPLOYED RANGE. This deliberately never
	# breaks out of the loop, however well it goes.
	#
	# The retry file lists the hosts that FAILED. Running the playbook limited
	# to them repairs those hosts -- but every play whose targets were dropped
	# when they failed still has not run. airfield 2026-09-15: bs-dc01 (sole
	# member of [pdc_blackstone]) failed on an ADWS race in attempt 1, so
	# Create Users, dns and BOTH domain joins lost their target and the SO
	# phases never started. Attempt 2 scoped to bs-dc01 fixed bs-dc01, passed,
	# and deploy.sh reported "Success on attempt 2" over a range with no
	# domain joins and no Security Onion.
	#
	# So the repair pass REPAIRS, and attempt 3's full sweep is what confirms
	# the range.
	#
	# Reachable only since 2026-09-15: before the RETRY_FILE path was fixed
	# the -f guard never matched, so attempt 2 was always a full sweep and
	# "success on attempt 2" really did mean a full sweep had passed.
	if [ $i -eq 2 ] && [ -f "$RETRY_FILE" ]; then
		echo "=== Attempt $i (retry-file scope — REPAIR PASS over failed hosts) ==="
		# PIPESTATUS[0], NOT the pipeline status. A pipeline reports the exit
		# code of its LAST command, which here is tee and is essentially always
		# 0 -- so `if ansible-playbook ... | tee ...; then` would declare every
		# deploy a success. The status must come from ansible-playbook itself.
		ansible-playbook $PLAYBOOK --forks $FORKS --limit @"$RETRY_FILE" "$@" 2>&1 \
			| tee "$ATTEMPT_LOG_DIR/deploy-attempt-$i.log"
		ANSIBLE_RC=${PIPESTATUS[0]}
		if [ "$ANSIBLE_RC" -eq 0 ]; then
			echo "Repair pass clean after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"
			echo "NOT declaring success — a full sweep must confirm the range"
		else
			echo "Attempt $i failed after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"
		fi
		rm -f "$RETRY_FILE"
		continue
	fi

	echo "=== Attempt $i (full sweep) ==="
	# See the PIPESTATUS note above: tee's exit code is not ansible's.
	ansible-playbook $PLAYBOOK --forks $FORKS "$@" 2>&1 \
		| tee "$ATTEMPT_LOG_DIR/deploy-attempt-$i.log"
	ANSIBLE_RC=${PIPESTATUS[0]}
	if [ "$ANSIBLE_RC" -eq 0 ]; then
		echo "Success on attempt $i after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"
		DEPLOY_RESULT="SUCCESS on attempt $i"
		break
	fi

	echo "Attempt $i failed after $(fmt_elapsed $(($(date +%s) - ATTEMPT_START)))"

	# Preserve the retry file between attempts 1 and 2 (that's how attempt 2
	# knows which hosts to target). Clear it between 2 and 3 so a stale
	# retry list can't accidentally scope attempt 3 the same way attempt 2
	# was scoped.
	if [ $i -ge 2 ]; then
		rm -f "$RETRY_FILE"
	fi

	if [ $i -eq $MAX_ATTEMPTS ]; then
		DEPLOY_RESULT="FAILED after $MAX_ATTEMPTS attempts"
		echo "ERROR: Playbook failed after $MAX_ATTEMPTS attempts"
		exit 1
	fi
done
