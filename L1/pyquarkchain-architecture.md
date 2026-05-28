# PyQuarkChain 架构图

## 项目概览

PyQuarkChain 是 QuarkChain 分片区块链协议的 Python 参考实现。它是 QuarkChain 协议设计的原始参考，
GitHub Wiki 上的协议设计文档均基于 Python 实现。GoQuarkChain 是其性能优化版本。

## 顶层架构

```mermaid
graph TB
    subgraph "External Clients"
        A[JSON-RPC Clients<br/>quarkchain-web3.js]
        B[External Miners<br/>cmd/miner/main.py]
        C[Load Test Tool]
    end

    subgraph "JSON-RPC Layer"
        D[Public JSON-RPC HTTP Server]
        E[Private JSON-RPC HTTP Server]
    end

    subgraph "Cluster Orchestration<br/>cluster/cluster.py"
        F[Cluster Class<br/>Process Manager]
        G[run_master / run_slaves<br/>Async Process Spawner]
    end

    subgraph "Master Process<br/>cluster/master.py"
        H[MasterServer<br/>Core Master Logic]
        I[ProtocolManager / P2P<br/>P2P Connection Manager]
        J[Synchronizer<br/>Root Chain Sync]
        K[SyncTask<br/>Individual Sync Task]
        L[RootMiner<br/>Root Chain Miner]
        M[RootState<br/>Root Chain State]
    end

    subgraph "Slave/Shard Process<br/>cluster/shard.py"
        N[Shard<br/>Shard Coordinator]
        O[ShardState<br/>Shard State & Execution]
        P[ShardMiner<br/>Minor Block Miner]
        Q[PeerShardConnection<br/>P2P to other shards]
        R[Synchronizer<br/>Minor Block Sync]
        S[SyncTask<br/>Individual Sync Task]
    end

    subgraph "Network Layer"
        T[P2PManager<br/>Full P2P Protocol]
        U[SimpleNetwork<br/>Simplified Network]
    end

    subgraph "Protocol & Communication"
        V[protocol.py<br/>ClusterConnection<br/>P2PConnection<br/>Message Protocol]
        W[rpc.py<br/>RPC Request/Response Types]
        X[p2p_commands.py<br/>P2P Command Ops]
    end

    subgraph "Shared Core"
        Y[core.py<br/>Block/Tx/Address Types]
        Z[config.py<br/>QuarkChainConfig<br/>ShardConfig<br/>RootConfig]
        AA[env.py<br/>Environment Context]
        BB[db.py<br/>PersistentDb / InMemoryDb]
        CC[evm/<br/>EVM State/VM/Transactions]
        DD[accounts.py<br/>Account Management]
        EE[consensus/<br/>ethash / qkchash / pow]
        FF[genesis.py<br/>Genesis Configuration]
        GG[posw.py<br/>Proof-of-Staked-Work]
        HH[guardian.py<br/>Guardian Mechanism]
    end

    A --> D
    B --> E
    C --> D

    D --> F
    E --> F

    F --> G
    G --> H

    H --> I
    H --> J
    H --> L
    H --> M
    H --> T
    H --> U
    H --> V
    H --> W

    T --> X
    U --> V

    I --> X
    L --> CC
    L --> DD
    J --> M

    G --> N

    N --> O
    N --> P
    N --> Q
    N --> R
    N --> V
    N --> W

    O --> CC
    O --> DD
    O --> BB
    P --> EE
    Q --> X
    R --> S
    S --> O
```

## 核心类关系图

