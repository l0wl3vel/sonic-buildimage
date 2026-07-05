# Maintaining the VPP integration forks

This tree pins three repos to personal forks that carry local patches on a
`vpp-integration` branch:

| Repo                  | Path                 | Fork                                      | Local patches |
|------------------------|----------------------|--------------------------------------------|----------------|
| sonic-buildimage       | `.` (this repo)      | `l0wl3vel/sonic-buildimage`                | devcontainer, `build-vpp-artifacts.sh`, Docker MTU fix, `FRR_PYTHONTOOLS` dep, submodule pins below |
| sonic-sairedis         | `src/sonic-sairedis` | `l0wl3vel/sonic-sairedis`                  | IPv6 ND/MLD multicast-to-hostif-tap forwarding, PR #1959 (VLAN BVI support, upstream, unmerged) |
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

Since our commits for sairedis include real cherry-picks of upstream PR
#1959, watch for that PR being merged upstream in the meantime: if
`upstream/master` now contains those same commits, the rebase will produce
empty/no-op commits for them — drop them with `git rebase --skip` (or
preemptively `git rebase --onto upstream/master <old-base> vpp-integration`
picking a new base past the merge) rather than keeping duplicates.

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

Repeat for `platform/vpp`. Once the rebase finishes:

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
