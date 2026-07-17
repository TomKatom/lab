# Runbook: firewall lockout recovery

You are locked out when the Proxmox host stops answering on 22 (SSH) and
8006 (API/UI) but the server is otherwise up and billed. This server has no
IPMI/KVM, so recovery means OVH **rescue mode** — plan on ~30 minutes.

A NIC/bridge misconfiguration and a default-DROP firewall with no accept
rules look *identical* from outside (everything dark, including ICMP), so
step 1 is to tell them apart before touching anything.

## 0. What caused the one real lockout so far

OpenTofu created the cluster firewall's `input_policy = "DROP"` **before**
the accept rules that punch holes in it. They are separate API objects; the
rules resource had a `depends_on` on an upstream that failed, so the rules
never ran, while the DROP policy — which depended on nothing — applied
cleanly. Proxmox's built-in management rules only permit 22/8006 from
`local_network` (the vmbr0 subnet), which is why the host stayed reachable
from its own LAN and from nowhere else.

`infra/tofu/firewall.tf` now inverts that dependency (policy depends on
rules) so a failed rule resource aborts the apply *before* the wall goes
up. See the ordering-invariant comment at the top of that file.

## 1. Confirm it's the firewall, not the network

From anywhere:

```sh
ping -c3 <host-ip>
nc -vz <host-ip> 22
nc -vz <host-ip> 8006
```

All dark tells you nothing on its own. The discriminator is the **apply
log**: if a firewall policy resource was created and its sibling rules
resource errored or never started, it's the firewall. If the last change
touched `network.tf` / bridges, suspect the NIC. Check the OVH manager —
if the server still answers OVH's own monitoring, the box is alive and it's
a filtering problem.

## 2. Boot rescue mode

In the OVH manager: **Dedicated server → Netboot → Rescue → rescue64-pro**,
then hard-reboot. OVH emails temporary root credentials for the rescue OS.
SSH in with those.

Rescue boots a separate Linux off the network; your Proxmox install is
untouched on disk.

## 3. Neutralise the firewall from rescue

Proxmox keeps `/etc/pve` in **pmxcfs**, a FUSE filesystem backed by a
SQLite database — it does not exist as plain files on the disk, so you
cannot just edit `cluster.fw` offline. Import the pool and edit the
database:

```sh
zpool import -f -R /mnt rpool
sqlite3 /mnt/var/lib/pve-cluster/config.db
```

Inspect before deleting — confirm the schema and the row:

```sql
SELECT inode, parent, name FROM tree WHERE name LIKE '%.fw';
```

You should see `cluster.fw` (cluster policy + ipsets) and possibly
`<node>.fw`. Removing the cluster row disables the firewall entirely: with
no `[OPTIONS]` section, `enable` reverts to its default of off.

```sql
DELETE FROM tree WHERE name = 'cluster.fw';
```

Then exit, export cleanly, and netboot back to disk:

```sh
zpool export rpool
```

Set **Netboot → Local disk** in the OVH manager and reboot. SSH and 8006
should answer again.

> If you ever *do* have a working console/session instead, all of this
> collapses to one command — no rescue needed:
> ```sh
> pvesh set /cluster/firewall/options --enable 0
> ```

## 4. Re-apply safely

State still records the cluster firewall resource, so the next apply will
detect the drift and re-create it — this time correctly ordered after the
accept rules. Before running it:

```sh
cd infra/tofu
./tofu.sh plan
```

Read the plan. You want to see the `mgmt` ipset, `node_firewall`, and
`firewall_rules.node` created, with `cluster_firewall` re-created **after**
them. Then arm the dead-man switch from `tofu-apply.md` §3 and apply
manually:

```sh
nohup sh -c 'sleep 900; pvesh set /cluster/firewall/options --enable 0' &
./tofu.sh apply
```

Verify public SSH from a machine that is *not* the dead-man-switch session,
then kill the switch.

## 5. Emergency kill-switch (no rescue required)

If you still have access but want the firewall gone declaratively, set
`enable_firewall = false` and apply. This disables cluster, node, and VM
firewalls in one shot without deleting any rules — they stay in the config,
just unenforced.

## Prevention

- **A reviewed plan is not a safety net for ordering.** The apply that
  caused the lockout *was* gated on the `production` environment's
  required-reviewer rule, and the plan was approved. It made no difference:
  `tofu plan` lists the resources it will create, not the **order** it will
  create them in, so a DROP-before-rules bug is invisible in plan output.
  Ordering has to be enforced in the graph (it now is) — you cannot review
  your way to it.
- **Firewall-affecting applies get a dead-man switch**, which means running
  them manually (`tofu-apply.md` §3). CI has no such switch, so let CI
  apply the boring diffs and take the firewall ones yourself.
- **Policy depends on rules, never the reverse.** Enforced by the graph in
  `firewall.tf`; `precondition` blocks refuse a DROP policy with an empty
  management-rule set, or `restrict_management = true` with empty
  `management_sources`.
- **Keep `restrict_management = false`** until WireGuard is verified
  end-to-end (Phase 3).
