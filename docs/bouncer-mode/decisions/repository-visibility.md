# Bouncer Mode Repository Visibility

- **Status:** superseded on 2026-11-24 by decision "One bar for each organization" in [decisions.md](../decisions.md)
- **Date:** 2026-11-16
- **Log entry:** decision "Root repository visibility" in [decisions.md](../decisions.md)

## Context

Bouncer mode, as planned, coordinates tasks across independent repositories. The bar holds coordination records; it is not the Rounds source repository unless the user chooses it. Task records can contain information from more than one organization. Separate coordination repositories per organization would limit what one repository holds, but would also divide the central view of tasks.

## Decision

Use one root Git repository, the bar, for Bouncer mode. The repository can be public or private. Keep bar configuration in the repository. When setup identifies a public remote, ask the user to confirm that they understand it is public before using it. If its visibility cannot be verified, treat it as potentially public and obtain the user's acknowledgement before using it. An acknowledgement does not grant permission to push; each push still requires approval.

The bar can hold task records from multiple organizations when their user-defined boundaries and storage rules permit it. It contains coordination records, not copies of application code. Bartenders load only the organization context needed for their task.

Repository visibility does not grant permission to store an organization's information. When the bar is not approved for task details, keep the detailed records in an organization-approved local location. Put only permitted metadata in the root Git repository, including links or paths. Do not put restricted details in its commits or checkpoints. Show that the detailed records are not remotely backed up by the bar. If no approved local location is available, stop until an approved location is available. Git history can retain information after a later deletion, so decide what may be stored before recording it.

Version one uses Git for permitted records and runs on one machine. Distributed compute is deferred.
