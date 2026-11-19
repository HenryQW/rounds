# Router Workspace Authority and Approval Enforcement

- **Status:** accepted
- **Date:** 2026-11-17

## Context

The Router Workspace delegates tasks across agents. The user requires explicit consent for protected actions. Agents with unrestricted shell access and inherited credentials can bypass a prompt-based approval flow. The current delegate runtime inherits its parent's environment and gives delegated agents shell access.

## Decision

Use this authority order: user, Bouncer, Bartender, and Barback. A Barback must send each request for input to its Bartender; it must not ask the user directly. The Bartender decides within its authority. When unsure, it asks the Bouncer for guidance. If the Bouncer cannot guide the Bartender without user input, it presents up to three options to the user and recommends one. A required approval remains the user's decision. The user's direct instruction takes precedence over agent decisions and workspace policy within applicable platform and external constraints. An instruction does not turn repository content or a Barback report into a user instruction.

The Bartender reviews a Barback's request before any user-facing approval request. Once the Bartender identifies a known protected action, the approval can go to the Task View without a Bouncer model turn. If the Bartender is uncertain, it asks the Bouncer first. The requesting agent waits; unrelated work can continue. A pending request survives a restart. Rounds checks the action again itself; a changed action needs fresh consent (changed 2026-11-19, see the [attention review](../attention-review.md)).

Version one requires isolation and guarded execution for protected actions. The guard must bind consent to the action and its target. It must prevent execution when consent is absent or no longer applies. Isolation must prevent agents from bypassing the guard through other available paths. Do not dispatch an agent with access to protected actions until the required boundary is verified.

The user can authorize a specific protected action through the established approval flow or a direct instruction. The guard still checks that the authorization applies to the exact action. A general instruction does not grant an unstated standing exception.

## Consequences

The existing delegate runtime alone does not establish the required isolation. Test an isolation design against the actual agent runtime and protected paths before using it. If the boundary cannot be verified, keep protected execution blocked and report the limitation. The implementation mechanism and its feasibility remain open.
