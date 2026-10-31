# Finalize a campaign

Use this procedure when `/finalize-campaign` is invoked. Infer the campaign from the current canonical
`campaign/<slug>` branch; never ask the user to select one.

This invocation authorizes the runner's local rebase, fast-forward integration, and cleanup only for
the inferred `campaign/<slug>` and `agentic/<slug>/*` namespaces. The runner creates only local branches and owns no remote refs; remote branches are
therefore not cleanup targets. This invocation does not authorize a push or unrelated branch changes.

Resolve and retain the worktree path for the main branch, then run `.agentic/bin/campaign finalize`. A campaign
held by another machine of the project's fleet is finalized from here with `.agentic/bin/campaign finalize --campaign
<slug>`: it is moved to this machine first, and lands in this machine's main branch. The
runner must refuse before mutation unless every required
ticket is `done`, no worker or runner is active, no required ticket is blocked or `needs-human`, and Git
state is safe.

Finalization performs this sequence:

1. If the main branch advanced, rebase the campaign onto the current main branch (rerere disabled). A conflict aborts
   the rebase and stops with the conflicting files, leaving the campaign intact; a rebase that drops a
   campaign change is detected and undone.
2. Run the final validation once, on the rebased tree that the main branch will fast-forward to. A failure stops
   with the campaign intact (planning files included), ready to repair and resume. The checkpoint
   (`finalize.json`) records the commit it validated (`tip`); a campaign branch anywhere else when finalize
   resumes (a manual rebase after a conflict, a new commit, a checkpoint without `tip`) is validated again
   before anything is merged.
   To correct the plan after a failed final validation, commit the corrected `campaigns/<slug>/validation.json` on
   the campaign branch and run finalize again. It takes the committed plan, checks it again (ticket keys and the
   project's `required_checks`) and re-validates before anything is merged.
3. Remove the campaign's SPEC, tickets, execution context, handoffs, and other campaign-only planning
   files from `campaigns/<slug>/`, then commit that cleanup on the campaign branch; it changes no
   validated file. Block when a safe fast-forward cannot be proven.
4. From the main worktree, integrate with `git merge --ff-only`; never create a merge commit. If the main branch moved
   while the final validation ran, stop with "<main branch> moved during finalize": the next run rebases and
   validates again.
5. Archive the campaign history (events, results, decisions, diagnoses and validation receipts) to the
   `archive_dir` of `.agentic/project.json` (relative to the main worktree, `{date}` and `{slug}` replaced) when
   that folder is ignored by Git, otherwise to the cache's `archive/` folder.
6. Remove only runner-owned `agentic/<slug>/*` worktrees and branches, the auxiliary campaign worktree and `campaign/<slug>` branch, runtime prompts/results/
   logs/locks, and the campaign cache. Run `git worktree prune`.
7. Verify no worktree, branch, planning artifact, runtime cache, or lock owned by that campaign remains.
   The only trace is the marker `<cache>/finalized/<slug>.json` (written right after the fast-forward), which
   lets a restarted queue count the campaign as done instead of creating it again.

After success, continue from the retained main worktree path and report it. The campaign worktree
used to invoke finalization no longer exists by design; do not leave the UI pointed at that path.

Unknown branches and resources outside the runner namespace are never cleanup targets. If any gate or
safe rebase condition fails, report the exact blocking condition and leave recoverable campaign state
intact.

Finalization is one runner operation; only a destructive risk outside the campaign namespace or a
human-decision gate may pause it.
