# Runbook: closing the management firewall (`restrict_management` flip)

How to move SSH(22), the Proxmox API/UI(8006) and the k8s API(6443) from
*open-to-any* to *WireGuard/internal-only*, on a server with **no
IPMI/console**, without stranding yourself. This is the forward procedure;
[`lockout-recovery.md`](lockout-recovery.md) is the recovery procedure if it
goes wrong. The flip itself is the single-line diff
`restrict_management = false → true` in `infra/tofu/terraform.tfvars`.

443 / 32400 / 51413 (torrent) / 51820-udp (WireGuard) stay public throughout —
only the management ports change.

Use this runbook any time `restrict_management` needs to go from `false` to
`true` — the initial flip, or a re-flip after a rollback (§9).

---

## 0. The one idea that makes this safe

The flip narrows three `proxmox_virtual_environment_firewall_rules` resources
(`node`, `vm`, `runner`) so their `source` becomes the `+mgmt` ipset instead
of *any*. `+mgmt` = `local.management_sources` =

- `internal_subnet` — the VM(s) and the self-hosted runner, on the internal
  bridge
- `wireguard_subnet` — your laptop over the tunnel

**Whatever runs `tofu apply` must have a source IP inside `+mgmt`, or the
apply severs its own connection to 8006/22 mid-flight and half-applies.**
That is the entire risk. Two things satisfy it, and this runbook uses both as
independent layers:

1. **Run the apply on a runner that lives inside `internal_subnet`** (e.g. a
   self-hosted CI runner on the internal bridge). It reaches the API endpoint
   over its own gateway (the host), so the host sees the packet's source as
   inside `+mgmt` — before *and* after the flip. It is never cut off. A
   GitHub-hosted `ubuntu-latest` runner has a random public source IP and
   **would** be cut off — the CI variable that routes applies to the
   self-hosted runner is a hard prerequisite (§2).
2. **Arm a dead-man switch on the host** (§4) that disables the whole cluster
   firewall after a timeout unless you cancel it. Belt to the runner's
   suspenders: if anything unforeseen strands access, the box re-opens on its
   own instead of needing rescue mode.

**One assumption both layers depend on: the `pve-firewall` daemon must be
running.** OpenTofu manages the firewall *config* — rules, the `+mgmt` ipset,
the cluster `enable` flag — over the PVE API, but has no visibility into the
`pve-firewall` *service* that compiles that config into live kernel rules. If
the daemon is stopped, the API still reports `enable: 1` while nothing is
enforced and the host is open on every port, so a closed-firewall apply
silently does nothing. **Confirm `pve-firewall status` says `enabled/running`
before trusting any part of this procedure** — if no automation owns the
daemon's lifecycle yet, this is a manual check, not an assumption.

> **Reconciling with any "do not let CI perform a firewall-affecting apply"
> policy documented elsewhere in this repo.** That kind of rule is usually
> written against a public-IP `ubuntu-latest` runner with no dead-man switch
> anywhere near the apply. Both conditions are addressed here: the apply runs
> on a runner *inside* `internal_subnet`, and you arm a dead-man switch on the
> host by hand (§4) regardless of where the apply executes. The supervised,
> dead-man-switched, internal-source apply this runbook describes is exactly
> the safety posture such a rule is protecting — it is not the unsupervised
> public-IP CI apply that rule forbids. If other docs still describe the
> older, stricter posture, reconcile the wording there when you touch them
> next.

---

## 1. Preconditions

Do not proceed until every row is green.

