# goquarkchain: Three-Week Bug-Fix Summary & Retrospective

> For the team meeting. Time range: 2026-06-14 ~ 07-05.
> Purpose: goquarkchain is being gradually deprecated. We put a lot of effort into this series of fixes; if it stops at "it's fixed," the value is limited. This doc distills the root causes and the process so goshard's design and development can learn from it.

---

## 0. Background: How Development & Review Actually Work Here

goquarkchain has had four or five main developers over its lifetime, with modules cross-reviewed among the team. It draws on two reference sources, each covering a different part:

- **Based on Geth**: a large amount of the lower layer is taken directly from Geth (block storage, insertChain, reorg, state trie, etc.). This part has a mainnet-proven, mature implementation to compare against.
- **Referencing pyquarkchain**: QuarkChain-specific features (sharding, xshard, commit status, etc.) don't exist in Geth, so their logic is modeled on pyquarkchain.

What's truly **without reference** is the part wedged between the two: **how to splice QuarkChain-specific logic into Geth's existing call chains**, plus the **Go-vs-Python language differences** that make pyquarkchain's implementation impossible to copy directly. Take **commit status** as an example: goquarkchain also tried a `committing` intermediate state (following pyquarkchain's approach), but it turned out to add little value, and we finally converged on **using locks (`chainmu` / `mu`) to achieve the equivalent behavior**. These "insertion points" and the lock model can neither be copied from Geth nor ported straight from pyquarkchain — they can only be worked out by our own understanding plus others' review.

The review process relies mainly on **individual reasoning-through** plus a few **simple principles** (conventions like "take the coarse lock before the fine lock"), and then surfaces problems through **test results** and **node run logs**. This approach (unchanged for the past five or six years) has two **long-standing, inherent limitations**:

- **Effective for modules with a reference, weak on home-grown features**: the manual + principles + logs approach works well on modules that have a "Geth / pyquarkchain counterpart," but under-covers our **home-grown, reference-less features (xshard broadcast, submit head, commit status)** — which is exactly where things broke.
- **Race-type bugs are hard to catch by reading code and logs**: Bug1's trigger window is only the 10–100 ms of the network broadcast; ordinary tests and logs almost never catch it.

This incident landed squarely in the un-referenceable zone: the core is a **race between AddBlock and AddRootBlock**, compounded by the **new features Geth doesn't have** — broadcasting xshard and submitting head to master. These new features are exactly where problems tend to arise, and Geth has no corresponding implementation to compare against. So this area can only be covered by manual review and case-by-case filtering, and manual filtering will always miss some combinations. **This chain of bugs is, in essence, the concentrated eruption of exactly those missed edge cases.**

---

## 1. The Incident "Storyline" (the most instructive part)

No single bug was fatal, but stacked together they formed a **self-perpetuating deadlock loop that survives crash-restart**. The full root-cause analysis is in `docs/incident/2026-05-18-shard40001-sync-unknown-ancestor.md` on the goquarkchain repo's `fix/sync-unknown-ancestor` branch. The chain:

1. **A race** (Bug1) quietly produced an inconsistent DB state during normal operation: after `AddBlockListForSync` finished inserting a block and released `m.chainmu`, it did network broadcasts (10–100 ms); within that window a concurrent `AddRootBlock` triggered `setHead`, which atomically deleted body + marker + canonical hash; when the network call returned, the shard layer — **outside the lock** — called `CommitMinorBlockByHash` again and re-wrote the marker.
   → End state: **body gone, canonical hash gone, but the commit marker present**.

2. `HasBlock` at the time only checked the marker (Bug5); seeing the marker present, it returned `true` → sync assumed the block was there and **skipped re-downloading it**.

3. Inserting the next block, `GetBlock(prev)` returned a **typed-nil** (non-nil interface wrapping a nil pointer); the `parent == nil` check failed (Bug2) → outright nil pointer panic, node crash.

4. After the panic was fixed it became a graceful `unknown ancestor`, but it was still stuck: the sync batch loop, on hitting an "already-known block," wrongly used `return nil` (Bug3), **abandoning the entire rest of the batch**.

