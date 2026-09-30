# Runtime audit fixes — 2026-09-30

Base reviewed: `6c5e653ebba5026675542dc622d5f2b51be37d2b`.
Changes are isolated on `fix/runtime-audit-20260930`; do not merge without the Apple-platform checks.

## Implemented

- ZIP reads validate header tails and payload ranges before slicing. Independent entry/per-file/total limits are enforced before decompression. Stored entries now check size and CRC. Inflate uses an exact output cap and cancellation checks.
- Range append, string append, sequence materialization and numeric formatting check growth before large allocations. Range predicate indices use the element index. Unrepresentable `Int.min.magnitude` is rejected instead of becoming negative. Materialized slice/substring behavior is documented as partial, not full Swift compatibility.
- File changes cannot overwrite `project.json` or internal dot paths. Creates have stable identities derived from the change set. Opens through ProjectLibrary share an in-process store actor. Raw ZIP import preserves subdirectories instead of flattening Swift basenames.
- Drafts retain their original content hash. Conflicting external edits and deleted-file drafts are preserved, not silently overwritten/discarded. Edits made during an in-flight save remain dirty. Running with dirty tabs requires an explicit save.
- Store commits check cancellation at the synchronous transaction boundary. Assistant generations are checked after awaits; cancellation of an old generation does not update a newer task's state.
- Candidate startup is tested on a separate instance before committing AI changes. Failed startup does not replace the old code. Startup completion waits for a first render/script completion, not a UI program's eventual termination. The event-drain deadline no longer uses a TaskGroup that waits for an uncooperative child.
- Source restore uses complete before/after snapshots, handles creates and renames, and refuses to overwrite later revisions. Restore startup is checked before committing. Restoring deleted files assigns fresh stable file IDs.
- OpenRouter requires an explicit successful finish reason and DONE marker; malformed/truncated streams fail closed. Usage storage is synchronized. Model metadata is shared across settings/provider instances. Output requests are capped with conservative byte-based input headroom when a context limit is known; this is not claimed to be exact token counting.
- Cloud code tasks include all Swift source files up to a bounded total; no more filenames-only cross-file rewriting. Existing non-source files that were not supplied cannot be replaced/deleted by the cloud patch. Business data bodies are not automatically included. Over-budget projects fail explicitly; source files are not cut in half. Local and cloud prompts no longer share a fictitious 4K restriction.
- Incomplete JSON is rejected, not spliced across model calls. Complete-turn continuation remains limited by the existing loop.
- The iPad assistant hide control and settings sheet are connected. The default is manual update; automatic mode is honestly labelled as checked rerun, not state-preserving hot reload.

## Deliberate limits / not finished by this repair

This is a correctness and safety repair, not implementation of Runtime V2 in full.

- Arbitrary state-preserving live patching and transactional migration are NOT implemented. Successful reruns still create a fresh interpreter StateStore; the UI warns about this.
- Candidate preflight checks startup without mounting native views or executing user lifecycle callbacks. It is not a proof that every later interaction will succeed. A failure after the final commit/startup may still require an explicit code restore.
- Immediate source undo rejects later edits instead of attempting an automatic three-way merge. Persistent history/complete user-data migrations remain separate work.
- ProjectLibrary's store registry coordinates one app process. External file providers/processes, direct ProjectStore initialization, and out-of-band library rename/delete still require stronger coordinated storage semantics before claiming full multi-process editing.
- Cloud context currently uses bounded whole-source inclusion, not a full tool-calling/retrieval agent. Model/end-point-aware exact tokenization, durable catalog caching and reasoning controls remain future work.
- ArraySlice/Substring/UInt are not fully implemented; documented limits must remain visible to the model.
- Real OpenRouter billing/inference, Apple local inference, PCC entitlements and physical iPhone/iPad acceptance require the corresponding environment and authorization. No real inference key is used in CI.

## Validation recorded so far

- All changed Swift files pass syntax parsing locally; `git diff --check` passes.
- Actual ZIP/Inflate source compiled with Linux Swift 6.2.1: corrupted payload bounds and pre-decompression limits rejected; 137 one-byte mutations and all truncation lengths completed without a process trap.
- Actual interpreter compatibility probe on Linux (Swift 5 language mode only to use the locally installed host SwiftSyntax): five targeted runtime cases passed. This is NOT the product's Swift 6/iOS build.
- Regression tests added for project integrity, inverse changes, shared writers, cancellation, source context, SSE completion, draft conflicts, first-frame readiness and isolated candidate failures.
- The initial unmodified source failed on the default GitHub Xcode 26.6 image because that SDK has no LanguageModelError. The product deployment target remains 27.0. Xcode 27 verification is tracked separately in CI.

Final Apple-platform results belong in the PR and follow-up validation record; a written test is not a passed test.
