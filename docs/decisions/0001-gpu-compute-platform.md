# ADR 0001 — GPU compute platform for the inference layer

**Status:** Open — decide before Phase 1 implementation of `terraform/modules/inference`
**Deciders:** AI & Innovation (platform), with ops input

## Context

The inference layer (vLLM nodes) needs a compute platform. The gateway already
runs on ECS Fargate; GPU nodes have different needs: device plugins, weight
warm-up, queue-depth/TTFT-driven autoscaling, possible Spot usage on the batch
tier (architecture.md §4.3, §8).

## Options

1. **EKS + Karpenter** — doc's stated preference. NVIDIA device plugin,
   manifest-driven deploys map naturally, Karpenter handles heterogeneous GPU
   pools well. Cost: Kubernetes operational overhead on a small team.
2. **ECS + ASG** — lower ops burden, NVIDIA AMI, simpler mental model.
   Weaker autoscaling ergonomics for mixed instance types and warm pools.

## Decision

_Pending._ Inputs required before deciding:

- Phase 1 go/no-go break-even calc from Phase 0 gateway telemetry (§11).
- Team operational preference (architecture.md §12, open question 2).
- Bedrock checkpoint result (§4.3) — if the first workloads land on Bedrock,
  this decision defers further.

## Consequences

`terraform/modules/inference` stays a placeholder exposing the contract in its
README until this ADR is accepted.
