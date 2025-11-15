# Changelog v3.1.2 – Kubelet auto-config removal tooling

## Highlights

- Added `remove-kubelet-auto-config.sh`, a safe cleanup utility that disables every `kubelet-auto-config@*.service`, deletes their drop-ins/env files, removes the helper scripts from `/usr/local/bin`, and leaves the running kubelet untouched.
- Updated the README with a dedicated **Removal** section, ensuring the new workflow sits next to installation/rollback guidance.
- Refreshed the Vagrant lab provisioning so control-plane and worker nodes automatically receive the removal script alongside the existing automation helpers.

## Validation

- Launched the cp1/w1 lab via `tests/vagrant`, validated the manual script execution path, the systemd installer, and the new removal script on both nodes.
- Restarted kubelet services to confirm `kubelet-auto-config@*.service` reruns correctly and that backups are only rotated when the config changes.
- Ran `remove-kubelet-auto-config.sh` on cp1 and w1 to confirm the cleanup leaves the cluster healthy (`kubectl get nodes`, `kubectl get pods -A`) while removing every installed asset.
