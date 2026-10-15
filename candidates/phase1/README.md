# Phase one: permanent CLAUS core protections

Review candidate only. Not deployed or activated.

The three entrypoints are in contract/src: ProtectedToken.sol, ProtectedHook.sol and PhaseOneFinalizer.sol. Existing token, main pool and custody addresses are retained. The finalizer atomically installs both implementations and renounces both ProxyAdmin owners. Token ownership remains only for metadata, globally bounded extra fees and a directory of separate product contracts. Registered products are never called by a swap and receive no core allowance or delegate authority.

The hook starts at 2.3%, with zero additional fee. The aggregate ceiling is 15% for core fees plus the actual main-pool v4 protocol fee. The optional surcharge is limited to 12.6%, reserving 0.1% for protocol fees; actual charges are checked after each trade. There is no sender, holder or external-pool transfer blacklist. Unrelated third-party pool costs, price impact and gas are outside this ceiling. LP owners still own their liquidity.

The existing NFT/LP debts, NFT backing, revenue recipients, fixed settlement processors and already running burn window are retained. Exact inherited source lives in contract/src/legacy. Compiler dependencies are included with their original paths and license headers. The supplied fork tests use an isolated local RPC with chain ID 31337 at Ethereum block 26197295; they do not send mainnet transactions. Eleven focused cases pass, including both sides/modes at maximum fee, full LP exits and NFT redemption. Local checks are not an independent audit.

Build from contract/ using Forge (Solidity 0.8.26, Cancun, optimizer 200, via IR). The manifest records source and bytecode-template hashes; immutable-populated deployed code must be checked separately. No source in this candidate permits arbitrary replacement of the protected core after finalization.
