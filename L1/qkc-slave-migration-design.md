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
- RpcConn (basic connection framework)
- MasterConn (Master-Slave communication)
- XshardConn (Slave-Slave communication)
- PeerConn (Peer virtual connection)
- Dispatcher (message routing)
- Slave Runtime (lifecycle management)
- Handler Registration (registration mechanism)
- Handler Dispatch (dispatch scheduling)

This phase does not implement business logic, such as:

- Shard Runtime
- StateDB
- TxPool
- Miner
- State Transition

## 3. Current Status

| PR  | Content                                              | Status      |
|-----|------------------------------------------------------|-------------|
| PR1 | Wire Frame encoding/decoding                         | ✅ Completed |
| PR2 | Metadata and Opcode definitions                      | ✅ Completed |
| PR3 | Message definitions and protocol constants           | Review      |
| PR4 | RpcConn + XshardConn foundation                      | Review      |
| PR5 | MasterConn, handler registration                     | Review      |
| PR6 | PeerConn, Dispatcher, and peer routing               | Planned     |
| PR7 | Slave communication runtime and lifecycle management | Planned     |

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
            │                                │── lookup MASTER_OP_RPC_MAP
            │                                │── dispatch handler
            │◄──[TCP Frame]──────────────────│── return response
            │  12B ClusterMetadata +         │
            │  op + rpc_id + payload         │
```

### 4.2 Peer Virtual Connection Forwarding

```
    External P2P Peer       Master           Slave (MasterConn)
            │                    │                        │
            │──[P2P Frame]─────►│                        │
            │                    │── convert to ClusterMetadata
            │                    │──[Cluster Frame]─────►│
            │                    │                        │── cluster_peer_id ≠ 0
            │                    │                        │── route to PeerConn
            │                    │◄──[Cluster Frame]─────│── return response
            │◄──[P2P Frame]─────│                        │
```

### 4.3 Slave → Slave RPC

```
        Slave A (XshardConn)          Slave B (XshardConn)
            │                                │
            │──[TCP Frame]──────────────────►│
            │  0B Metadata +                 │
            │  op + rpc_id + payload         │
            │                                │── lookup XSHARD_OP_RPC_MAP
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
PR4 (RpcConn / XshardConn)
↓
PR5 (MasterConn)
↓
PR6 (PeerConn / Dispatcher)
↓
PR7 (Slave Runtime)
```

### PR4: RpcConn + XshardConn

Corresponding Python components: `Connection`, `SlaveConnection`

Main contents:

- RpcConn: connection framework (TCP read/write loops, RPC ID management, request/response matching)
- XshardConn: Slave-to-Slave communication
- Xshard handler registration and Ping/Pong handshake

### PR5: MasterConn

Corresponds to Python: `MasterConnection`

Main contents:

- Master-Slave communication
- MasterConn serves as the transport channel for forwarded peer traffic
- Master Handler registration and dispatch framework
- Stub implementations for Handlers depending on business components

### PR6: PeerConn + Dispatcher

Corresponds to Python: `PeerShardConnection`, `VirtualConnection`

Main contents:

- PeerConn: virtual connection for forwarded external peer traffic.
- PeerConn does not own a TCP socket and uses MasterConn as its transport.
- PeerConn is an independent RPC channel with its own RPC ID namespace.
- PeerConn lifecycle is controlled by Master commands.
- Dispatcher: routes frames to the correct PeerConn based on `cluster_peer_id` (`cluster_peer_id == 0` routes to
  MasterConn itself)
- Peer Handler registration and dispatch framework
- Stub implementations for Handlers depending on business components

### PR7: Slave Communication Runtime

Corresponds to Python: `SlaveServer`

Main contents:

- Slave communication service lifecycle management
- TCP listener for cluster connections
- Unified connection management (MasterConn / PeerConn / XshardConn)
- Dispatcher orchestration
- Wiring of communication components

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

- PR1–PR6: Use Python-generated test vectors and lightweight Python protocol peers to validate serialization, RPC flows,
  and connection lifecycles. These protocol peers are used solely for protocol compatibility testing and do not require
  a full Python Master or business components.
- PR7: Run end-to-end interoperability tests using a real Python Master and the Go Slave implementation.

Testing focuses on:

- Frame and Metadata compatibility
- Message serialization compatibility
- RPC request/response flow
- Master-Slave communication
- Slave-Slave communication
- Peer communication

## 8. Expected Result

After completing PR1-PR7:

- Complete the migration of the Slave communication framework
- Master-Slave, Slave-Slave, and Peer virtual connections are all ready
- All RPC Opcodes have completed registration and dispatch
- Business Handlers provide compatible Stub implementations

This phase only completes the communication layer infrastructure. Business logic will be implemented in later phases.