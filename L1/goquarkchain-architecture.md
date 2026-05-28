# GoQuarkChain 架构图

## 项目概览

GoQuarkChain 是 QuarkChain 分片区块链协议的 Go 语言实现。QuarkChain 采用两层架构：
- **Root Chain（根链层）**: 保护网络安全、协调跨分片交易
- **Shard Layer（分片层）**: 多个分片链并行处理交易，容量随分片数量线性扩展

## 顶层架构

```mermaid
graph TB
    subgraph "External Clients"
        A[Metamask / quarkchain-web3.js]
        B[External Mining Pool]
        C[Load Test Tool]
        D[Stats Monitor]
    end

    subgraph "JSON RPC Layer"
        E[Public HTTP RPC<br/>Port 38391]
        F[Private HTTP RPC<br/>Port 38491]
        G[WebSocket RPC]
        H[gRPC Server]
        I[In-Process RPC]
    end

    subgraph "Node Service Layer<br/>cluster/service/"
        J[Node<br/>Container for Services]
        K[ServiceContext<br/>Service Constructor]
        L[P2P Server<br/>gossip protocol]
    end

    subgraph "Master Service<br/>cluster/master/"
        M[QKCMasterBackend<br/>Core Master Logic]
        N[ProtocolManager<br/>P2P Protocol Handler]
        O[MasterMiner<br/>Root Chain Miner]
        P[PeerSet & Peer<br/>P2P Peer Management]
        Q[Synchronizer<br/>Root Chain Sync]
        R[RootBlockChain<br/>Root Chain State]
    end

    subgraph "Shard Services<br/>cluster/slave/"
        S[SlaveBackend<br/>Shard Coordinator]
        T[ShardState<br/>Shard State & Execution]
        U[ShardMiner<br/>Minor Block Miner]
        V[Shard Sync<br/>Minor Block Sync]
        W[Filter System<br/>Event Subscription]
        X[ConnManager<br/>Slave-to-Slave]
    end

    subgraph "Shared Modules"
        Y[account/<br/>Address/Identity/Branch]
        Z[core/types<br/>Block/Transaction Types]
        AA[core/evm<br/>Ethereum EVM]
        AB[p2p/<br/>P2P Protocol]
        AC[rpc/<br/>JSON-RPC + gRPC]
        AD[cluster/config<br/>Cluster Configuration]
        AE[serialize/<br/>Message Serialization]
        AF[qkcdb/<br/>Database Layer]
        AG[consensus/<br/>PoW / QKCHASH / PoSW]
      AH[cluster/rpc<br/>gRPC Interface Definitions]
    end

    A --> E
    B --> F
    C --> E
    D --> F

    E --> J
    F --> J
    G --> J
    H --> J
    I --> J

    J --> K
    J --> L

    K --> M
    K --> S

    M --> N
    M --> O
    M --> R
    N --> P
    N --> Q
    N --> R

    S --> T
    S --> U
    S --> V
    S --> W
    S --> X

    N --> AB
    M --> AE
    M --> AD
    S --> AD
    T --> AA
    U --> AG
    Q --> AG
    O --> AG
    T --> Y
    R --> Y
    N --> AE
    S --> AC
    M --> AH
    T --> AF
    R --> AF
    X --> AB
```

## 模块依赖图

```mermaid
graph LR
    subgraph "Entry Points"
        E1[cmd/cluster/main.go<br/>Cluster CLI]
        E2[cmd/eth_api/main.go<br/>Metamask API]
        E3[cmd/miner/main.go<br/>External Miner]
        E4[cmd/stats/stats.go<br/>Monitoring]
    end

    subgraph "Service Layer"
        SL1[service/Node<br/>Node Container]
        SL2[service/Service<br/>Service Interface]
        SL3[service/Config<br/>Node Configuration]
    end

    subgraph "Master Package"
        MA1[master/QKCMasterBackend<br/>Core Logic]
        MA2[master/ProtocolManager<br/>P2P Protocol]
        MA3[master/Peer<br/>Peer Connection]
        MA4[master/Miner<br/>Root Miner]
        MA5[master/master_grpc.go<br/>gRPC Server Side]
        MA6[master/api_backend.go<br/>API Implementations]
    end

    subgraph "Shard Package"
        SH1[slave/SlaveBackend<br/>Shard Coordinator]
        SH2[slave/api.go<br/>PublicFilterAPI / eth_*]
        SH3[slave/backend.go<br/>Transaction Execution]
        SH4[slave/filters/<br/>Event System]
    end

    subgraph "Shard Package"
        SD1[shard/interface.go<br/>ConnManager Interface]
        SD2[shard/tx_generator.go<br/>Test Tx Generator]
    end

    subgraph "Shared Libraries"
        LIB1[account/<br/>Address, Identity, Branch]
        LIB2[core/types/<br/>RootBlock, MinorBlock, Tx]
        LIB3[core/evm<br/>EVM Execution]
        LIB4[p2p/<br/>Protocol, Discovery]
        LIB5[cluster/rpc/<br/>gRPC Protos]
        LIB6[cluster/config/<br/>ClusterConfig]
        LIB7[cluster/service/<br/>Node, Service]
        LIB8[serialize/<br/>Serialization]
        LIB9[consensus/<br/>PoW Engines]
        LIB10[qkcdb/<br/>Database]
        LIB11[common/<br/>Utilities]
        LIB12[rpc/<br/>JSON-RPC Server]
    end

    E1 --> SL1
    E2 --> SL1
    E3 --> MA4

    SL1 --> SL2
    SL1 --> SL3

    SL2 --> MA1
    SL2 --> SH1

    MA1 --> MA2
    MA1 --> MA3
    MA1 --> MA4
    MA1 --> MA5
    MA1 --> MA6

    SH1 --> SH2
    SH1 --> SH3
    SH1 --> SH4

    MA1 --> LIB1
    MA1 --> LIB2
    MA1 --> LIB3
    MA1 --> LIB4
    MA1 --> LIB5
    MA1 --> LIB6
    MA1 --> LIB8
    MA1 --> LIB9
    MA1 --> LIB10
    MA1 --> LIB12

    SH1 --> LIB1
    SH1 --> LIB2
    SH1 --> LIB3
    SH1 --> LIB4
    SH1 --> LIB5
    SH1 --> LIB6
    SH1 --> LIB8
    SH1 --> LIB9
    SH1 --> LIB10
    SH1 --> LIB11
    SH1 --> LIB12

    SD1 --> LIB2
```

