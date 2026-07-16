# Maintaining the VPP integration forks

This tree pins three repos to personal forks that carry local patches on a
`vpp-integration` branch:

| Repo                  | Path                 | Fork                                      | Local patches |
|------------------------|----------------------|--------------------------------------------|----------------|
| sonic-buildimage       | `.` (this repo)      | `l0wl3vel/sonic-buildimage`                | devcontainer, `build-vpp-artifacts.sh`, Docker MTU fix, `FRR_PYTHONTOOLS` dep, submodule pins below |
| sonic-sairedis         | `src/sonic-sairedis` | `l0wl3vel/sonic-sairedis`                  | IPv6 ND/MLD multicast-to-hostif-tap forwarding, ip6 mfib punt via `sonic_ext`, per-lcp-pair link-local mcast punt+inject, RFC 5549 nexthop `sw_if_index` resolution, RIF IPv4-enable + VLAN-RIF neighbor resolution |
| sonic-platform-vpp     | `platform/vpp`       | `l0wl3vel/sonic-platform-vpp`              | Guard all VPP package registration behind `BLDENV=trixie` |

Every repo has two remotes:

- `upstream` — the real sonic-net repo (or FRRouting/frr etc. where applicable)
- `fork` — the personal fork above, on branch `vpp-integration`

`.gitmodules` points `sonic-sairedis` and `platform/vpp` at their `fork` URL with
`branch = vpp-integration`, so a plain `git submodule update --init` on this
branch checks out the patched code, not vanilla upstream.

**Caveat for a brand new clone of the buildimage fork**: `git submodule update
--init` creates each submodule's remote as `origin`, pointed at whatever URL is
in `.gitmodules` — i.e. the fork. There's no `upstream` remote yet. Add one
per submodule before trying to sync:

```sh
git -C src/sonic-sairedis remote add upstream https://github.com/sonic-net/sonic-sairedis
git -C platform/vpp remote add upstream https://github.com/sonic-net/sonic-platform-vpp.git
git remote add upstream git@github.com:sonic-net/sonic-buildimage.git   # if origin isn't already upstream
```

Upstream sonic-buildimage gets commits daily (including automated submodule
bump PRs), so `vpp-integration` needs periodic rebasing everywhere it touches
shared files — most sensitively `.gitmodules` and the submodule gitlinks
themselves, since upstream's automated bump commits touch exactly those.

## Sync order

Always sync leaf submodules **before** the superproject. The superproject
rebase needs each submodule's fork already sitting on top of the latest
upstream commit for that submodule, so the gitlink conflict resolution below
has something correct to point at.

## 1. Sync a submodule fork (sonic-sairedis, sonic-platform-vpp)

```sh
cd src/sonic-sairedis        # or platform/vpp
git fetch upstream
git rebase upstream/master vpp-integration     # replays our commits onto the new upstream tip
# resolve any conflicts the usual way (git status / edit / git add / git rebase --continue)
git push --force-with-lease fork vpp-integration
```

Watch for any of our sairedis commits landing upstream in the meantime. When
they do, drop ours rather than replaying duplicates: upstream's merged version
is authoritative and usually carries review changes ours never got.

Because a squash-merge upstream shares no patch-id with our commits, `git
rebase` will *not* auto-detect them as already-applied — it will happily replay
duplicates and hand you conflicts against upstream's own copy. Detect the
overlap by hand before rebasing:

```sh
git log --oneline <merge-base>..upstream/master   # anything that looks like our work?
git diff --name-only upstream/master...vpp-integration   # our files
```

If a commit has landed, rebuild the branch skipping it — cherry-pick our
unique commits onto `upstream/master` and leave the merged ones behind:

```sh
git checkout -B sync-wip upstream/master
git cherry-pick <first-unique>            # repeat / use ranges, omitting merged commits
git branch -f vpp-integration sync-wip
```

Verify the outcome with `git range-diff <old-base>..<old-tip>
upstream/master..vpp-integration` — dropped commits show as `<`, and anything
marked `!` is a commit whose content the rebase changed, which is exactly where
to look for a botched conflict resolution.

