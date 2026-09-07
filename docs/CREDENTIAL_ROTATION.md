# Credential containment and rotation

The exposed session-signing key must not remain a verification fallback. Rotating it invalidates every existing app session, so backup protection must be deployed first or in the same controlled cutover.

1. Save the current user and sync JSON directories to a private directory outside the checkout. Restrict directory permissions to 0700 and files to 0600; verify copies by checksum and restore/parse them in an isolated directory. Never include configuration secrets in the backup evidence report.
2. Run the offline containment suite and review the candidate. Copy the reviewed backend modules into a separate, immutable release directory. Preserve the selected Python runtime and original data location explicitly; verify all imported modules are included. Development changes must not alter the running release.
3. With a generated fixture account and separate temporary data root, start the candidate on a disposable loopback port. Verify legacy uploads return 426 without changing its snapshot and download still works. Verify query-token access logs and exceptions are redacted. Record the candidate's hashes and test results.
4. Generate a new random signing key inside a private script and install it atomically into the selected private environment source. Do not print it, pass it on a command line, write it into Git, or preserve the compromised key as fallback. Restrict the configuration file to 0600.
5. Point the single-process service to the verified release and its explicit persistent data root, then restart. This cutover must activate the legacy-upload guard with the new key. If the guard is deployed separately, verify it before rotating. Keep the guarded release for rollback.
6. Verify old-key sessions fail and the new service is reachable without exposing token-bearing URLs. Perform normal Apple sign-in on the device, confirm server snapshot reads, and record any device-dependent check still pending. The old client will show a sync failure for uploads; this is deliberate until the versioned client is deployed.
7. Run the redacted current-tree/history audit. Current source must have no usable key. Record affected refs and collaborator impact separately. Shared-history rewriting requires explicit authorization; rotation is effective without a rewrite.

Rollback changes application code/environment only to a release retaining legacy-write protection. Retain the new signing key and the latest user/sync data. Do not restore the compromised credential or stale user snapshots. Additional workers are unsupported until the sync store has a shared transactional lock.

See REMEDIATION_PROGRESS.md for actual completion evidence. This runbook alone does not mean runtime rotation has happened.
