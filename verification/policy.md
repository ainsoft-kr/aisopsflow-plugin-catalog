# Verification Policy

A verified plugin should satisfy:

- manifest schema valid
- image pinned by digest
- signed image evidence declared in manifest and attached as a catalog artifact
- internal auth verification implemented
- compatibility declared
- vulnerability scan summary declared in manifest and attached as a catalog artifact
- no critical known vulnerabilities at verification time

This repository does not publish plugin images and does not publish Core or Runner images.
Those release responsibilities stay with the plugin owner and the private enterprise repository respectively.

For official plugins, `verification.signature_ref` and `verification.vulnerabilities.report_ref`
must point at committed artifacts in this repository so catalog validation can reproduce the policy check.