## 数据流图

```mermaid
graph TB
    subgraph "Transaction Flow"
        T1[Client sends<br/>Raw Transaction]
        T2[Public HTTP RPC<br/>eth_sendRawTransaction]
        T3[QKCMasterBackend<br/>AddTransaction]
        T4[Resolve shard by<br/>FromChainID → FullShardId]
        T5[SlaveConn<br/>AddTransaction via gRPC]
        T6[ShardState<br/>add_tx → EVM execution]
        T7[Broadcast to P2P peers]
    end

    subgraph "Mining Flow"
        M1[B miner calls<br/>getWork]
        M2[QKCMasterBackend<br/>GetWork → dispatch to root/miner]
        M3[RootMiner creates<br/>RootBlock candidate]
        M4[Slave queries unconfirmed<br/>minor block headers]
        M5[RootBlock assembled with<br/>minor block headers]
        M6[Miner finds valid nonce]
        M7[SubmitWork → add_root_block]
        M8[RootBlock added to<br/>RootBlockChain]
        M9[Broadcast to peers & slaves]
    end

    subgraph "Block Production Flow"
        B1[ShardMiner calls<br/>createBlockToMine]
        B2[ShardState assembles<br/>MinorBlock from tx pool]
        B3[Miner finds valid PoW]
        B4[handle_new_block → validate]
        B5[add_block → execute txs]
        B6[Broadcast to shard peers]
        B7[send_minor_block_header_to_master]
        B8[broadcast_xshard_tx_list<br/>for cross-shard txs]
    end

    T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7
    M1 --> M2 --> M3 --> M4 --> M5 --> M6 --> M7 --> M8 --> M9
    B1 --> B2 --> B3 --> B4 --> B5 --> B6 --> B7 --> B8
```

## 进程模型

```mermaid
graph TB
    subgraph "Master Process"
        P1[Master Server<br/>QKCMasterBackend]
        P2[P2P Server<br/>gossip protocol]
        P3[Public JSON RPC<br/>:38391]
        P4[Private JSON RPC<br/>:38491]
        P5[gRPC Server<br/>inter-process]
    end

    subgraph "Slave Process N (Shard N)"
        S1[SlaveBackend<br/>Shard Coordinator]
        S2[ShardState<br/>State + EVM]
        S3[ShardMiner<br/>PoW Mining]
        S4[WebSocket RPC<br/>:3859x]
        S5[P2P Peer Connection<br/>to other shards]
    end

    subgraph "Communication"
        C1[Master ↔ Slave:<br/>gRPC / TCP]
        C2[Slave ↔ Slave:<br/>P2P Protocol]
        C3[Master ↔ Master:<br/>P2P Protocol]
        C4[Client → Master:<br/>HTTP JSON-RPC]
    end

    P1 --> C1 --> S1
    P2 --> C3
    P3 --> C4
    P4 --> C4
    P5 --> C1
    S2 --> S3
    S4 --> C4
    S5 --> C2
```

## 关键组件说明

| 组件 | 包路径 | 职责 |
|------|--------|------|
| **Node** | `cluster/service/node.go` | 节点容器，管理所有服务的生命周期（类似 go-ethereum 的 Node） |
| **Service** | `cluster/service/service.go` | 服务接口，定义 Protocols/ APIs/ Start/Stop |
| **QKCMasterBackend** | `cluster/master/handle.go` | 主节点核心逻辑：交易分发、块同步、RPC 实现 |
| **ProtocolManager** | `cluster/master/handle.go` | P2P 协议管理器，处理 peer 连接、消息分发、根链同步 |
| **MasterMiner** | `cluster/master/miner.go` | 根链矿工，创建和挖掘 RootBlock |
| **SlaveBackend** | `cluster/slave/api.go` | 分片节点协调器，处理所有 shard RPC 请求 |
| **PublicFilterAPI** | `cluster/slave/api.go` | 提供 eth_* JSON-RPC 接口（兼容以太坊） |
| **ShardState** | `cluster/slave/backend.go` | 分片状态管理、交易执行、块构建 |
| **ShardMiner** | `cluster/slave/miner.go` | 分片矿工，挖掘 MinorBlock |
| **RootBlockChain** | `core/` | 根链状态和持久化 |
| **ConnManager** | `cluster/shard/interface.go` | 分片间通信管理器（跨分片交易广播等） |