```mermaid
classDiagram
    class Cluster {
        +config ClusterConfig
        +async run_master()
        +async run_slaves()
        +async run()
        +shutdown()
    }

    class MasterServer {
        +root_state RootState
        +synchronizer Synchronizer
        +root_miner Miner
        +network P2PManager/SimpleNetwork
        +branch_to_slaves Dict~int, SlaveConnection~
        +async start_mining()
        +async add_transaction()
        +async add_root_block()
        +async get_work()
        +async submit_work()
        +async get_stats()
    }

    class SlaveConnection {
        +master_server MasterServer
        +id int
        +full_shard_id_list List~int~
        +async add_transaction()
        +async get_minor_block_by_hash()
        +async get_work()
        +async submit_work()
        +handle_add_minor_block_header()
    }

    class Shard {
        +full_shard_id int
        +state ShardState
        +miner Miner
        +synchronizer Synchronizer
        +peers Dict~cluster_peer_id, PeerShardConnection~
        +add_peer()
        +handle_new_block()
        +add_block()
        +add_tx()
        +broadcast_new_tip()
    }

    class ShardState {
        +branch Branch
        +header_tip MinorBlockHeader
        +root_tip RootBlockHeader
        +db PersistentDb
        +new_block_header_pool
        +add_block()
        +add_tx()
        +create_block_to_mine()
        +validate_block()
        +init_genesis_state()
    }

    class PeerShardConnection {
        +cluster_peer_id
        +shard_state ShardState
        +send_new_block()
        +broadcast_new_tip()
        +broadcast_tx_list()
        +handle_new_block_minor()
        +handle_new_transaction_list()
    }

    class RootState {
        +tip RootBlockHeader
        +db PersistentDb
        +committing_block_hash
        +add_block()
        +get_root_block_by_height()
        +create_block_to_mine()
    }

    class Synchronizer {
        +tasks Dict~peer, header~
        +running bool
        +add_task()
        +async __run()
        +_pop_best_task()
    }

    class SyncTask {
        +header RootBlockHeader
        +peer P2P peer
        +root_state RootState
        +async sync()
        +__find_ancestor()
        +__run_sync()
    }

    Cluster --> MasterServer : spawns
    Cluster --> Shard : spawns
    MasterServer --> RootState : manages
    MasterServer --> Synchronizer : owns
    MasterServer --> SlaveConnection : connects to
    SlaveConnection --> MasterServer : references
    Shard --> ShardState : owns
    Shard --> Synchronizer : owns (shard level)
    Shard --> PeerShardConnection : manages peers
    PeerShardConnection --> ShardState : reads
    Synchronizer --> SyncTask : creates
    RootState --> PersistentDb : uses
    ShardState --> PersistentDb : uses
```

## 模块文件组织

```mermaid
graph LR
    subgraph "quarkchain/"
        subgraph "cluster/"
            C1[master.py<br/>MasterServer<br/>SyncTask<br/>Synchronizer<br/>SlaveConnection]
            C2[shard.py<br/>Shard<br/>ShardSync<br/>PeerShardConnection]
            C3[cluster.py<br/>Cluster CLI]
            C4[slave.py<br/>Slave entry point]
            C5[miner.py<br/>Miner class]
            C6[rpc.py<br/>RPC types]
            C7[protocol.py<br/>ClusterConnection<br/>P2PConnection]
            C8[p2p_commands.py<br/>CommandOp enum]
            C9[cluster_config.py<br/>ClusterConfig]
            C10[jsonrpc.py<br/>JSON-RPC server]
            C11[log_filter.py<br/>Event filters]
            C12[root_state.py<br/>RootState]
            C13[shard_state.py<br/>ShardState]
            C14[simple_network.py<br/>SimpleNetwork]
            C15[posw.py<br/>PoSW logic]
            C16[guardian.py<br/>Guardian]
        end

        subgraph "p2p/"
            P1[p2p_manager.py<br/>P2P Manager]
            P2[p2p_server.py<br/>P2P Server]
            P3[p2p_proto.py<br/>P2P Protocol]
            P4[peer.py<br/>Peer class]
            P5[discovery.py<br/>Kademlia Discovery]
            P6[kademlia.py<br/>DHT Implementation]
            P7[ecies.py<br/>Encryption]
            P8[nat.py<br/>NAT Traversal]
        end

        subgraph "evm/"
            E1[state.py<br/>EVM State]
            E2[virtual_machine.py<br/>EVM VM]
            E3[transactions.py<br/>EVM Tx]
            E4[trie.py<br/>Merkle Trie]
            E5[opcodes.py<br/>OP Code table]
        end

        CORE1[core.py<br/>Core types]
        CORE2[config.py<br/>QuarkChainConfig]
        CORE3[env.py<br/>Environment]
        CORE4[db.py<br/>Database]
        CORE5[accounts.py<br/>Accounts]
        CORE6[genesis.py<br/>Genesis]
        CORE7[constants.py<br/>Constants]
    end

    C1 --> P1
    C1 --> C6
    C1 --> C7
    C1 --> CORE1
    C1 --> CORE2
    C1 --> CORE3
    C1 --> CORE4
    C2 --> C7
    C2 --> CORE1
    C3 --> C9
    C3 --> CORE3
    C6 --> CORE1
    C7 --> CORE3
    P1 --> P2
    P1 --> P3
    P1 --> P4
    P1 --> P5
    P2 --> P6
    P2 --> P7
    P2 --> P8
```

