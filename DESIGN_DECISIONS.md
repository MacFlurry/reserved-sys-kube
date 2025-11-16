# Design Decisions - kubelet_auto_config.sh

## Why kube-reserved is NOT enforced on control-plane nodes

### Summary
This script disables `kube-reserved` enforcement on control-plane nodes while keeping it active on worker nodes.

### Technical Rationale

#### 1. **Static Pod Architecture**
- Control-plane components (apiserver, etcd, scheduler, controller-manager) run as **static pods**
- Static pods are managed directly by kubelet, **outside the kubelet.slice cgroup**
- They are not subject to the same resource accounting as regular pods

#### 2. **Cgroup Hierarchy Complexity**
When `kube-reserved` is enforced on a control-plane:
```
/
├── system.slice (system-reserved enforced)
├── kubelet.slice (kube-reserved enforced) ← kubelet process itself
└── kubepods.slice (allocatable for pods)
    └── Static pods run here, NOT in kubelet.slice
```

The kubelet process consumes resources from `kubelet.slice`, but **static pods do not**.
Enforcing `kube-reserved` would only limit the kubelet process memory/CPU, which is typically minimal (~200-500MB).

#### 3. **Conservative Safety Approach**
We chose **NOT to enforce** `kube-reserved` on control-planes for these reasons:

##### Valid Safety Concerns:
- **Unpredictable control-plane load**: API server and etcd can have sudden resource spikes
- **Cgroup misconfiguration risk**: Incorrect cgroup paths can prevent kubelet startup
- **Static pod guarantees**: Control-plane pods should have unrestricted access to node resources
- **Industry convention**: GKE, EKS, and kubeadm follow this pattern


### Implementation Details

#### Control-plane enforcement:
```yaml
enforceNodeAllocatable:
  - "pods"
  - "system-reserved"
  # kube-reserved intentionally omitted
```

#### Worker node enforcement:
```yaml
enforceNodeAllocatable:
  - "pods"
  - "system-reserved"
  - "kube-reserved"  # Full accounting on workers
```

### Critical Assumption

**This design assumes control-plane nodes are tainted to prevent workload scheduling.**

If your control-plane nodes run user workloads (untainted), the risks change significantly:
- Static pods compete with workload pods for resources in kubepods.slice
- Without kube-reserved enforcement, workload pods can starve critical control-plane components
- This can lead to cluster instability (apiserver/etcd OOM, scheduler unresponsive)

**Recommendation for untainted control-planes:**
Consider enforcing kube-reserved to protect control-plane components, or ensure 
workloads have strict resource limits and lower QoS priority than control-plane pods.

### Alternative Approaches Considered
#### Option 1: Enforce kube-reserved everywhere
**Pros:**
- More accurate resource accounting
- Kubelet overhead properly tracked
**Cons:**
- Requires careful cgroup configuration
- Static pods still unaffected (they're not in kubelet.slice)
- Minimal benefit since kubelet itself uses little memory
**Decision:** Rejected - Complexity outweighs benefits
#### Option 2: Different kube-reserved values per node type
**Pros:**
- Flexibility for different workload patterns
**Cons:**
- Adds configuration complexity
- Still doesn't affect static pods
**Decision:** Rejected - Use case unclear
### References
- [Kubernetes Node Allocatable](https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- [Static Pods](https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/)
- [Cgroup hierarchy](https://www.kernel.org/doc/Documentation/cgroup-v2.txt)

---
## Summary
**This is a design choice based on operational safety, not a Kubernetes requirement.**
Technically, `kube-reserved` CAN be enforced on control-planes, but:
- It provides minimal value (kubelet itself uses ~200-500MB)
- It doesn't affect static pods (they run outside kubelet.slice)
- It adds cgroup configuration complexity
- Industry best practices avoid it

**We keep this conservative approach to prioritize stability and simplicity.**