| # | Precondition | How to check |
|---|---|---|
| 1 | A runner inside `internal_subnet` exists and is registered | Cloud/CI provider's runner list shows it online |
| 2 | The role/config that registers the runner is merged and applied | Runner shows **Idle/online**, correct labels |
| 3 | CI is routed to that runner (not the public-IP default) | The relevant CI variable/setting points at the internal runner's label |
| 4 | WireGuard up, host reachable over tunnel | `ssh root@<host-wg-address>` works right now |
| 5 | The environment gating the apply has a required reviewer | CI provider's environment protection settings |
| 6 | The flip PR is a clean, minimal diff, CI green | `gh pr diff <PR#>`, `gh pr checks <PR#>`; plan shows only the expected `source` narrowing, no adds/destroys |
| 7 | `+mgmt` ipset non-empty | `pvesh get /cluster/firewall/ipset/mgmt` lists internal + wg subnets |
| 8 | **`pve-firewall` daemon running** | `pve-firewall status` = `enabled/running` (not `…/stopped`) — else the flip enforces nothing |

If any row fails, stop — applying with a precondition unmet is the self-strand
this runbook exists to prevent.

---

## 2. First-time setup: route CI onto the internal runner

Skip this section if CI is already routed onto the internal-subnet runner
(check row 3 above). Otherwise, once the runner is registered and Idle, point
CI at it — e.g. for a GitHub Actions repo variable that gates `runs-on`:

```sh
gh variable set LAB_RUNNER --body <runner-label>
gh variable list          # confirm it's set
```

This re-routes plan/apply jobs onto the self-hosted runner. That is harmless
while the firewall is still open — the runner can already reach the API.

Sanity-check the runner still shows Idle after setting it (setting a variable
does not start a job):

```sh
gh api repos/:owner/:repo/actions/runners --jq '.runners[] | {name,status,busy,labels:[.labels[].name]}'
```

Once set, leave it set (§8) — every subsequent apply depends on it for
reachability.

---

## 3. Prove the post-flip management path *before* flipping

You must confirm the path that has to survive the flip actually works **while
the firewall is still open**, so a failure here is diagnosed as "WireGuard is
down" and not "I just locked myself out."

From your laptop with the WireGuard tunnel **up**:

```sh
ssh root@<host-wg-address> 'hostname; pvesh get /version'   # host over WG
```

If that fails, **stop** — bring WireGuard up and re-verify before touching the
firewall. Everything downstream assumes this works.

Optional but reassuring — confirm the runner itself reaches the API the way
the apply will (run from a shell on the runner, or trust a green `tofu plan`
from §1 row 6, which already proved API reachability from the runner):

```sh
curl -sk https://<host-public-ip>:8006/api2/json/version | head -c 200
```

---

## 4. Arm the dead-man switch on the host

In a **separate, dedicated** SSH session to the host over WireGuard — keep it
open and untouched for the whole operation:

```sh
ssh root@<host-wg-address>
nohup sh -c 'sleep 900; pvesh set /cluster/firewall/options --enable 0' &
```

This disables the **entire** cluster firewall in 15 minutes if you don't
cancel it — reverting the box to fully-open (public SSH/API back), which is
the safe-but-unprotected state, never bricked. If the apply plus verification
looks like it might exceed 15 minutes, use a larger `sleep` (e.g. `1800`).

> The switch fires `--enable 0` on the *cluster firewall options* only; it
> does not revert `restrict_management`. So if it fires, the rules still say
> `+mgmt` but nothing is enforced because the master switch is off. Tofu state
> then shows drift (`enabled = true`); a later boring apply reconciles it.
> That is fine — the switch is an escape hatch, not a config change.

---

## 5. Un-draft the flip PR and run the gated apply on the runner

The apply flows through whatever workflow runs `tofu apply` on this repo: it
should be gated by a required reviewer, run **pre-merge on the PR branch**,
and commit the updated state back to that branch so it rides the merge.

1. **Confirm CI is routed onto the internal runner** (§2) — this is the last
   moment to catch it.
2. Un-draft the flip PR: `gh pr ready <PR#>`. To be sure the apply runs on the
   runner with a fresh plan, push an empty commit (or re-run the workflow) so
   a new run starts *after* the routing was confirmed:
   ```sh
   git commit --allow-empty -m "chore: trigger flip apply on self-hosted runner" && git push
   ```