5. Steps 1–4 above are the original incident chain. Then, **during the fix**, we tried a recovery approach of "roll back the root block (setRootBlock), fall back to an earlier block, and re-sync" to break the deadlock — and that rollback / replay path itself exposed a latent bug, e.g. `isSameRootChain` triggering `log.Crit` and exiting the process when an argument-order precondition is violated (Bug4). This isn't hit under normal operation.

Key point: **only after all of these bugs are fixed can the node recover**. Fix any subset and the loop just changes shape and keeps hanging. The "Why No Single Bug Was Sufficient" table in the incident doc lays this combinatorial explosion out clearly.

---

## 2. Bug Branch Inventory

| Branch / PR | Type | Core problem | Status |
|---|---|---|---|
| `fix/bug2-typed-nil` (#680) | Language trap | Go typed-nil interface makes `== nil` fail, causing panic | ✅ Merged to master |
| `fix/bug4-issameroottchain-guard` | Precondition | Inverted args trigger `log.Crit` crash | Partly reverted & redone |
| `fix/setHead-reorg` | Data persistence | setHead deletes body / resets to genesis / wrong write ordering in same-chain reorg | Evolved into `RollbackToBlock` |
| `fix/deser-list-length-oom` (#685, #691) | **Security** | P2P message declares an oversized length prefix → OOM crash | ✅ Merged to master |
| `fix/commit-status` | Aggregate refactor | Final convergence of the above + lock-model rework | Currently active branch, 23 commits |

---

## 3. Pitfalls Hit While Working With AI

Much of this code was written with AI assistance — a clear efficiency gain, but we also hit a set of AI-specific pitfalls. Recorded here as experience for future AI-assisted work of this kind:

**1. Every model has the "keeps getting more complex" disease.**
It tends to keep adding code and making repeated tweaks to "work around" a problem, introducing new problems, piling on more and more — instead of stepping back to find the root cause and subtract. A human has to actively call a stop, demand "solve it with less code," or just revert to a clean baseline and start over.

**2. When a test fails, the AI tends to "revert the change" rather than understand why the test failed.**
A concrete example is the Bug1 fix: the original code already wrote the commit marker once inside `insertChain`, then after broadcasting xshard and submitting the header wrote it again outside the lock — **this second write is redundant and is precisely the race root cause**. After deleting it, a test that still used "is the marker present" to judge whether the block was inserted began to fail. Shown that failure, the AI didn't fix the test's judging method (it should check body, not marker); instead it **rolled the redundant write back in** to make the test green — effectively re-introducing the bug it had just fixed correctly. Lesson: watch it to distinguish "the test exposed a real bug" from "the test's assertion is stale." Watching isn't enough — better to **tell it the correct fix directly** — e.g. in this case, explicitly instruct "the marker is redundant, don't write it back; switch to judging insertion success by body," rather than tossing out "the test broke, take a look," or it will most likely game the test with a revert again.

**3. The AI often doesn't recognize code it (or a human) already changed.**
In long sessions it forgets the current code state, re-proposes based on stale impressions, and overwrites existing changes — especially parts a human edited by hand that aren't in its own latest output. **Countermeasure: either have the AI make the change itself (then it recognizes it as its own), or before asking, explicitly tell it "which places I already changed by hand" so it aligns with the current code state before acting.**

**4. The AI will carry a premise you hand it all the way through implementation, even if that premise is itself flawed.**
The AI tends to take an idea I gave it during the interaction as an established premise and carry it to the end, rather than questioning it. A concrete example: I initially believed **`chainmu` (the coarse lock) guarding `insertChain` was enough, other places use `mu` (the fine lock), plus the upper layer has its own locking**. This assumption was actually flawed, but throughout subsequent design and edits the AI just followed this line of thinking; worse, when asked to review, it couldn't find the problem either — because it was reviewing under the same premise I had "set the tempo" with. It was ultimately **the reviewer's comment that caught it**. Lesson: **the AI won't question the premise for you, and in a context where its own premise is polluted it can't review its way out of it.** So critical reviews are best done in a **clean context**: first `clear` the prior interaction (this step is key — merely switching models while keeping the same polluted context lets the new model get dragged along by the original premise), then review again; switching person / model helps if you can, but only if the context is clean.

> Summary: AI massively accelerates writing code and looking things up, but it's unreliable at **maintaining global consistency, insisting on subtraction, questioning premises, and recognizing existing changes**. Humans must hold three control points — "goal / premise definition, root-cause judgment, and knowing when to stop" — and do critical reviews in a clean, post-`clear` context (just switching models without clearing the context doesn't help).

---

## 4. Why This Took So Long

The fix cycle stretched out; the time went mainly into three things:

**1. Repeated modification — the same piece of code changed many rounds.**
Not fixed in one pass, but advanced round by round, each round triggered by a newly discovered problem:

- First produced a version that **runs and rescues the node from the deadlock**, and committed it;
- then **split that big chunk of changes into multiple independent PRs** to submit and review separately;
- during the splitting and review, **discovered there was still a race condition hiding inside**, and went back to change it again;
- then surfaced a **scope-not-well-defined** problem — e.g. I had decided init-related logic was a one-time operation, out of scope, and deliberately left it untouched, but the reviewer's comment pointed out it had to be changed too, so it was changed again;
- finally found that **lock usage hadn't been thought through up front**: the holding ranges of `chainmu` / `mu` / `s.mu` were adjusted over multiple rounds (there are some edge-case paths that could go wrong, but with extremely low probability), and it only converged after walking every locking path and compiling [`locking.md`](./locking.md).

The common thread across these rounds: **the boundaries / premises / overall structure weren't drawn clearly before starting** (scope not aligned, race not foreseen, lock model not designed holistically), so it could only be "find one spot, rework one round."

**2. Interacting with the AI, and reviewing the AI's changes, took considerable time.**
Each of the pitfalls in Section 3 (getting more complex, reverting on error, not recognizing existing changes, following a wrong premise) takes several round-trips to correct; and in a context that's been "given the tempo," the AI's own review can't find the premise-level flaws either, so they often only surface after a `clear`-and-restart or the reviewer's comment.

**3. Testing + running a test node to watch logs.**
This class of race / recovery bug can't be confirmed by reading code alone; you have to actually **run the node and watch the logs** to see whether it still hangs, whether phenomena like unknown ancestor still appear — a high cost per iteration.

The latter two (AI interaction cost, slow node verification) also directly lead to the two goshard recommendations in the next section: let the AI review in a clean context, and push the "must run a node to verify" things down into fast race tests.

---

## 5. Takeaways for goshard Design & Development (the key section)

The thinking distilled from the previous sections (storyline, AI pitfalls, why it took so long) all points to concrete recommendations for goshard. Ten of them — the first seven are technical design principles, the last three are process and collaboration:

**1. Reuse Geth's mature code as much as possible; the less home-grown deviation, the safer.**
Almost every bug this time landed on **features Geth doesn't have and we added ourselves** (xshard broadcast, submit head, commit status). Geth's core call chains (insertChain, reorg, setHead, typed-nil handling) are mainnet-proven over many years; the moment we cut into them, or wrap home-grown logic around them, we enter territory with no reference and no precedent. Principle: **if you can reuse a Geth path directly, don't rewrite it; when you must add home-grown features, try to make them a separate layer outside Geth's core rather than embedding them into critical paths like insertChain / setHead**, so as to shrink the surface of "no counterpart to review against."

**2. Out-of-lock "patch-up" writes are a breeding ground for races.**
The root of Bug1: a write that should have been completed inside the lock (the commit marker) was moved out of the lock and redone because it had to wait for a network broadcast. Be wary of any pattern of "mutate state inside the lock, release the lock to do IO, then come back and patch in one more write." Principle: **the authoritative write of state should as much as possible be completed within the same lock's critical section, not patched up outside the lock after being interrupted by network IO**; if for performance (see item 3) you truly must release the lock midway, then you must treat this concurrent path as high-risk and back it with a targeted race test (see item 4), rather than relying on the gut feeling that "it probably won't collide."

**3. Lock vs. performance needs a deliberate balance.**
Bug1 actually stemmed from a reasonable performance consideration: not wanting to hold `m.chainmu` throughout the 10–100 ms network broadcast (which would block the whole chain's insertion), so the lock was released — but that's exactly what opened the race window. Conversely, `fix/commit-status`'s final convergence was to **widen the lock scope** (AddRootBlock holds chainmu across rewind + reset + index-rewrite), buying correctness at the cost of concurrency. There's no free lunch. goshard should **make this trade-off explicitly**: which critical sections must be atomic (even if slow), which can be done outside the lock (even if they need extra idempotency/validation as a backstop) — rather than deciding implicitly by gut feel. The accompanying principles (like "coarse lock before fine lock," "no network IO while holding a lock") should be written down and checked item by item in review.

**4. Home-grown concurrent paths need deterministic race tests; don't rely only on manual review + node runs as a backstop.**
As Background said, this review approach inherently can't catch race-type bugs (Bug1's window is only 10–100 ms), and the "run node + watch logs" verification loop is slow. Countermeasure: for **home-grown, Geth-referenceless concurrent paths**, add **targeted race tests (`-race` + a deterministic interleaving seam)**, and push the "must run a node to verify" parts down into fast, replayable unit / race tests. The `api_backend_test.go` added in `fix/commit-status` this time (using a seam to drive both empty-xshard branches with `-race` interleaving tests) is a demonstration of this idea and can serve as a template for goshard's concurrency tests.

**5. Locks must be defined clearly before use, and maintain a lock call-chain doc from day one.**
This time the lock model was "fix wherever a problem shows up," with lots of back-and-forth, and it was only at the very end that all locking paths were walked and compiled into [`locking.md`](./locking.md). The fundamental issue is that **locks weren't treated up front as something to "design first, then use."** goshard should do the opposite:

- **Define first**: first list clearly **which shared variables / state need protection** (e.g. `rootTip`, `currentBlock`, `confirmedHeaderTip`, the various tips / indexes), then decide which of them each lock **protects, where its responsibility boundary is, and in which scenarios it may be acquired** — pin down the "variable → lock" ownership before writing code, not add-as-you-go. Every protected variable should have a clear answer to "which lock owns it."
- **Fix the acquisition order**: give all locks a unified **acquisition order** (e.g. `s.mu → chainmu → mu`); no path may reverse it, eliminating AB-BA deadlock at the source.
- **Then use + keep the doc alive**: while coding, follow this definition, and from day one maintain a lock call-chain doc (which lock each path holds, acquisition order, why it's not re-entrant).

In one line: **concurrency correctness rarely converges by "patching point by point"; the lock model must first be designed as a whole (responsibilities + acquisition order) before use**; if this definition / doc exists before you start, it saves a lot of rework.

**6. Distinguish local (single-node / Geth-layer) from global (cluster / api_backend-layer) semantics; design in layers rather than sharing one function.**
A typical source of complexity this time was `HasBlock`: the same function was used both by the local Geth layer (asking "does this block's body exist in the local DB") and by the global `api_backend` layer (asking "is this block committed / usable in cluster semantics"). **The two scenarios define "have this block" fundamentally differently**; cramming them into one function made its semantics ping-pong over these three weeks (marker-only → marker+body → body-only → finally split into `HasBlock` / `HasCommittedBlock`), and every change rippled across a swath of callers. Lesson: goshard should, at design time, **clarify which queries / state are local-semantic and which are global-semantic, and layer them — each with its own function and name** — rather than letting one function serve two definitions across layers. Clear layering is itself complexity reduction.

**7. Defensive input validation: validate the length prefix before allocating.**
The OOM one (#685): a P2P message declared a 4-byte length ≈ 4.3 billion, and `reflect.MakeSlice` tried to allocate tens of GB before reading the first byte. The 128MB command-size cap doesn't stop it, because the allocation is driven by the "declared count." goshard's deserialization layer: **any length/count field coming from the network must be validated against the remaining buffer length before being used to allocate**, and give frame size a hard upper bound.

> The first seven are technical design principles. The three below are lessons from the **process and collaboration** that cost the most time this round, and matter just as much to goshard.

**8. Frame the scope, premises, and overall structure clearly before writing code.**
This round's rework (Section 4) almost all stemmed from the same thing: **boundaries / premises / overall structure not drawn clearly before starting** — scope not aligned with the reviewer (should init be touched), race not foreseen, lock model not designed holistically — so it became "find one spot, rework one round." Principle: before starting, write down three things and reach agreement with the reviewer — **(a) scope**: which modules this touches, which it explicitly does not; **(b) premises / invariants**: which assumptions it relies on (e.g. "this lock is enough," "init is a one-time operation"), and those assumptions themselves should be questioned once up front; **(c) overall structure**: if concurrency is involved, draw the lock model first (see item 5); if a state machine is involved, list the invariants first. This framing is cheap; overturning it at the review stage is expensive.

**9. Commit in small steps; don't "make a big change that runs, then go back and split PRs."**
This round's order was: first make a big change that rescued the node, then split it into multiple independent PRs — and it was during the splitting and review that a hidden race condition surfaced. Lesson: **a big change running as a whole doesn't mean each part is correct**; cut it into a batch of small, independent commits that can each be reviewed and tested on their own, so problems (especially races and boundaries) surface earlier in a smaller diff, instead of being fished out only when splitting PRs. goshard's concurrency / recovery changes especially should go in small steps.

**10. Developing with AI needs matching engineering constraints.**
goshard will use AI heavily too, so turn Section 3's pitfalls into positive constraints: **(a) do critical reviews in a clean context**: `clear` the conversation, or more thoroughly — `git clone` the code to a new directory and open a brand-new session to review (isolating even the working-tree state); merely switching models without clearing the context doesn't help, the polluted premise gets carried along; **(b) on a test failure / sticking point, either tell it the correct fix directly, or have it give a root-cause analysis and a plan first, and only change code after you confirm** — rather than tossing out "it broke, take a look" and letting it act on its own; otherwise it tends to game the test with a revert; the latter (analyze first, then change) is less effort — you don't have to think out the fix yourself, and it still blocks it from blindly reverting; **(c) have the AI make the change, or before asking explicitly tell it "which places the human already changed by hand"**, to keep it from failing to recognize existing changes and overwriting correct code; **(d) actively control the size of each change and watch complexity**: have it change in small steps, one small piece at a time, and step in as soon as complexity explodes (constantly adding code to work around a problem, introducing new ones), demanding subtraction or a revert to a clean baseline, rather than letting it snowball. The core: **the AI won't question the premise for you and doesn't guarantee global consistency — these two control points must be held by a human.**

---

## 6. The Direct Value of This Fix to goshard

Beyond the distilled experience, this fix itself carries a layer of **direct code value** for goshard: many of goshard's implementations are **copied from** goquarkchain right now, especially the QuarkChain-specific, Geth-referenceless logic (xshard, commit status, sync / recovery paths) — and those are exactly the disaster area of this bug chain. In other words, had we not fixed them, what goshard copied over would be **code carrying these race and recovery defects**; after the fix, the correctness of this logic is substantially solidified, and goshard now has a **cleaner, more reliable foundation** to keep building on. So this investment isn't just "rescuing a project that's being deprecated" — it's also clearing mines ahead of time for the very code goshard is going to reuse.

---

## 7. One-Line Summary

> This wasn't fixing 6 bugs; it was fixing one systemic problem — "a distributed state machine's invariants on the crash-recovery path being quietly violated in multiple places." Those invariants are concentrated in the **home-grown features Geth offers no reference for**, and are hard to exhaust by manual review. If goshard, from the very start, treats **atomicity of state, recovery invariants, interface nil-checking, and batch-processing control flow** as first-class design concerns, and backs its home-grown concurrent paths with deterministic race tests, it can avoid this whole class of pitfalls — and the portion of goquarkchain code it's going to reuse has, this time, been made more solid too.
