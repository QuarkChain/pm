# QuarkChain Slave Migration Design Document

## 1. Migration Goal

Migrate the Slave component in QuarkChain cluster communication from Python to Go while maintaining byte-level protocol
compatibility with the Python Master.

The Python implementation remains the sole protocol specification.

The goal of this phase is to complete the migration of the communication infrastructure while keeping the existing
Python Master unchanged, providing a foundation for future business logic migration.

## 2. Scope

This phase implements:

- Frame encoding and decoding
- Metadata / Opcode / Message definitions
- baseConn (basic connection framework)
- MasterConn (Master-Slave communication)
- XshardConn (Slave-Slave communication)
- XshardPool (Slave-Slave connection pool)
- PeerConn (Peer virtual connection)
- Dispatcher (message routing)
- SlaveComm Runtime (lifecycle management)
- Handler Registration and Dispatch

This phase does not implement business logic, such as:

- Shard Runtime
- StateDB
- TxPool
- Miner
- State Transition

## 3. Current Status

| PR  | Content                                    |
|-----|--------------------------------------------|
| PR1 | Wire Frame encoding/decoding               |
| PR2 | Metadata and Opcode definitions            |
| PR3 | Message definitions and protocol constants |
| PR4 | baseConn + XshardConn + XshardPool         |
| PR5 | MasterConn, handler registration/dispatch  |
| PR6 | PeerConn, Dispatcher, peer routing         |
| PR7 | SlaveComm Runtime, interop testing         |

## 4. Communication Flow

QuarkChain cluster communication consists of three communication paths:

- Master ↔ Slave
- Peer ↔ Slave (forwarded through Master)
- Slave ↔ Slave

### 4.1 Master → Slave RPC

```
        Master                        Slave (MasterConn)
            │                                │
            │──[TCP Frame]──────────────────►│
            │  12B ClusterMetadata +         │
            │  op + rpc_id + payload         │
            │                                │── cluster_peer_id == 0
            │                                │── lookup handler
            │                                │── dispatch handler
            │◄──[TCP Frame]──────────────────│── return response
            │  12B ClusterMetadata +         │
            │  op + rpc_id + payload         │
```

### 4.2 Peer Virtual Connection Forwarding

**External view (Master ↔ External Peer):**

```
    External P2P Peer       Master           Slave (MasterConn)
            │                    │                        │
            │──[P2P Frame]─────► │                        │
            │                    │── convert to ClusterMetadata
            │                    │──[Cluster Frame]─────► │
            │                    │                        │── cluster_peer_id ≠ 0
            │                    │                        │── Dispatcher.RouteFrame
            │                    │                        │── enqueue to PeerConn
            │                    │◄──[Cluster Frame]───── │── PeerConn writeFrame
            │◄──[P2P Frame]───── │── via MasterConn        │
```

**Internal view (PeerConn virtual transport):**

```
   MasterConn (readLoop)               Dispatcher              PeerConn (readLoop)
          │                                │                          │
          │── frame with cluster_peer_id≠0 │                          │
          │── forwarder(frame) ───────────►│                          │
          │                                │── RouteFrame             │
          │                                │── lookup peer by         │
          │                                │   (cluster_peer_id,      │
          │                                │    branch)               │
          │                                │── vt.receive(frame) ────►│
          │                                │                          │── readFrame() from
          │                                │                          │   vt.inbound chan
          │                                │                          │── dispatch handler
          │                                │                          │── handler returns resp
          │                                │◄── vt.writeFrame(resp) ──│
          │◄── MasterConn.ForwardFrame ────│                          │
          │── write to TCP                 │                          │
```

PeerConn does not own a TCP socket. Instead:

- **Inbound**: MasterConn's readLoop calls `forwarder(frame)` → `Dispatcher.RouteFrame` → `vt.receive(frame)` enqueues
  into `vt.inbound` channel → PeerConn's readLoop reads from the channel
- **Outbound**: PeerConn's handler returns a response → `vt.writeFrame(resp)` sets `ClusterMetadata` and calls
  `MasterConn.ForwardFrame` → MasterConn writes to TCP

### 4.3 Slave → Slave RPC

```
        Slave A (XshardConn)          Slave B (XshardConn)
            │                                │
            │──[TCP Frame]──────────────────►│
            │  0B Metadata +                 │
            │  op + rpc_id + payload         │
            │                                │── lookup handler
            │                                │── dispatch handler
            │◄──[TCP Frame]──────────────────│── return response
            │  0B Metadata +                 │
            │  op + rpc_id + payload         │
```

### 4.4 Connection Model Rules

**Connection Identity**

| Connection Type | Description                                                                             |
|-----------------|-----------------------------------------------------------------------------------------|
| MasterConn      | Connection used for Master-Slave communication                                          |
| XshardConn      | Connection used for Slave-Slave communication                                           |
| PeerConn        | Virtual connection representing forwarded peer traffic, identified by `cluster_peer_id` |

**RPC Isolation**

- Each logical connection is an independent RPC channel.
- RPC IDs are scoped per connection and are not required to be globally unique.
- Multiple PeerConn instances sharing the same MasterConn transport may use overlapping RPC IDs.

**Lifecycle**

- PeerConn lifecycle is driven by Master commands, never autonomously by the Slave
- Closing MasterConn closes all associated PeerConn instances.

**Message Routing**

MasterConn routes frames based on `cluster_peer_id`:

- `cluster_peer_id == 0`: Master RPC, handled locally by MasterConn
- `cluster_peer_id != 0`: Peer RPC, forwarded by the Dispatcher to the corresponding PeerConn

## 5. Migration Plan

```
PR1-PR3 (Protocol foundation layer)
↓
PR4 (baseConn / XshardConn / XshardPool)
↓
PR5 (MasterConn)
↓
PR6 (PeerConn / Dispatcher)
↓
PR7 (SlaveComm Runtime + interop testing)
```

### PR4: baseConn + XshardConn + XshardPool

Corresponding Python components: `Connection`, `SlaveConnection`, `SlaveConnectionManager`

Main contents:

- **baseConn**: shared RPC connection framework (lifecycle management, RPC ID tracking and monotonic validation,
  request/response matching, typed handler dispatch, OpSerializer registration, connection close propagation)
- **XshardConn**: Slave-to-Slave communication (0-byte metadata, PING/PONG identity exchange, shard list validation,
  stub handlers for ADD_XSHARD_TX_LIST and BATCH_ADD_XSHARD_TX_LIST)
- **XshardPool**: shard-indexed connection pool (Add/Get/Remove, slave ID deduplication, inbound/outbound tracking,
  VerifyAndAdd with PING verification, broadcast send)

Testing: unit tests only (`xshard_test.go`), validating Go-side connection behavior (RPC ID validation, pending RPC
lifecycle, connection close semantics, pool lifecycle).

### PR5: MasterConn

Corresponds to Python: `MasterConnection`

Main contents:

- Master-Slave communication (12-byte ClusterMetadata)
- MasterConn serves as the transport channel for forwarded peer traffic via `forwarder` callback
- Master Handler registration and dispatch framework
- Stub implementations for Handlers depending on business components

### PR6: PeerConn + Dispatcher

Corresponds to Python: `PeerShardConnection`, `VirtualConnection`

Main contents:

- **PeerConn**: virtual connection for forwarded external peer traffic. Does not own a TCP socket; uses
  `virtualTransport` (inbound channel + outbound forwarding through MasterConn) as its transport. Independent RPC ID
  namespace. Lifecycle controlled by Master commands.
- **Dispatcher**: routes frames to the correct PeerConn based on `cluster_peer_id` and `branch` (`cluster_peer_id == 0`
  stays with MasterConn). Two-layer map: `cluster_peer_id → branch → *PeerConn`. Manages `CreatePeerConns` and
  `DestroyPeerConns`.
- Peer Handler registration and dispatch framework
- Stub implementations for Handlers depending on business components

### PR7: SlaveComm Runtime + Interop Testing

Corresponds to Python: `SlaveServer`

Main contents:

- **SlaveComm**: runtime orchestration layer (TCP listener, accept loop with first-connection-as-MasterConn semantics,
  XshardConn lifecycle management, CONNECT_TO_SLAVES_REQUEST handler, unified Start/Stop)
- Wiring of all communication components: MasterConn, XshardPool, Dispatcher, PeerConns
- **Interop testing**: end-to-end tests using a real Python Master (`pyquarkchain`) and Go Slaves
    - `TestRealMasterBootstrap`: verifies Master↔Slave PING/PONG, slave-to-slave xshard connections via
      CONNECT_TO_SLAVES_REQUEST
    - `TestRealMasterPeerLifecycle`: verifies external peer connect → CREATE_CLUSTER_PEER_CONNECTION_REQUEST →
      Dispatcher.peers populated → peer disconnect → DESTROY_CLUSTER_PEER_CONNECTION_COMMAND → Dispatcher.peers cleaned
      up

## 6. Handler Implementation Strategy

Handlers are categorized by connection type:

- Xshard Handler → XshardConn
- Master Handler → MasterConn
- Peer Handler → PeerConn

This phase completes:

- Handler registration (Registration)
- Handler dispatch (Dispatch)
- RPC request/response flow

For Handlers depending on other components, such as:

- Shard Runtime
- StateDB
- TxPool
- Miner

Only Stub implementations are provided, without implementing actual business logic.

The goal of the Stubs is to ensure:

- Opcode can be recognized
- Messages can be parsed
- Handlers can be correctly dispatched
- RPC request/response flow is complete
- Protocol-compatible placeholder responses are returned

## 7. Testing

The Python implementation is the protocol authority.

Testing is performed in two stages:

- **PR1–PR6**: Unit tests validate Go-side communication components, including RPC
  lifecycle, connection handling, handler dispatch, pool lifecycle, and virtual
  transport routing. Protocol behavior is implemented according to the Python
  reference implementation.
- **PR7**: End-to-end interoperability tests using a real Python Master
  (`pyquarkchain`) and Go Slave processes. Tests validate the complete
  communication lifecycle: bootstrap handshake, slave-to-slave connection
  establishment, and peer connection create/destroy lifecycle through Dispatcher.

Testing focuses on:

- Frame and Metadata compatibility
- Message serialization compatibility
- RPC request/response flow
- Master-Slave communication
- Slave-Slave communication
- Peer virtual connection forwarding

## 8. Expected Result

After completing PR1-PR7:

- Complete the migration of the Slave communication framework
- Master-Slave, Slave-Slave, and Peer virtual connections are all ready
- All RPC Opcodes have completed registration and dispatch
- Business Handlers provide compatible Stub implementations
- End-to-end interoperability with real Python Master validated

This phase only completes the communication layer infrastructure. Business logic will be implemented in later phases.

---