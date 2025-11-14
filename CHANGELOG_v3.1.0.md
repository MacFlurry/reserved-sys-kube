# Changelog v3.0.1 – English documentation refresh

## Summary
- README rewritten entirely in English while keeping the original structure and usage details.
- `kubelet_auto_config.sh` output, comments, and help text translated to English; log messages now match the README terminology.
- `rollback-kubelet-config.sh` already exposed English output, no functional change required.
- Added `--no-kubelet-restart` flag so the script can be invoked by systemd before kubelet boots (prevents recursive restarts).
- Internal version bumped to **3.0.1** to track the documentation-only release.
- Added optional systemd automation (templated unit + installer) to re-run `kubelet_auto_config.sh` automatically on control-plane and worker nodes.

## Notes
- The main script logic is unchanged apart from the new CLI flag used by the systemd integration; the automation remains optional.
- Scripts remain compatible with Kubernetes v1.26+ and the guidance described in earlier versions.
