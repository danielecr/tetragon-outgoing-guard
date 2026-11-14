# Tetragon Outgoing Guard

Deterministic, kernel-level runtime security policies for **Cilium Tetragon** designed to block stealthy post-exploitation implants (such as **GSocket**), unauthorized reverse shells, and interactive container escapes (`docker exec ... sh`).

## Why this exists

Recent threat intelligence (such as Microsoft's analysis of threat actors weaponizing **GSocket**) highlights how attackers maintain persistent C2 access on Linux container hosts even after initial vulnerabilities are patched:
- **No fixed C2 IP/domain:** Traffic is relayed over public shared infrastructure via outbound TLS connections, bypassing inbound firewall rules.
- **Process masquerading:** Binaries are staged in memory-backed directories (`/dev/shm`) and executed with `exec -a` to mimic kernel threads (e.g., `[kaluad]`).
- **Short-lived payloads:** User-space polling scripts inspecting `ps` or `ss` suffer from race conditions against fast `curl | sh` drop-and-execute chains.

Instead of polling in user space or relying on heuristic/AI anomaly detection, this repository provides declarative **eBPF `TracingPolicy` manifests** that enforce two deterministic rules synchronously inside the Linux kernel:

1. **Container Executable Allowlisting (`security_bprm_check`):** Every binary executed inside a non-host PID namespace must match an explicit allowlist of ground-truth binary paths. Anything else—including `/bin/sh`, `/bin/bash`, `curl`, or binaries staged in `/dev/shm`—receives an immediate, synchronous kernel `SIGKILL` before execution completes.
2. **Host Outbound TCP Zero-Trust (`tcp_connect`):** On dedicated container hosts (Docker, Swarm, or Kubernetes nodes) where all application workloads run inside containers, any process in the root `host_ns` initiating a TCP connection to a public (non-RFC1918) IP address is killed immediately.

---

## Repository Structure

```text
tetragon-outgoing-guard/
├── README.md
├── LICENSE
├── policies/
│   ├── standalone-docker.yaml      # TracingPolicy for Docker / Swarm / standalone Linux hosts
│   └── kubernetes-workload.yaml    # TracingPolicyNamespaced with podSelector for K8s clusters
├── scripts/
│   └── discover-binaries.sh        # Helper to extract ground-truth binary paths from running containers
└── examples/
    └── docker-compose.tetragon.yml # Deploy Tetragon via Docker Compose or Docker Swarm (global mode)
```

---

## Quickstart (Docker / Docker Swarm / Standalone Linux)

### Step 1: Discover allowed binaries in your running containers
Never enable `action: Sigkill` before mapping all legitimate binaries used by your containers (including `tini`, entrypoint wrappers, and application runtimes).

Run the discovery helper on your host:
```bash
chmod +x scripts/discover-binaries.sh
sudo ./scripts/discover-binaries.sh
```

Copy the output paths into `policies/standalone-docker.yaml` under `matchBinaries`.

### Step 2: Test in Audit Mode first (Recommended)
Before enforcing `Sigkill`, comment out the `matchActions: - action: Sigkill` blocks in `policies/standalone-docker.yaml` and start Tetragon using the provided Compose file:

```bash
docker compose -f examples/docker-compose.tetragon.yml up -d
```

Watch live kernel events to verify no legitimate workload triggers the policy:
```bash
docker exec -it tetragon tetra getevents -o compact
```

### Step 3: Enforce Kernel-Level `Sigkill`
Uncomment `matchActions: - action: Sigkill` in `policies/standalone-docker.yaml` and restart Tetragon:

```bash
docker compose -f examples/docker-compose.tetragon.yml restart tetragon
```

Verify enforcement by attempting to spawn a shell inside any running container:
```bash
docker exec -it <your-container> sh
# Expected output: Killed
```

---

## Quickstart (Kubernetes)

Tetragon runs alongside any CNI (including **Calico**, Flannel, or Cilium) without conflicts, as it hooks into kernel LSM/kprobe points rather than CNI packet routing.

1. Install Tetragon via Helm:
   ```bash
   helm repo add cilium https://cilium.io
   helm repo update
   helm install tetragon cilium/tetragon -n kube-system
   ```
2. Edit `policies/kubernetes-workload.yaml` to match your Pod labels and allowed binaries, then apply:
   ```bash
   kubectl apply -f policies/kubernetes-workload.yaml
   ```

---

## Maintenance Windows (`apt upgrade` on Host)

Because `standalone-docker.yaml` blocks outbound public TCP connections from `host_ns`, package managers on the host (`apt`, `dnf`, `yum`) will be terminated while the policy is active.

Use a shell alias to temporarily unload the policy during host updates:
```bash
alias sysupgrade='docker compose -f /path/to/examples/docker-compose.tetragon.yml stop tetragon && sudo apt update && sudo apt upgrade -y; docker compose -f /path/to/examples/docker-compose.tetragon.yml start tetragon'
```
*(Note: When the Tetragon user-space daemon stops, the kernel automatically closes its BPF file descriptors and unloads the hooks until the container starts again.)*

---

## Caveats & Edge Cases
- **Interpreted languages (Python, Node.js, PHP):** `security_bprm_check` evaluates the binary executable passed to `execve` (e.g., `/usr/local/bin/python3.12`), not the `.py` script argument. Allowlisting the interpreter allows any script executed by that interpreter, while still blocking sub-shells (`os.system()`, `subprocess` calling `/bin/sh`).
- **Healthchecks:** If your `Dockerfile` or `docker-compose.yml` defines a `HEALTHCHECK` using `curl` or `wget`, those binaries will be killed unless added to the allowlist. Prefer native TCP/HTTP probes or distroless/Go healthcheck binaries.

