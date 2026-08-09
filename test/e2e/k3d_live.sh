#!/bin/sh
set -eu

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf "missing required command: %s\n" "$1" >&2
    exit 127
  }
}

require_command k3d
require_command kubectl
require_command mix
require_command git
require_command curl

log_step() {
  printf "\n==> %s\n" "$1"
}

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cli_bin="$repo_root/twelvgaige"
cluster="${K3D_CLUSTER_PREFIX:-twelvgaige-live}-$(date +%s)-$$"
namespace="${K3D_NAMESPACE:-default}"
context="k3d-$cluster"
fixture_deployment="twelvgaige-live-fixture"
fixture_selector="app=$fixture_deployment"
reader_context="twelvgaige-live-reader"
writer_context="twelvgaige-live-writer"
http_fixture="twelvgaige-http-fixture"
http_local_port=$((18000 + $$ % 20000))
http_base_url="http://127.0.0.1:$http_local_port"
artifact_dir="${TWELVGAIGE_LIVE_ARTIFACT_DIR:-/tmp/twelvgaige-live-k3d-$cluster}"
secret_dir="${TMPDIR:-/tmp}/twelvgaige-live-secrets-$cluster"
reader_kubeconfig="$secret_dir/reader.kubeconfig"
writer_kubeconfig="$secret_dir/writer.kubeconfig"
daemon_pid=""
port_forward_pid=""
mkdir -p "$artifact_dir"
artifact_dir=$(CDPATH= cd -- "$artifact_dir" && pwd)
rm -rf \
  "$artifact_dir/workflows" \
  "$artifact_dir/gitops-repo" \
  "$artifact_dir/broken-rollout" \
  "$artifact_dir/daemon-resume" \
  "$artifact_dir/fanout" \
  "$artifact_dir/http-live" \
  "$artifact_dir/git-policy" \
  "$artifact_dir"/*.json \
  "$artifact_dir"/*.sqlite3 \
  "$artifact_dir"/*.txt \
  "$artifact_dir"/summary.env
mkdir -p "$secret_dir"
{
  printf "suite=k3d\n"
  printf "cluster=%s\n" "$cluster"
  printf "namespace=%s\n" "$namespace"
  printf "admin_context=%s\n" "$context"
  printf "context=%s\n" "$reader_context"
  printf "writer_context=%s\n" "$writer_context"
  printf "fixture_deployment=%s\n" "$fixture_deployment"
  printf "fixture_selector=%s\n" "$fixture_selector"
  printf "http_fixture=%s\n" "$http_fixture"
  printf "http_base_url=%s\n" "$http_base_url"
} > "$artifact_dir/summary.env"

cleanup() {
  status=$?

  if [ "$status" -ne 0 ]; then
    mkdir -p "$artifact_dir"
    kubectl --context "$context" get nodes -o wide > "$artifact_dir/nodes.txt" 2>&1 || true
    kubectl --context "$context" get all -A -o wide > "$artifact_dir/all.txt" 2>&1 || true
    kubectl --context "$context" get events -A --sort-by=.lastTimestamp > "$artifact_dir/events.txt" 2>&1 || true
  fi

  if [ -n "${daemon_pid:-}" ] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
  fi

  if [ -n "${port_forward_pid:-}" ] && kill -0 "$port_forward_pid" 2>/dev/null; then
    kill "$port_forward_pid" 2>/dev/null || true
  fi

  k3d cluster delete "$cluster" >/dev/null 2>&1 || true
  rm -rf "$secret_dir"
  exit "$status"
}

trap cleanup EXIT INT TERM

bootstrap_cluster() {
k3d cluster create "$cluster" --wait --agents 0
kubectl --context "$context" get namespace "$namespace" >/dev/null

kubectl --context "$context" -n "$namespace" create deployment "$fixture_deployment" \
  --image=busybox:1.36 \
  -- /bin/sh -c 'while true; do echo "twelvgaige-live-log fixture-ready"; sleep 2; done'
kubectl --context "$context" -n "$namespace" rollout status "deployment/$fixture_deployment" --timeout=90s

pod_name=""
i=0
while [ "$i" -lt 30 ]; do
  pod_name="$(kubectl --context "$context" -n "$namespace" get pods -l "$fixture_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "$pod_name" ] && kubectl --context "$context" -n "$namespace" logs "$pod_name" --tail=20 2>/dev/null | grep -q "twelvgaige-live-log"; then
    break
  fi
  i=$((i + 1))
  sleep 2
done

if [ -z "$pod_name" ]; then
  printf "fixture pod was not ready\n" >&2
  exit 1
fi

kubectl --context "$context" -n "$namespace" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: twelvgaige-http-fixture
data:
  server.py: |
    import json
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    EVENTS = "/tmp/twelvgaige-events.jsonl"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, _format, *args):
            return

        def _send(self, status, body, content_type="application/json"):
            if isinstance(body, str):
                payload = body.encode("utf-8")
            else:
                payload = json.dumps(body).encode("utf-8")
            self.send_response(status)
            self.send_header("content-type", content_type)
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path == "/healthz":
                self._send(200, "twelvgaige-http-live-ok", "text/plain")
            elif self.path == "/version":
                self._send(200, {"name": "twelvgaige-http-fixture", "version": "1.0.0"})
            elif self.path == "/events":
                events = []
                try:
                    with open(EVENTS, "r", encoding="utf-8") as handle:
                        for line in handle:
                            if line.strip():
                                events.append(json.loads(line))
                except FileNotFoundError:
                    pass
                self._send(200, {"events": events})
            else:
                self._send(404, {"error": "not_found"})

        def do_POST(self):
            if self.path != "/events":
                self._send(404, {"error": "not_found"})
                return
            length = int(self.headers.get("content-length", "0"))
            body = self.rfile.read(length).decode("utf-8")
            event = {"body": body}
            with open(EVENTS, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(event) + "\n")
            self._send(202, {"status": "accepted", "token": "secret", "body": body})

    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: twelvgaige-http-fixture
spec:
  replicas: 1
  selector:
    matchLabels:
      app: twelvgaige-http-fixture
  template:
    metadata:
      labels:
        app: twelvgaige-http-fixture
    spec:
      containers:
        - name: server
          image: python:3.12-alpine
          command: ["python", "/app/server.py"]
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: server
              mountPath: /app
      volumes:
        - name: server
          configMap:
            name: twelvgaige-http-fixture
---
apiVersion: v1
kind: Service
metadata:
  name: twelvgaige-http-fixture
spec:
  selector:
    app: twelvgaige-http-fixture
  ports:
    - name: http
      port: 8080
      targetPort: 8080
EOF
kubectl --context "$context" -n "$namespace" rollout status "deployment/$http_fixture" --timeout=120s

kubectl --context "$context" -n "$namespace" port-forward --address 127.0.0.1 "service/$http_fixture" "$http_local_port:8080" \
  > "$artifact_dir/http-port-forward.log" 2>&1 &
port_forward_pid=$!

i=0
while [ "$i" -lt 100 ]; do
  if curl -fsS "$http_base_url/healthz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$port_forward_pid" 2>/dev/null; then
    printf "HTTP fixture port-forward exited early\n" >&2
    cat "$artifact_dir/http-port-forward.log" >&2 || true
    exit 1
  fi
  i=$((i + 1))
  sleep 0.1
done
if ! curl -fsS "$http_base_url/healthz" > "$artifact_dir/http-healthz.txt"; then
  printf "HTTP fixture port-forward did not become ready\n" >&2
  cat "$artifact_dir/http-port-forward.log" >&2 || true
  exit 1
fi

kubectl --context "$context" -n "$namespace" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: twelvgaige-live-reader
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: twelvgaige-live-writer
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: twelvgaige-live-reader
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: twelvgaige-live-reader
subjects:
  - kind: ServiceAccount
    name: twelvgaige-live-reader
    namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: twelvgaige-live-reader
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: twelvgaige-live-writer
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: twelvgaige-live-writer
subjects:
  - kind: ServiceAccount
    name: twelvgaige-live-writer
    namespace: $namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: twelvgaige-live-writer
EOF

reader_token="$(kubectl --context "$context" -n "$namespace" create token twelvgaige-live-reader --duration=20m)"
writer_token="$(kubectl --context "$context" -n "$namespace" create token twelvgaige-live-writer --duration=20m)"
cluster_server="$(kubectl config view --raw --minify --context "$context" -o jsonpath='{.clusters[0].cluster.server}')"
cluster_ca="$(kubectl config view --raw --minify --context "$context" -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

cat > "$reader_kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: twelvgaige-live
    cluster:
      server: $cluster_server
      certificate-authority-data: $cluster_ca
contexts:
  - name: $reader_context
    context:
      cluster: twelvgaige-live
      namespace: $namespace
      user: twelvgaige-live-reader
current-context: $reader_context
users:
  - name: twelvgaige-live-reader
    user:
      token: $reader_token
EOF
chmod 600 "$reader_kubeconfig"

cat > "$writer_kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: twelvgaige-live
    cluster:
      server: $cluster_server
      certificate-authority-data: $cluster_ca
contexts:
  - name: $writer_context
    context:
      cluster: twelvgaige-live
      namespace: $namespace
      user: twelvgaige-live-writer
current-context: $writer_context
users:
  - name: twelvgaige-live-writer
    user:
      token: $writer_token
EOF
chmod 600 "$writer_kubeconfig"
}

run_kubernetes_tool_tests() {
TWELVGAIGE_K8S_LIVE=1 \
  TWELVGAIGE_K8S_CONTEXT="$reader_context" \
  TWELVGAIGE_K8S_NAMESPACE="$namespace" \
  TWELVGAIGE_K8S_KUBECONFIG="$reader_kubeconfig" \
  TWELVGAIGE_K8S_FIXTURE_DEPLOYMENT="$fixture_deployment" \
  TWELVGAIGE_K8S_FIXTURE_SELECTOR="$fixture_selector" \
  TWELVGAIGE_K8S_TIMEOUT_MS="${TWELVGAIGE_K8S_TIMEOUT_MS:-30000}" \
  MIX_ENV=test \
  mix test --include k8s_live test/twelvgaige/integration/kubernetes_live_test.exs
}

run_basic_cli_round() {
workflow_dir="$artifact_dir/workflows"
agent_dir="$workflow_dir/agents"
mock_responses="$artifact_dir/mock-responses.json"
round_output="$artifact_dir/cli-round.json"
mkdir -p "$agent_dir"

cat > "$workflow_dir/k3d_live_round.yaml" <<EOF
kind: workflow
id: k3d_live_round
name: K3D Live Round
version: 1.0.0
shots:
  - id: inspect_fixture_pods
    kind: slug
    agent: k3d_live_agent
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Inspect the live k3d fixture pods.
EOF

cat > "$agent_dir/k3d_live_agent.yaml" <<EOF
kind: agent
id: k3d_live_agent
name: K3D Live Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Inspect only the configured live Kubernetes fixture.
tools:
  allowed: [kubectl_get]
  denied: [kubectl_delete, kubectl_exec]
EOF

cat > "$mock_responses" <<EOF
[
  {
    "content": "reading fixture pods",
    "tool_calls": [
      {
        "name": "kubectl_get",
        "input": {
          "context": "$reader_context",
          "namespace": "$namespace",
          "resource": "pods",
          "selector": "$fixture_selector",
          "limit": 3
        }
      }
    ],
    "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
  },
  {
    "content": "fixture pods inspected",
    "tool_calls": [],
    "usage": {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
  }
]
EOF

cd "$repo_root"
MIX_ENV=test mix escript.build >/dev/null
KUBECONFIG="$reader_kubeconfig" \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$mock_responses" \
  TWELVGAIGE_STORE_SQLITE="$artifact_dir/cli-round.sqlite3" \
  "$cli_bin" round run "$workflow_dir/k3d_live_round.yaml" --format json > "$round_output"

ROUND_OUTPUT="$round_output" FIXTURE_DEPLOYMENT="$fixture_deployment" MIX_ENV=test mix run -e '
path = System.fetch_env!("ROUND_OUTPUT")
fixture = System.fetch_env!("FIXTURE_DEPLOYMENT")
round = path |> File.read!() |> Jason.decode!()

unless round["status"] == "complete" do
  raise "expected complete round, got #{inspect(round["status"])}"
end

shot = Enum.find(round["shots"], &(&1["id"] == "inspect_fixture_pods"))
unless shot && shot["status"] == "complete" do
  raise "expected complete inspect_fixture_pods shot, got #{inspect(shot)}"
end

tool_call =
  shot
  |> get_in(["output", "tool_calls"])
  |> Enum.find(&(&1["name"] == "kubectl_get"))

unless tool_call do
  raise "expected kubectl_get tool call in CLI round output"
end

output = tool_call["output"]
unless get_in(output, ["summary", "item_count"]) >= 1 do
  raise "expected kubectl_get to return at least one fixture pod"
end

pod_names = Enum.map(output["items"] || [], &get_in(&1, ["metadata", "name"]))
unless Enum.any?(pod_names, &(is_binary(&1) and String.contains?(&1, fixture))) do
  raise "expected fixture pod in CLI round output, got #{inspect(pod_names)}"
end
'
}

run_http_live_rounds() {
http_dir="$artifact_dir/http-live"
http_output="$artifact_dir/http-live-round.json"
http_denied_output="$artifact_dir/http-denied-round.json"
http_responses="$artifact_dir/http-live-mock-responses.json"
http_denied_responses="$artifact_dir/http-denied-mock-responses.json"
mkdir -p "$http_dir/workflows/agents"

cat > "$http_dir/workflows/http_live_round.yaml" <<EOF
kind: workflow
id: k3d_http_live_round
name: K3D HTTP Live Round
version: 1.0.0
shots:
  - id: get_healthz
    kind: slug
    agent: k3d_http_agent
    tools: [http_get]
    choke:
      max_iterations: 3
    prompt: Fetch the live HTTP fixture health endpoint.
  - id: approve_webhook
    kind: safety
    depends_on: [get_healthz]
    prompt: Approve posting an event to the live HTTP fixture.
  - id: post_event
    kind: slug
    agent: k3d_http_agent
    depends_on: [approve_webhook]
    tools: [http_post]
    choke:
      max_iterations: 3
      tool_safety: destructive
    prompt: Post an event to the live HTTP fixture.
  - id: read_events
    kind: slug
    agent: k3d_http_agent
    depends_on: [post_event]
    tools: [http_get]
    choke:
      max_iterations: 3
    prompt: Read back recorded events from the live HTTP fixture.
EOF

cat > "$http_dir/workflows/http_denied_round.yaml" <<EOF
kind: workflow
id: k3d_http_denied_round
name: K3D HTTP Denied Round
version: 1.0.0
shots:
  - id: denied_get
    kind: slug
    agent: k3d_http_agent
    tools: [http_get]
    choke:
      max_iterations: 3
    prompt: Attempt a blocked HTTP GET.
EOF

cat > "$http_dir/workflows/agents/k3d_http_agent.yaml" <<EOF
kind: agent
id: k3d_http_agent
name: K3D HTTP Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Exercise HTTP tools against the live k3d fixture.
tools:
  allowed: [http_get, http_post]
  denied: []
EOF

cat > "$http_responses" <<EOF
{
  "responses_by_shot": {
    "get_healthz": [
      {
        "content": "fetch health",
        "tool_calls": [
          {
            "name": "http_get",
            "input": {
              "url": "$http_base_url/healthz",
              "max_bytes": 256
            }
          }
        ]
      },
      {"content": "health ok", "tool_calls": []}
    ],
    "post_event": [
      {
        "content": "post event",
        "tool_calls": [
          {
            "name": "http_post",
            "input": {
              "url": "$http_base_url/events",
              "body": "{\"event\":\"k3d-http-live\",\"source\":\"twelvgaige\"}",
              "content_type": "application/json",
              "max_bytes": 512,
              "confirm": true
            }
          }
        ]
      },
      {"content": "event posted", "tool_calls": []}
    ],
    "read_events": [
      {
        "content": "read events",
        "tool_calls": [
          {
            "name": "http_get",
            "input": {
              "url": "$http_base_url/events",
              "max_bytes": 2048
            }
          }
        ]
      },
      {"content": "events read", "tool_calls": []}
    ]
  }
}
EOF

TWELVGAIGE_HTTP_ALLOWED_HOSTS="127.0.0.1" \
  TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS=1 \
  TWELVGAIGE_HTTP_TIMEOUT_MS=5000 \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$http_responses" \
  TWELVGAIGE_STORE_SQLITE="$artifact_dir/http-live.sqlite3" \
  "$cli_bin" round run "$http_dir/workflows/http_live_round.yaml" --approve-safety --format json > "$http_output"

ROUND_OUTPUT="$http_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "complete", do: raise("expected HTTP live round complete")
shots = Map.new(round["shots"], &{&1["id"], &1})
for id <- ["get_healthz", "approve_webhook", "post_event", "read_events"] do
  unless get_in(shots, [id, "status"]) == "complete", do: raise("expected #{id} complete")
end

health = get_in(shots, ["get_healthz", "output", "tool_calls", Access.at(0), "output"])
unless health["status"] == 200, do: raise("expected health status 200")
unless health["body"] == "twelvgaige-http-live-ok", do: raise("expected health body")

post = get_in(shots, ["post_event", "output", "tool_calls", Access.at(0), "output"])
unless post["status"] == 202, do: raise("expected post status 202")
unless String.contains?(post["body"], "[REDACTED]"), do: raise("expected redacted post response")

events_body = get_in(shots, ["read_events", "output", "tool_calls", Access.at(0), "output", "body"])
events = Jason.decode!(events_body)
unless Enum.any?(events["events"], fn event -> String.contains?(event["body"], "k3d-http-live") end) do
  raise("expected posted event in fixture event log")
end
'

cat > "$http_denied_responses" <<EOF
{
  "responses_by_shot": {
    "denied_get": [
      {
        "content": "blocked fetch",
        "tool_calls": [
          {
            "name": "http_get",
            "input": {
              "url": "$http_base_url/healthz",
              "max_bytes": 256
            }
          }
        ]
      }
    ]
  }
}
EOF

set +e
  TWELVGAIGE_HTTP_ALLOWED_HOSTS="example.com" \
  TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS=1 \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$http_denied_responses" \
  TWELVGAIGE_STORE_SQLITE="$artifact_dir/http-denied.sqlite3" \
  "$cli_bin" round run "$http_dir/workflows/http_denied_round.yaml" --format json > "$http_denied_output" 2>&1
http_denied_status=$?
set -e
if [ "$http_denied_status" -eq 0 ]; then
  printf "expected HTTP denied round to fail\n" >&2
  exit 1
fi

ROUND_OUTPUT="$http_denied_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "failed", do: raise("expected HTTP denied round failed")
unless get_in(round, ["error", "reason"]) == "network_policy_denied", do: raise("expected network_policy_denied")
shots = Map.new(round["shots"], &{&1["id"], &1})
unless get_in(shots, ["denied_get", "status"]) == "failed", do: raise("expected denied_get failed")
'
}

run_git_live_rounds() {
gitops_dir="$artifact_dir/gitops-repo"
gitops_output="$artifact_dir/gitops-round.json"
gitops_responses="$artifact_dir/gitops-mock-responses.json"
mkdir -p "$gitops_dir/manifests" "$gitops_dir/workflows/agents"
git -C "$gitops_dir" init -b main >/dev/null
git -C "$gitops_dir" config user.email "twelvgaige-live@example.invalid"
git -C "$gitops_dir" config user.name "Twelvgaige Live"

cat > "$gitops_dir/manifests/gitops-deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: twelvgaige-gitops
  namespace: $namespace
  labels:
    app: twelvgaige-gitops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: twelvgaige-gitops
  template:
    metadata:
      labels:
        app: twelvgaige-gitops
    spec:
      containers:
        - name: worker
          image: busybox:1.36
          command:
            - /bin/sh
            - -c
            - while true; do echo "twelvgaige-gitops-live"; sleep 2; done
EOF

cat > "$gitops_dir/workflows/gitops_round.yaml" <<EOF
kind: workflow
id: k3d_gitops_round
name: K3D GitOps Round
version: 1.0.0
shots:
  - id: approve_gitops
    kind: safety
    prompt: Approve Git commit and Kubernetes apply for the fixture manifest.
  - id: commit_manifest
    kind: slug
    agent: k3d_gitops_agent
    depends_on: [approve_gitops]
    tools: [git_commit]
    choke:
      max_iterations: 3
      tool_safety: destructive
    prompt: Commit the generated GitOps manifest.
  - id: apply_manifest
    kind: slug
    agent: k3d_gitops_agent
    depends_on: [approve_gitops, commit_manifest]
    tools: [kubectl_apply]
    choke:
      max_iterations: 3
      tool_safety: idempotent_write
    prompt: Apply the generated GitOps manifest.
  - id: verify_gitops
    kind: slug
    agent: k3d_gitops_agent
    depends_on: [apply_manifest]
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Verify the GitOps deployment pods.
EOF

cat > "$gitops_dir/workflows/agents/k3d_gitops_agent.yaml" <<EOF
kind: agent
id: k3d_gitops_agent
name: K3D GitOps Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Exercise Git and Kubernetes tools against the live k3d fixture.
tools:
  allowed: [git_commit, kubectl_apply, kubectl_get]
  denied: [kubectl_delete, kubectl_exec]
EOF

cat > "$gitops_responses" <<EOF
{
  "responses_by_shot": {
    "commit_manifest": [
      {
        "content": "commit manifest",
        "tool_calls": [
          {
            "name": "git_commit",
            "input": {
              "paths": ["manifests/gitops-deployment.yaml"],
              "message": "Add live gitops fixture",
              "confirm": true
            }
          }
        ]
      },
      {"content": "manifest committed", "tool_calls": []}
    ],
    "apply_manifest": [
      {
        "content": "apply manifest",
        "tool_calls": [
          {
            "name": "kubectl_apply",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "path": "manifests/gitops-deployment.yaml",
              "confirm": true
            }
          }
        ]
      },
      {"content": "manifest applied", "tool_calls": []}
    ],
    "verify_gitops": [
      {
        "content": "verify pods",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "pods",
              "selector": "app=twelvgaige-gitops",
              "limit": 3
            }
          }
        ]
      },
      {"content": "gitops verified", "tool_calls": []}
    ]
  }
}
EOF

(
  cd "$gitops_dir"
  KUBECONFIG="$writer_kubeconfig" \
    TWELVGAIGE_MOCK_RESPONSES_FILE="$gitops_responses" \
    TWELVGAIGE_STORE_SQLITE="$artifact_dir/gitops-round.sqlite3" \
    "$cli_bin" round run workflows/gitops_round.yaml --approve-safety --format json > "$gitops_output"
)
kubectl --kubeconfig "$writer_kubeconfig" --context "$writer_context" -n "$namespace" rollout status deployment/twelvgaige-gitops --timeout=90s

ROUND_OUTPUT="$gitops_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "complete", do: raise("expected GitOps round complete")

shots = Map.new(round["shots"], &{&1["id"], &1})
for id <- ["approve_gitops", "commit_manifest", "apply_manifest", "verify_gitops"] do
  unless get_in(shots, [id, "status"]) == "complete", do: raise("expected #{id} complete")
end

commit_tool = get_in(shots, ["commit_manifest", "output", "tool_calls", Access.at(0), "name"])
apply_tool = get_in(shots, ["apply_manifest", "output", "tool_calls", Access.at(0), "name"])
verify_count = get_in(shots, ["verify_gitops", "output", "tool_calls", Access.at(0), "output", "summary", "item_count"])

unless commit_tool == "git_commit", do: raise("expected git_commit call")
unless apply_tool == "kubectl_apply", do: raise("expected kubectl_apply call")
unless verify_count >= 1, do: raise("expected GitOps pod verification")
'
git -C "$gitops_dir" log --oneline -- manifests/gitops-deployment.yaml | grep -F "Add live gitops fixture" >/dev/null
if [ -n "$(git -C "$gitops_dir" status --porcelain -- manifests/gitops-deployment.yaml)" ]; then
  printf "gitops manifest was not clean after commit\n" >&2
  git -C "$gitops_dir" status --porcelain -- manifests/gitops-deployment.yaml >&2
  exit 1
fi
if git -C "$gitops_dir" ls-files --error-unmatch workflows/gitops_round.yaml >/dev/null 2>&1; then
  printf "generated workflow file was unexpectedly committed\n" >&2
  exit 1
fi

git_policy_dir="$artifact_dir/git-policy"
git_policy_output="$artifact_dir/git-policy-round.json"
git_policy_responses="$artifact_dir/git-policy-mock-responses.json"
mkdir -p "$git_policy_dir/manifests" "$git_policy_dir/workflows/agents"
git -C "$git_policy_dir" init -b main >/dev/null
git -C "$git_policy_dir" config user.email "twelvgaige-live@example.invalid"
git -C "$git_policy_dir" config user.name "Twelvgaige Live"
printf "denied\n" > "$git_policy_dir/manifests/denied.txt"

cat > "$git_policy_dir/workflows/git_policy_round.yaml" <<EOF
kind: workflow
id: k3d_git_policy_round
name: K3D Git Policy Round
version: 1.0.0
shots:
  - id: approve_git_policy
    kind: safety
    prompt: Approve the intentionally denied Git safety test.
  - id: denied_commit
    kind: slug
    agent: k3d_git_policy_agent
    depends_on: [approve_git_policy]
    tools: [git_commit]
    choke:
      max_iterations: 3
      tool_safety: idempotent_write
    prompt: Attempt a commit without destructive tool safety.
EOF

cat > "$git_policy_dir/workflows/agents/k3d_git_policy_agent.yaml" <<EOF
kind: agent
id: k3d_git_policy_agent
name: K3D Git Policy Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Exercise Git safety policy against a live local repository.
tools:
  allowed: [git_commit]
  denied: []
EOF

cat > "$git_policy_responses" <<EOF
{
  "responses_by_shot": {
    "denied_commit": [
      {
        "content": "attempt denied commit",
        "tool_calls": [
          {
            "name": "git_commit",
            "input": {
              "paths": ["manifests/denied.txt"],
              "message": "Denied live git commit",
              "confirm": true
            }
          }
        ]
      }
    ]
  }
}
EOF

(
  cd "$git_policy_dir"
  set +e
  TWELVGAIGE_MOCK_RESPONSES_FILE="$git_policy_responses" \
    TWELVGAIGE_STORE_SQLITE="$artifact_dir/git-policy.sqlite3" \
    "$cli_bin" round run workflows/git_policy_round.yaml --approve-safety --format json > "$git_policy_output" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    printf "expected git policy round to fail\n" >&2
    exit 1
  fi
)

ROUND_OUTPUT="$git_policy_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "failed", do: raise("expected Git policy round failed")
unless get_in(round, ["error", "reason"]) == "policy_denied", do: raise("expected policy_denied")
shots = Map.new(round["shots"], &{&1["id"], &1})
unless get_in(shots, ["denied_commit", "status"]) == "failed", do: raise("expected denied_commit failed")
'
if git -C "$git_policy_dir" log --oneline 2>/dev/null | grep -F "Denied live git commit" >/dev/null; then
  printf "denied git commit unexpectedly exists\n" >&2
  exit 1
fi
}

run_remediation_round() {
broken_deployment="twelvgaige-broken-rollout"
broken_selector="app=$broken_deployment"
broken_dir="$artifact_dir/broken-rollout"
broken_output="$artifact_dir/broken-rollout-round.json"
broken_responses="$artifact_dir/broken-rollout-mock-responses.json"
mkdir -p "$broken_dir/workflows/agents"

kubectl --context "$context" -n "$namespace" create deployment "$broken_deployment" \
  --image=busybox:1.36 \
  --replicas=0 \
  -- /bin/sh -c 'while true; do echo "twelvgaige-remediated-live"; sleep 2; done'

cat > "$broken_dir/workflows/broken_rollout_round.yaml" <<EOF
kind: workflow
id: k3d_broken_rollout_round
name: K3D Broken Rollout Round
version: 1.0.0
shots:
  - id: inspect_broken
    kind: slug
    agent: k3d_remediator
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Inspect the scaled-to-zero deployment.
  - id: approve_remediation
    kind: safety
    depends_on: [inspect_broken]
    prompt: Approve scaling the fixture deployment back to one replica.
  - id: scale_broken
    kind: slug
    agent: k3d_remediator
    depends_on: [approve_remediation]
    tools: [kubectl_scale]
    choke:
      max_iterations: 3
      tool_safety: idempotent_write
    prompt: Scale the fixture deployment to one replica.
  - id: verify_remediation
    kind: slug
    agent: k3d_remediator
    depends_on: [scale_broken]
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Verify the remediated deployment pod.
EOF

cat > "$broken_dir/workflows/agents/k3d_remediator.yaml" <<EOF
kind: agent
id: k3d_remediator
name: K3D Remediator
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Safely remediate only the configured k3d fixture.
tools:
  allowed: [kubectl_get, kubectl_scale]
  denied: [kubectl_delete, kubectl_exec]
EOF

cat > "$broken_responses" <<EOF
{
  "responses_by_shot": {
    "inspect_broken": [
      {
        "content": "inspect deployment",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "deployments",
              "name": "$broken_deployment",
              "limit": 1
            }
          }
        ]
      },
      {"content": "deployment is scaled to zero", "tool_calls": []}
    ],
    "scale_broken": [
      {
        "content": "scale deployment",
        "tool_calls": [
          {
            "name": "kubectl_scale",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "deployments",
              "name": "$broken_deployment",
              "replicas": 1
            }
          }
        ]
      },
      {"content": "deployment scaled", "tool_calls": []}
    ],
    "verify_remediation": [
      {
        "content": "verify pods",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "pods",
              "selector": "$broken_selector",
              "limit": 3
            }
          }
        ]
      },
      {"content": "remediation verified", "tool_calls": []}
    ]
  }
}
EOF

KUBECONFIG="$writer_kubeconfig" \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$broken_responses" \
  TWELVGAIGE_STORE_SQLITE="$artifact_dir/broken-rollout.sqlite3" \
  "$cli_bin" round run "$broken_dir/workflows/broken_rollout_round.yaml" --approve-safety --format json > "$broken_output"
kubectl --kubeconfig "$writer_kubeconfig" --context "$writer_context" -n "$namespace" rollout status "deployment/$broken_deployment" --timeout=90s

ROUND_OUTPUT="$broken_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "complete", do: raise("expected remediation round complete")
shots = Map.new(round["shots"], &{&1["id"], &1})
unless get_in(shots, ["approve_remediation", "status"]) == "complete", do: raise("expected safety approval complete")
unless get_in(shots, ["scale_broken", "output", "tool_calls", Access.at(0), "name"]) == "kubectl_scale", do: raise("expected kubectl_scale")
unless get_in(shots, ["verify_remediation", "output", "tool_calls", Access.at(0), "output", "summary", "item_count"]) >= 1, do: raise("expected remediated pod")
'
}

run_daemon_resume_round() {
daemon_dir="$artifact_dir/daemon-resume"
daemon_workflow_dir="$daemon_dir/workflows"
daemon_agent_dir="$daemon_workflow_dir/agents"
daemon_responses="$daemon_dir/mock-responses.json"
daemon_endpoint="$daemon_dir/run/breech.endpoint.json"
daemon_output="$daemon_dir/round.json"
mkdir -p "$daemon_agent_dir" "$daemon_dir/run"

cat > "$daemon_workflow_dir/restart_resume_round.yaml" <<EOF
kind: workflow
id: k3d_restart_resume_round
name: K3D Restart Resume Round
version: 1.0.0
shots:
  - id: inspect_before_restart
    kind: slug
    agent: k3d_daemon_agent
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Inspect fixture pods before daemon restart.
  - id: approve_after_restart
    kind: safety
    depends_on: [inspect_before_restart]
    prompt: Pause so the daemon can be restarted before approval.
  - id: verify_after_restart
    kind: slug
    agent: k3d_daemon_agent
    depends_on: [approve_after_restart]
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Verify fixture pods after daemon restart.
EOF

cat > "$daemon_agent_dir/k3d_daemon_agent.yaml" <<EOF
kind: agent
id: k3d_daemon_agent
name: K3D Daemon Agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Verify daemon recovery against the live k3d fixture.
tools:
  allowed: [kubectl_get]
  denied: [kubectl_delete, kubectl_exec]
EOF

cat > "$daemon_responses" <<EOF
{
  "responses_by_shot": {
    "inspect_before_restart": [
      {
        "content": "inspect before restart",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "pods",
              "selector": "$fixture_selector",
              "limit": 3
            }
          }
        ]
      },
      {"content": "pause for restart", "tool_calls": []}
    ],
    "verify_after_restart": [
      {
        "content": "verify after restart",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "pods",
              "selector": "$fixture_selector",
              "limit": 3
            }
          }
        ]
      },
      {"content": "verified after restart", "tool_calls": []}
    ]
  }
}
EOF

TWELVGAIGE_STORE_SQLITE="$daemon_dir/store.sqlite3" \
  KUBECONFIG="$writer_kubeconfig" \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$daemon_responses" \
  "$cli_bin" daemon serve --transport tcp --runtime-dir "$daemon_dir/run" --endpoint "$daemon_endpoint" --format json \
  > "$daemon_dir/daemon-1.stdout" 2> "$daemon_dir/daemon-1.stderr" &
daemon_pid=$!

i=0
while [ "$i" -lt 100 ] && [ ! -f "$daemon_endpoint" ]; do
  i=$((i + 1))
  sleep 0.1
done

TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" "$cli_bin" status --format json > "$daemon_dir/status-1.json"

TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" \
  "$cli_bin" round run "$daemon_workflow_dir/restart_resume_round.yaml" --detach --format json > "$daemon_dir/detached.json"
round_id="$(tr ',' '\n' < "$daemon_dir/detached.json" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed -n '1p')"

i=0
while [ "$i" -lt 100 ]; do
  TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" "$cli_bin" round show "$round_id" --format json > "$daemon_dir/show-before-restart.json" || true
  if grep -F '"status":"awaiting_safety"' "$daemon_dir/show-before-restart.json" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
grep -F '"status":"awaiting_safety"' "$daemon_dir/show-before-restart.json" >/dev/null

TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" "$cli_bin" daemon stop --endpoint "$daemon_endpoint" --format json > "$daemon_dir/stop-1.json" || true
i=0
while [ "$i" -lt 100 ] && kill -0 "$daemon_pid" 2>/dev/null; do
  i=$((i + 1))
  sleep 0.1
done
daemon_pid=""

TWELVGAIGE_STORE_SQLITE="$daemon_dir/store.sqlite3" \
  KUBECONFIG="$writer_kubeconfig" \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$daemon_responses" \
  "$cli_bin" daemon serve --transport tcp --runtime-dir "$daemon_dir/run" --endpoint "$daemon_endpoint" --format json \
  > "$daemon_dir/daemon-2.stdout" 2> "$daemon_dir/daemon-2.stderr" &
daemon_pid=$!

i=0
while [ "$i" -lt 100 ] && [ ! -f "$daemon_endpoint" ]; do
  i=$((i + 1))
  sleep 0.1
done

TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" \
  "$cli_bin" round approve "$round_id" --shot approve_after_restart --reason "k3d restart e2e" --format json \
  > "$daemon_dir/approve.json"

i=0
while [ "$i" -lt 100 ]; do
  TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" "$cli_bin" round show "$round_id" --format json > "$daemon_output" || true
  if grep -F '"status":"complete"' "$daemon_output" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.1
done
grep -F '"status":"complete"' "$daemon_output" >/dev/null

TWELVGAIGE_BREECH_ENDPOINT="$daemon_endpoint" "$cli_bin" daemon stop --endpoint "$daemon_endpoint" --format json > "$daemon_dir/stop-2.json" || true
daemon_pid=""

ROUND_OUTPUT="$daemon_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "complete", do: raise("expected daemon restart round complete")
shots = Map.new(round["shots"], &{&1["id"], &1})
unless get_in(shots, ["approve_after_restart", "status"]) == "complete", do: raise("expected resumed safety approval")
unless get_in(shots, ["verify_after_restart", "output", "tool_calls", Access.at(0), "name"]) == "kubectl_get", do: raise("expected post-restart kubectl_get")
'
}

run_fanout_round() {
fanout_dir="$artifact_dir/fanout"
fanout_output="$artifact_dir/fanout-round.json"
fanout_responses="$artifact_dir/fanout-mock-responses.json"
mkdir -p "$fanout_dir/workflows/agents"

cat > "$fanout_dir/workflows/fanout_round.yaml" <<EOF
kind: workflow
id: k3d_parallel_fanout_round
name: K3D Parallel Fanout Round
version: 1.0.0
shots:
  - id: inspect_pods
    kind: slug
    agent: k3d_pod_inspector
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Inspect fixture pods.
  - id: inspect_deployments
    kind: slug
    agent: k3d_deployment_inspector
    tools: [kubectl_get]
    choke:
      max_iterations: 3
    prompt: Inspect fixture deployments.
  - id: inspect_events
    kind: slug
    agent: k3d_event_inspector
    tools: [kubectl_events]
    choke:
      max_iterations: 3
    prompt: Inspect namespace events.
  - id: synthesize_incident
    kind: slug
    agent: k3d_analyst
    depends_on: [inspect_pods, inspect_deployments, inspect_events]
    prompt: Synthesize the fanout inspection outputs.
EOF

for agent in k3d_pod_inspector k3d_deployment_inspector k3d_event_inspector k3d_analyst; do
  cat > "$fanout_dir/workflows/agents/$agent.yaml" <<EOF
kind: agent
id: $agent
name: $agent
version: 1.0.0
provider: mock
model: mock-model
system_prompt: Participate in a deterministic fanout/fan-in k3d workflow.
tools:
  allowed: [kubectl_get, kubectl_events]
  denied: [kubectl_delete, kubectl_exec]
EOF
done

cat > "$fanout_responses" <<EOF
{
  "responses_by_shot": {
    "inspect_pods": [
      {
        "content": "inspect pods",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "pods",
              "selector": "$fixture_selector",
              "limit": 3
            }
          }
        ]
      },
      {"content": "pods inspected", "tool_calls": []}
    ],
    "inspect_deployments": [
      {
        "content": "inspect deployments",
        "tool_calls": [
          {
            "name": "kubectl_get",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "resource": "deployments",
              "name": "$fixture_deployment",
              "limit": 1
            }
          }
        ]
      },
      {"content": "deployments inspected", "tool_calls": []}
    ],
    "inspect_events": [
      {
        "content": "inspect events",
        "tool_calls": [
          {
            "name": "kubectl_events",
            "input": {
              "context": "$writer_context",
              "namespace": "$namespace",
              "limit": 5
            }
          }
        ]
      },
      {"content": "events inspected", "tool_calls": []}
    ],
    "synthesize_incident": [
      {"content": "fanout synthesis complete", "tool_calls": []}
    ]
  }
}
EOF

KUBECONFIG="$writer_kubeconfig" \
  TWELVGAIGE_MOCK_RESPONSES_FILE="$fanout_responses" \
  TWELVGAIGE_STORE_SQLITE="$artifact_dir/fanout.sqlite3" \
  "$cli_bin" round run "$fanout_dir/workflows/fanout_round.yaml" --format json > "$fanout_output"

ROUND_OUTPUT="$fanout_output" MIX_ENV=test mix run -e '
round = System.fetch_env!("ROUND_OUTPUT") |> File.read!() |> Jason.decode!()
unless round["status"] == "complete", do: raise("expected fanout round complete")
shots = Map.new(round["shots"], &{&1["id"], &1})
for id <- ["inspect_pods", "inspect_deployments", "inspect_events", "synthesize_incident"] do
  unless get_in(shots, [id, "status"]) == "complete", do: raise("expected #{id} complete")
end
unless get_in(shots, ["inspect_pods", "output", "tool_calls", Access.at(0), "name"]) == "kubectl_get", do: raise("expected pod inspector tool")
unless get_in(shots, ["inspect_deployments", "output", "tool_calls", Access.at(0), "name"]) == "kubectl_get", do: raise("expected deployment inspector tool")
unless get_in(shots, ["inspect_events", "output", "tool_calls", Access.at(0), "name"]) == "kubectl_events", do: raise("expected event inspector tool")
'
}

main() {
  log_step "bootstrap k3d cluster"
  bootstrap_cluster
  log_step "kubernetes tool tests"
  run_kubernetes_tool_tests
  log_step "basic cli round"
  run_basic_cli_round
  log_step "http live rounds"
  run_http_live_rounds
  log_step "git live rounds"
  run_git_live_rounds
  log_step "guarded remediation round"
  run_remediation_round
  log_step "daemon restart/resume round"
  run_daemon_resume_round
  log_step "fanout/fan-in round"
  run_fanout_round

  printf "status=passed\n" >> "$artifact_dir/summary.env"
  printf "k3d live e2e passed for cluster %s\n" "$cluster"
}

main
