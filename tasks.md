

clone https://github.com/temporal-sa/temporal-design-patterns.git in a temp folder in ./

research design pattern as a solution architect

use context builder skill

do below:


Use top-down seeding when no entry point is known; otherwise start from the named
symbol, endpoint, workflow, or file.

1. Read applicable repository instructions, writing conventions, and existing documentation hierarchy.
2. Identify relevant language, framework, dependency, runtime, and deployment versions.
3. Map only the components needed for the reader's goal.
4. Find the entry point and trace the public flow through interfaces, types,
   configuration, persistence, events, external services, and operations as needed.
5. Identify the source of truth for each contract: code, schema, configuration,
   generated specification, ADR, test, or operational definition.
6. Inspect existing documents for terminology and links, then verify factual
   claims against current sources rather than copying stale prose.
7. Determine configuration precedence, defaults, required values, validation,
   and safe examples when configuration is in scope.
8. Inspect tests or implementation bodies only when public contracts do not
   explain a behaviour the reader needs.
9. Use a bundled reading-list script when Java, Kotlin, Python, or TypeScript
   relationships need ranking.
10. Record missing intent or operational knowledge under Open questions.

Choose Standard for a bounded guide or reference and Deep for service-level or
onboarding documentation. Split larger documentation by reader task rather than
building a single exhaustive document. Follow references one hop at a time and
stop when the reader goal can be completed accurately.

## Ranked documentation checklist

Apply the items relevant to the selected document type:

1. State purpose, audience, prerequisites, supported scope, and non-goals.
2. Use repository terminology consistently and define unavoidable jargon.
3. Describe observable behaviour before internal implementation details.
4. Make setup and task steps ordered, complete, safe, and independently checkable.
5. Show exact public signatures, commands, schemas, or keys only from verified sources.
6. Explain validation, errors, recovery, and cleanup for task-oriented guidance.
7. Document authentication, authorization, secret handling, and data sensitivity safely.
8. Document configuration precedence and environment-specific differences.
9. Document compatibility, migrations, deployment order, and rollback where relevant.
10. Document timeouts, retries, idempotency, concurrency, and consistency where relevant.
11. Link related source, contracts, runbooks, dashboards, and decisions with stable paths.
12. Use examples that match current interfaces and avoid environment-specific secrets.
13. Distinguish guarantees from implementation details that may change.
14. Remove redundant detail that does not help the reader accomplish the stated goal.
15. Verify commands, links, anchors, diagrams, and examples when feasible.

## Evidence and writing standards

- Label every research-pack claim `[verified]`, `[inferred]`, or `[assumed]`.
- Cite verified claims as `path:line` or an exact external reference.
- Do not publish an inference as fact; either verify it or phrase it as an open question.
- Prefer anchors and summaries over large copied excerpts.
- Preserve exact syntax for signatures, schemas, configuration keys, commands,
  and error strings when the reader must reproduce them.
- Do not claim a command, example, or deployment procedure was tested unless it ran.
- When source and existing documentation disagree, report the conflict and its impact.
- Verify version-sensitive behaviour against the repository's versions and
  authoritative documentation when repository evidence is insufficient.

## Required output

Write two files with different lifespans:

### `<topic>.md`

Write clean, audience-appropriate prose ready to ship. Do not include confidence
labels or the research ledger. Use the requested document type and length. If a
material fact remains unresolved, state the limitation plainly or omit the
unsupported procedure rather than guessing.

### `doc-result.md`

Write the evidence pack with:

- **Objective:** topic, document type, audience, reader goal, and scope.
- **Map:** relevant paths and one-line roles.
- **Public surface:** exact signatures, schemas, commands, and configuration keys needed by the document.
- **Findings:** labelled claims with `path:line` anchors.
- **Conflicts:** stale or contradictory sources and how the draft handled them.
- **Open questions:** unresolved intent and every inference excluded from the published draft.
- **Validation:** commands, examples, links, and render checks executed, with results.
- **Not included:** deliberately excluded components or reader tasks.

End the response with a concise summary and links to both files. Keep
`doc-result.md` until the document is verified; it is the audit trail for future
updates and can be deleted after publication if project policy permits.
