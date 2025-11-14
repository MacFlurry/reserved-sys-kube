# Changelog v3.1.1 – Config diff & rsync lab fixes

## Summary
- The kubelet auto-config script now generates the candidate YAML first, strips auto-generated headers, and compares it to the current kubelet config before touching `/var/lib/kubelet/config.yaml`. When nothing changes, the script logs a clear message and skips backup rotation, file writes, and kubelet restarts.
- Timestamp headers are only injected when the config truly changes which keeps the sanitized diff stable across runs.
- README updated with the new behavior and the changelog pointer refreshed.
- The Vagrant lab now uses an `rsync` synced folder for `/workspace`, preventing VMware HGFS mount issues while testing the systemd automation.

## Notes
- Functional validation covered repeated runs on a worker node (no backup churn), parameter changes (backup + apply), and rollback (kubelet restart failure restores the previous config).
- Version reported by `kubelet_auto_config.sh --help` is now **3.1.1**.