## 进程模型

```mermaid
graph TB
    subgraph "Cluster Process"
        CL[cluster.py<br/>Async Event Loop]
    end

    subgraph "Master Subprocess"
        M1[MasterServer]
        M2[P2PManager or SimpleNetwork]
        M3[Public JSON-RPC<br/>:38391]
        M4[Private JSON-RPC<br/>:38491]
        M5[PersistentDb<br/>master.db]
    end

    subgraph "Slave Subprocess 0"
        S1[SlaveBackend → Shard]
        S2[ShardState]
        S3[ShardMiner]
        S4[P2P Peer Conn]
        S5[PersistentDb<br/>shard-0.db]
    end

    subgraph "Slave Subprocess N"
        SN1[SlaveBackend → Shard]
        SN2[ShardState]
        SN3[ShardMiner]
        SN4[P2P Peer Conn]
        SN5[PersistentDb<br/>shard-N.db]
    end

    CL --> M1
    CL --> S1
    CL --> SN1

    M1 --> M2
    M1 --> M3
    M1 --> M4
    M1 --> M5

    S1 --> S2
    S1 --> S3
    S1 --> S4
    S2 --> S5

    SN1 --> SN2
    SN1 --> SN3
    SN1 --> SN4
    SN2 --> SN5

    style M1 fill:#ff9
    style S1 fill:#9f9
    style SN1 fill:#9f9
```

## 关键组件说明

| 组件 | 文件 | 职责 |
|------|------|------|
| **Cluster** | `cluster/cluster.py` | 进程编排器，启动 master 和所有 slave 子进程 |
| **MasterServer** | `cluster/master.py` | 主节点核心：管理 slave 连接、根链同步、交易分发、挖矿 |
| **SlaveConnection** | `cluster/master.py` | master 到每个 slave 的 RPC 连接，转发所有 RPC 请求 |
| **Shard** | `cluster/shard.py` | 分片协调器，管理分片状态、矿工、P2P peer 连接、同步 |
| **ShardState** | `cluster/shard_state.py` | 分片状态：交易池、块执行、状态树、genesis 初始化 |
| **RootState** | `cluster/root_state.py` | 根链状态：根块管理、跨分片交易确认 |
| **P2PManager** | `p2p/p2p_manager.py` | 完整 P2P 网络协议管理，含 discovery、peer 管理 |
| **SimpleNetwork** | `cluster/simple_network.py` | 简化网络实现（不含 P2P discovery） |
| **Miner** | `cluster/miner.py` | 通用矿工类，支持 root 和 shard 链挖矿 |
| **Synchronizer** | `cluster/master.py` | 根链同步器，从 peer 下载新根块 |
| **SyncTask** | `cluster/master.py` | 单次同步任务，含 ancestor 查找和块下载 |
