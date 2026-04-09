---
description: Run all four audit commands in sequence — engineering, performance, documentation, and design.
argument-hint: "[path-or-module (optional)]"
---

# Full Audit — Engineering + Performance + Documentation + Design

Run all four audit commands in sequence, then produce a combined summary.

**Instructions:**

1. Invoke `/engineering-audit $ARGUMENTS` and wait for it to complete.
2. Invoke `/performance-audit $ARGUMENTS` and wait for it to complete.
3. Invoke `/docs-audit $ARGUMENTS` and wait for it to complete.
4. Invoke `/design-audit $ARGUMENTS` and wait for it to complete.
5. After all four audits complete, print a **Combined Audit Summary**:
   - **Findings per audit:** total count from each of the four audits.
   - **Top 5 cross-cutting improvements:** issues that appeared in multiple audits
     or that would have the highest overall impact on codebase health.
   - **Overall codebase health assessment:** one paragraph synthesizing the four
     audits into a holistic view of the project's quality, performance,
     documentation, and design state.