3. Watch the run. The plan job's output should show only the expected
   `firewall_rules.*` `source` narrowing to `"+mgmt"` — no adds, no destroys.
   Anything else → do not approve; investigate.
4. **Approve the gated environment.** When you approve, verify on the apply
   job's page that it is running on the **internal, self-hosted** runner, not
   a hosted/public-IP one. If it shows a hosted runner, cancel immediately —
   the CI routing was not picked up.
5. The apply runs from inside `internal_subnet`, narrows the rule sets, and
   commits the new Tofu state to the PR branch.

If instead you prefer to apply by hand, note the endpoint caveat: Tofu is
typically pointed at the host's **public** IP. Over WireGuard your route to
that public IP goes over the open internet (source = your public IP, **not**
`+mgmt`) unless you add the host's public IP to the tunnel's `AllowedIPs`, in
which case your source becomes your WG address (inside `+mgmt`). The runner
path in this section has no such footgun, which is why it's the default.

---

## 6. Verify the closed state

Positive (must still work):

```sh
ssh root@<host-wg-address> 'pve-firewall status'  # MUST say enabled/running — a dead daemon enforces nothing
ssh root@<host-wg-address> 'pvesh get /version'   # host mgmt over WG — OK
gh run view --log <apply-run-id> | tail           # apply exited 0, state pushed
```

If `pve-firewall status` shows `enabled/stopped`, the flip is **inert** — the
host is wide open, not closed, and every check below is meaningless. Start the
daemon (`systemctl start pve-firewall`) and re-verify.

Negative (must now be refused) — run from a machine that is **off** the
tunnel, i.e. not the dead-man-switch session:

```sh
nc -vz <host-public-ip> 22      # SSH        → refused / timeout
nc -vz <host-public-ip> 8006    # Proxmox API→ refused / timeout
nc -vz <host-public-ip> 443     # HTTPS      → still OPEN (public)
nc -vzu <host-public-ip> 51820  # WireGuard  → still OPEN (public)
```

`22` and `8006` open-off-tunnel = the flip did **not** take — treat as a
failed apply and investigate before cancelling the dead-man switch.

---

## 7. Cancel the dead-man switch, then merge

Only after §6 passes from a session that is **not** the dead-man-switch
session:

```sh
# in the dead-man-switch session on the host:
jobs -l                     # find the backgrounded sleep/pvesh
kill %1                     # (or: pkill -f 'pvesh set /cluster/firewall/options')
```

Confirm it's gone (`jobs` empty), then merge the flip PR:

```sh
gh pr merge <PR#> --squash
```

The state commit the apply pushed to the branch merges along with it — no
separate bot commit lands on the trunk branch.

---

## 8. After the flip

- **From now on every apply runs on the self-hosted runner** — leave the CI
  routing (§2) set. Every apply/plan job depends on it for reachability —
  unsetting it strands the next apply exactly as an unset one would have here.
- The management plane is now WireGuard-only. Any subsequent host/VM
  configuration work applies over the runner from here on.

---

## 9. If it goes wrong (rollback ladder, cheapest first)

1. **Let the dead-man switch fire** (or trigger it now from the host session):
   ```sh
   pvesh set /cluster/firewall/options --enable 0
   ```
   Whole firewall off → public SSH/API back in seconds. Box is open, not lost.
   Re-arm, fix, retry.
2. **Declarative kill-switch** — if you have host access and want it gone
   through code: set `enable_firewall = false` in `terraform.tfvars` and apply
   (disables cluster/node/VM firewalls without deleting rules). See
   `lockout-recovery.md` §5.
3. **Revert the flip** — set `restrict_management = false`, apply from the
   runner (still in `+mgmt`, still reachable). Re-run this runbook from the
   top when you're ready to try again.
4. **OVH rescue mode** — only if 1–3 are all unreachable (total strand).
   Full procedure in [`lockout-recovery.md`](lockout-recovery.md) §2–4:
   netboot rescue, `zpool import`, delete the `cluster.fw` row from pmxcfs's
   `config.db`, netboot back. ~30 minutes.
