# `ufw.sh` — Design

A small host-side helper that configures UFW for an easyhole deployment, then keeps the WireGuard UDP rule in sync with `${SERVERPORT}` from `.env` on subsequent runs.

Sits next to `build.sh` and `install-awg.sh` at the project root, follows the same shape (small `log()` helper, early gates, linear flow, `set -euo pipefail`).

## Goals

- First run: lay down a minimal sane UFW config (default deny-in / allow-out, allow SSH, allow WireGuard UDP) and turn UFW on.
- Subsequent runs: keep one rule — the WireGuard UDP rule — synced with `${SERVERPORT}` in `.env`. Touch nothing else.
- Be safe to re-run any time. Never lock the user out of SSH.

## Non-Goals

- Does not manage forward / route rules. WireGuard runs inside the wg-easy container; `wg0` is in the container's network namespace, not on the host. Docker prepends its own `FORWARD` ACCEPTs above UFW for the published port. Host UFW FORWARD rules referencing `wg0` would be no-ops or fail.
- Does not bootstrap `.env` (that is `build.sh`'s job).
- Does not install UFW (bails with an `apt install ufw` hint if missing).
- Does not modify SSH or default-policy rules after first run.
- Does not disable UFW. Ever.
- No dry-run mode. `ufw status` is the source of truth and the script is idempotent.
- No IPv6-specific allow rule. `ufw allow PORT/udp` covers v4 and v6 when `IPV6=yes` (the Debian/Ubuntu default in `/etc/default/ufw`).

## Pre-flight gates

In order — fail fast, fail loud:

1. **Platform.** `uname -s != Linux` → `exit 0` silently. Matches `install-awg.sh`.
2. **`ufw` available.** `command -v ufw` missing → bail with `ERROR: ufw not found. Install with: apt install ufw`.
3. **Root.** `id -u != 0` → bail with `ERROR: ufw.sh requires root. Run: sudo ./ufw.sh`.
4. **`.env` present.** Missing → bail with `ERROR: .env not found. Run ./build.sh first.`
5. **Load `.env`.** Use the same one-liner as `build.sh`:
   ```sh
   export $(grep -v '^#' .env | sed 's/#.*$//' | sed '/^$/d' | xargs)
   ```
6. **`SERVERPORT` valid.** Non-empty, numeric, in 1..65535. Bail otherwise.

## Mode detection

Run `ufw status verbose`. Search the output for the literal token `easyhole` (our comment marker).

- Token **found** → **update mode**. The system has been initialized by us before; only the WG rule may need to move.
- Token **not found** → **first-run mode**. Treat as a clean slate to be initialized. (This includes the case where someone manually deleted our tagged rule. Re-prompting for SSH and re-asserting defaults is acceptable; silent partial-restore would be worse.)

## First-run mode

### SSH-port discovery and prompt

1. Detect from `/etc/ssh/sshd_config`:
   ```sh
   awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config
   ```
   Fallback: `22`.
2. Prompt: `SSH port [<detected>]:`. Empty input accepts the detected default.
3. Validate: numeric, 1..65535. Reject otherwise and re-prompt (small bounded loop, e.g. 3 attempts; bail after).
4. If stdin is not a TTY (`[ ! -t 0 ]`), bail with an error — do not silently apply a default in non-interactive mode on first run, since a wrong value would be persisted into UFW.

### Apply, in this order

Allow rules are applied *before* `ufw --force enable` flips UFW into enforcement, so there is no window in which the deny-incoming default is active without the SSH allow already in place.

1. `ufw allow <ssh-port>/tcp` — **no comment**. The user owns this rule from here on; we never touch it again.
2. `ufw allow ${SERVERPORT}/udp comment 'easyhole'` — our managed rule.
3. `ufw default deny incoming`
4. `ufw default allow outgoing`
5. `ufw --force enable`

Print the final `ufw status verbose` so the operator sees exactly what was applied.

## Update mode

This path runs every subsequent invocation. It must **only** touch the easyhole-tagged WG rule.

1. Parse `ufw status` to find the line whose comment contains `easyhole`. Extract the port from the `To` column (e.g. `51820/udp` → port `51820`).
2. **If parsed port == `${SERVERPORT}`** → log `OK: ufw easyhole rule already current (${SERVERPORT}/udp)` and exit 0. Idempotent no-op.
3. **If parsed port != `${SERVERPORT}`** → port has changed in `.env`:
   - `ufw delete allow <old-port>/udp`
   - `ufw allow ${SERVERPORT}/udp comment 'easyhole'`
   - Log the before/after.
4. Print final `ufw status verbose`.

What this path explicitly does **not** do:
- Does not modify the SSH rule.
- Does not change default policies.
- Does not touch UFW's enabled/disabled state.
- Does not add or remove any rule it didn't itself put there.

## Failure modes worth calling out

- **User manually deleted our tagged rule but left UFW enabled.** Detection sees no `easyhole` token, so the script enters first-run mode and re-prompts for SSH port. Acceptable: the alternative (silent partial-restore) hides state from the operator. The `ufw default deny incoming` re-application is a no-op if it's already set.
- **`.env`'s `SERVERPORT` was changed and a stale UFW rule exists for the old port.** Update mode catches this on the next run and migrates the rule.
- **Stdin is not a TTY on first run.** Script bails rather than silently writing a default SSH port into UFW. Update mode does not need stdin.
- **A second UDP rule for the same port exists without our comment.** `ufw delete allow <port>/udp` removes by spec, not by comment, so it might delete the user's rule instead of ours. Edge case; accepted. Documented in the script header so anyone reading the source knows the assumption.
- **Cloud-provider external firewall.** Out of scope. Mentioned in script header as a reminder ("UFW is host-level only; check your provider's security groups too").

## What the user should see

First run, condensed:

```
ufw: detected SSH port 22 from /etc/ssh/sshd_config
SSH port [22]: 2222
ufw: applying first-run config
  + allow 2222/tcp
  + allow 51820/udp (comment 'easyhole')
  + default deny incoming
  + default allow outgoing
  + enable
ufw: status:
<ufw status verbose output>
```

Update mode, port unchanged:

```
ufw: easyhole rule already current (51820/udp); nothing to do
```

Update mode, port changed:

```
ufw: easyhole rule out of date (was 51820/udp, .env says 51999/udp)
  - delete 51820/udp
  + allow 51999/udp (comment 'easyhole')
ufw: status:
<ufw status verbose output>
```

## File summary

- **New:** `/Users/illusion/Self/easyhole/ufw.sh` (executable, ~80–100 lines).
- **No edits** to `build.sh`, `docker-compose.yml`, `.env.example`, or `install-awg.sh`.
- **README:** add a short subsection under the existing UFW caveat noting that `./ufw.sh` exists and what it does. (Optional in this scope; the script is usable without it.)