**Precedent (2026-07-16):** PR #1959 (VLAN BVI support + DHCP/LLDP L2 classifier
punt) was re-opened as **PR #1981** and merged upstream. Four of our nine
sairedis commits (`VLAN BVI support`, `Add l2 classifier to punt dhcp packet`,
`Reduce classifier table size`, `Add SWSS_LOG_ENTER to the new functions`) were
dropped in favour of upstream's version, which is a superset — it adds
best-effort punt error handling, `VALUE_EXIST` idempotency in
`vpp_normalize_ret`, null-context guards, and LAG egress-disable integration
(PR #1953), while keeping our reduced classifier table size. Our five remaining
commits now sit on top of it.

That rebase also produced one non-trivial conflict worth remembering: upstream
moved the `sflow` msg-id lookup to the end of `vpp_connect`, while our
`sonic_ext` commit inserted its own lookup above the old `sflow` position. The
resolution keeps only the `sonic_ext` block — re-adding `sflow` from our side
would double-initialize it.

## 2. Sync the superproject (sonic-buildimage)

```sh
git fetch upstream
git rebase upstream/master vpp-integration
```

Two conflict shapes show up repeatedly, both because upstream's daily
"[submodule] Update submodule X to the latest HEAD automatically" commits
touch the same lines we customized:

**`.gitmodules` conflicts** — upstream may reorder/reformat entries or touch
unrelated submodules; that merges cleanly on its own. If upstream ever edits
the `sonic-sairedis`/`platform/vpp` stanzas themselves (e.g. a URL typo fix),
resolve by hand but always keep our two added lines:

```
url = git@github.com:l0wl3vel/<repo>.git
branch = vpp-integration
```

**Submodule gitlink conflicts** (shown as "both modified" on
`src/sonic-sairedis` or `platform/vpp`, not a text diff) — upstream's commit
wants to point the gitlink at its own newer upstream commit; we want it
pointed at our fork's rebased tip instead. Resolve per submodule:

```sh
cd src/sonic-sairedis                  # already rebased per step 1, sitting at fork/vpp-integration's new tip
git checkout vpp-integration           # make sure the submodule worktree matches
cd ..
git add src/sonic-sairedis              # records our fork's commit as the resolution, discarding upstream's pin
git rebase --continue
```

Repeat for `platform/vpp`.

**Careful with the intermediate pin commits.** Our patch set contains several
"Update <submodule> pin to ..." commits, not just one, so this conflict fires
once per pin commit — and resolving them all to the fork's *final* tip would
make every intermediate commit pin the same SHA and misrepresent history. If
step 1 rewrote the submodule's commits, resolve each pin commit to the *rebased
equivalent* of what it originally pinned, so every commit on the branch pins a
commit that still exists on the fork after the force-push:

```sh
# what the pre-rebase commits pinned:
git ls-tree <old-pin-commit> src/sonic-sairedis
# check out that commit's rebased counterpart, then record it:
git -C src/sonic-sairedis checkout <rebased-equivalent>
git add src/sonic-sairedis && git rebase --continue
```

Use the submodule's own `range-diff` (old range vs new) to map old SHA → new
SHA. For a pin whose original target was *dropped* because it merged upstream,
pin the rebased commit that reproduces the same tree state — e.g. in the
2026-07-16 sync, the pin at the tip of the dropped BVI series mapped forward to
our IPv6 ND/MLD commit sitting on top of upstream's merged BVI work. Remember to
leave the submodule back on `vpp-integration` for the final pin commit.

Once the rebase finishes:

```sh
git push --force-with-lease fork vpp-integration
```

## Why rebase instead of merge

`--force-with-lease` push to `fork` is safe here because `vpp-integration` is
a personal branch nobody else builds on. Rebasing keeps the patch set small
and readable (a handful of commits on top of a moving upstream tip) instead
of accumulating merge commits every time upstream lands new work — with
upstream committing daily, a merge-based history would be dominated by noise
within a couple of weeks.
