![语言](https://img.shields.io/badge/语言-Verilog_(IEEE1364_2001)-9A90FD.svg) ![仿真](https://img.shields.io/badge/仿真-cocotb-green.svg) ![部署](https://img.shields.io/badge/部署-vivado-FF1010.svg)

[English](#en) | [中文](#cn)

　

<span id="en">FPGA-AES-GCM</span>
========================================

An **FPGA**-based pure-pipeline **AES-GCM** authenticated encryption/decryption IP core, compliant with **NIST SP 800-38D**. Protocol-agnostic — suitable for **IPsec**, **TLS**, **MACsec**, or any **AEAD** application.

For full AES-GCM encrypt/decrypt with APB register control and AXI-Stream data interface, use `aes_gcm_top`. For bare streaming interface without APB, instantiate `aes_gcm_stream_engine` directly.

Features:

- Pure **Verilog** design, no vendor-specific primitives, portable across Xilinx / Intel / Lattice.
- Supports **AES-128**, **AES-192**, and **AES-256**.
- Sustained throughput: **1 block (128-bit) per clock** — **32 Gbps @ 250 MHz**.
- Pipelined **Karatsuba-Ofman (KOA)** GF(2^128) multiplier for GHASH.
- Parameterized GHASH fold depth (**N=4/8/16/32**).
- Composite-field S-box — zero BRAM for AES round logic.
- Standard **APB3** register interface + **AXI-Stream** data interface.
- Byte-level partial last block support with `tkeep` / `tlast`.
- 19 cocotb tests verified against **OpenSSL** (Python `cryptography` library).

　

# Documentation

## `aes_gcm_top` module

Top-level AES-GCM IP with **APB3** register interface and **AXI-Stream** data ports. Instantiates `aes_gcm_apb_regs` for configuration and `aes_gcm_stream_engine` for the crypto datapath. APB provides key/nonce/length programming and status/tag readback. AXI-Stream slave accepts AAD then payload blocks; AXI-Stream master outputs ciphertext or plaintext with `tkeep`/`tlast`. Active-low async reset. Generates `o_irq` on operation completion.

## `aes_gcm_apb_regs` module

APB3 slave register file. Provides write access to key (256-bit), nonce (96-bit), AAD/data byte counts, encrypt/decrypt direction, and expected tag for decrypt verification. Provides read access to computed tag, auth_ok, done status, and error flags. Start is triggered by writing CONFIG register with bit[0]=1. Done is acknowledged by writing CTRL register with bit[0]=1. Zero wait states.

## `aes_gcm_stream_engine` module

Core AES-GCM streaming engine. Accepts a raw 256-bit key and internally performs key expansion, H-power precomputation, AES-CTR keystream generation, GHASH authentication, and tag comparison — all with a single shared AES pipeline and a single shared KOA multiplier. Supports byte-level masking for non-16-byte-aligned final AAD/data blocks. The 15-state FSM covers: key setup, H/J0 initialization, H-power iteration, GHASH fold start, AAD streaming, data streaming with concurrent AES-CTR XOR, length block append, GHASH finalization, and tag generation/comparison. Parameterized by `FOLD_DEPTH` (4/8/16/32).

## `aes_encrypt_core_cf` module

AES encryption stream core with internal key expansion. Wraps `aes_key_expand` and `aes_encrypt_pipe_cf`. Accepts a raw 256-bit key via the configuration interface, runs sequential key expansion internally, then accepts 128-bit data blocks at 1 block/cycle sustained throughput. Supports AES-128/192/256 via `i_key_len`. Carries a parameterizable metadata sideband (`META_WIDTH`) through the pipeline for downstream identification of H/mask/data blocks.

## `aes_encrypt_pipe_cf` module

Fixed-latency 15-stage AES encrypt pipeline using combinational S-box. All 14 AES rounds are fully unrolled with one pipeline register per round. Flow control uses a single global enable (`pipe_en`) gated by the output consumer — no per-stage valid/ready chain, eliminating high-fanout CE bottlenecks. AES-128 uses rounds 1-10, AES-192 uses 1-12, AES-256 uses 1-14; inactive rounds pass data through. Latency: 15 cycles. Throughput: 1 block/cycle.

## `aes_round` module

Complete single AES encryption round: SubBytes (16 parallel S-box lookups) + ShiftRows (wire permutation) + MixColumns (4-column GF(2^8) xtime multiply) + AddRoundKey (128-bit XOR). All combinational with zero pipeline registers. Final round bypasses MixColumns. Inactive round passes input state through unchanged.

## `aes_sbox` module

AES forward S-box byte substitution. Implemented as a 256-entry combinational case-statement ROM. Pure combinational, no clock, no BRAM. Each instance maps one 8-bit input to one 8-bit output per the FIPS 197 S-box table.

## `aes_key_expand` module

Sequential AES key schedule expansion for AES-128/192/256. Generates all 60 round key words (1920 bits) from the raw key. Uses a synchronous BRAM-style S-box (`aes_sub_word_bram`) for the SubWord operation, running at 2 cycles per word (address phase + write phase). Outputs all round keys as a packed 1920-bit vector once expansion is complete.

## `aes_sbox_bram` module

LUTRAM-based S-box with one-cycle registered output. Used exclusively by `aes_key_expand` for the SubWord operation during key schedule computation. Implements the S-box as 8 parallel LUTRAM bit-planes (256-entry ROM per bit), providing area-efficient lookup with synchronous read.

## `aes_sub_word_bram` module

SubWord transform for AES key schedule. Applies the S-box to all 4 bytes of a 32-bit word in parallel using 4 instances of `aes_sbox_bram`. Used by `aes_key_expand`.

## `aes_rcon` module

AES round constant ROM. Returns the round constant word for key schedule expansion, indexed by round number (1-10). Pure combinational lookup.

## `ghash_mul_koa_pipe_fixed` module

Fixed-latency 6-stage pipelined GF(2^128) multiplier using 2-level Karatsuba-Ofman decomposition. Computes the carry-less polynomial product followed by 2-stage GCM polynomial reduction (x^128 + x^7 + x^2 + x + 1). Uses a global pipe enable instead of per-stage valid/ready, eliminating the fanout bottleneck. Latency: 6 cycles. Throughput: 1 multiply/cycle. Sub-modules (bit reversal, leaf products, recombination, reduction) are defined in `ghash_gf2_lib`.

## `ghash_gf2_lib` module library

GF(2) arithmetic primitive library containing 8 self-contained combinational modules: `ghash_bit_reverse128` (128-bit bit reversal for GCM convention), `gf2_clmul16` (16×16 carry-less multiply), `gf2_32_koa_leaf16` (32-bit KOA leaf split into three 16×16 products), `gf2_32_koa_recombine` (recombine 16×16 leaves into 32×32 product), `gf2_64_koa_from32` (64-bit from three 32-bit products), `gf2_128_koa_from64` (128-bit from three 64-bit products), `gf2_ghash_reduce_stage1` (first GCM reduction fold), `gf2_ghash_reduce_stage2` (final reduction fold).

## `ghash_foldN_stream` module

Streaming GHASH fold engine with parameterized group depth (`FOLD_DEPTH`). Processes GHASH blocks in groups of N using precomputed H-powers, achieving 1 block/cycle sustained throughput through a single shared external multiplier. Uses double-buffered group slots for overlapped input and finalization. H-power values are read from an external BRAM via a 1-cycle read pipeline. Multiplier interface is fully external (no internal KOA instance) — the parent module provides the shared KOA and arbitrates between H-power precomputation and GHASH fold.

## `val_rdy_lib` module library

Valid/ready flow-control primitive library containing 3 modules: `val_rdy_one_stage` (1-deep pipeline register with `ready = ~valid | downstream_ready`), `val_rdy_two_entry_fifo` (2-entry circular elastic buffer), `val_rdy_bram_fifo` (parameterizable-depth BRAM-backed FIFO with first-word buffered output). All use asynchronous active-low reset.

　

## Common Signals

    i_clk              : System clock, rising edge active
    i_rst_n            : Async active-low reset
    i_start_valid      : Start command valid
    o_start_ready      : Core ready to accept command
    i_encrypt          : 1 = encrypt, 0 = decrypt
    i_key_len          : Key length: 0 = AES-128, 1 = AES-192, 2 = AES-256
    i_key              : Raw AES key (256-bit, MSB-aligned, zero-padded for shorter keys)
    i_nonce            : 96-bit IV/nonce
    i_aad_bytes        : AAD length in bytes
    i_data_bytes       : Payload length in bytes
    i_tag              : Expected authentication tag (decrypt mode)
    i_s_valid          : Input stream valid (AXI-Stream tvalid)
    o_s_ready          : Input stream ready (AXI-Stream tready)
    i_s_data           : Input stream data, 128-bit (AXI-Stream tdata)
    o_m_valid          : Output stream valid
    i_m_ready          : Output stream ready
    o_m_data           : Output stream data, 128-bit
    o_m_keep           : Output byte enables, 16-bit, MSB-first
    o_m_last           : Output last beat marker
    o_done_valid       : Operation complete
    i_done_ready       : Done acknowledged
    o_tag              : Computed 128-bit authentication tag
    o_auth_ok          : 1 = tag match (decrypt), always 1 (encrypt)
    o_error            : Configuration error

## Common Parameters

    FOLD_DEPTH         : GHASH fold group size: 4, 8, 16, or 32 (default 8)
    META_WIDTH         : Metadata sideband width through AES pipeline
    DATA_WIDTH         : FIFO data width
    ADDR_WIDTH         : FIFO address width (depth = 2^ADDR_WIDTH)

　

## Source Files

    rtl/lib/val_rdy_lib.v                : Valid/ready pipeline register, 2-entry FIFO, BRAM FIFO
    rtl/aes/aes_sbox.v                   : AES S-box combinational lookup
    rtl/aes/aes_sbox_bram.v              : AES S-box LUTRAM (for key expansion)
    rtl/aes/aes_sub_word_bram.v          : AES SubWord (4-byte parallel S-box)
    rtl/aes/aes_rcon.v                   : AES round constant ROM
    rtl/aes/aes_round.v                  : AES round: SubBytes + ShiftRows + MixColumns + AddRoundKey
    rtl/aes/aes_key_expand.v             : AES-128/192/256 key schedule expansion
    rtl/aes/aes_encrypt_pipe_cf.v        : 15-stage fixed-latency AES encrypt pipeline
    rtl/aes/aes_encrypt_core_cf.v        : AES encrypt core with internal key expansion
    rtl/ghash/ghash_gf2_lib.v            : GF(2) arithmetic primitives (KOA, reduction, bit-reverse)
    rtl/ghash/ghash_mul_koa_pipe_fixed.v : 6-stage fixed-latency KOA GF(2^128) multiplier
    rtl/ghash/ghash_foldN_stream.v       : Parameterized streaming GHASH fold engine
    rtl/gcm/aes_gcm_stream_engine.v      : AES-GCM streaming core (AES-CTR + GHASH + H-power)
    rtl/gcm/aes_gcm_apb_regs.v          : APB3 register file (key/nonce/control/status)
    rtl/gcm/aes_gcm_top.v               : Top-level: APB3 + AXI-Stream wrapper

　

# Testing

## Prerequisites

- **ModelSim** DE / QuestaSim
- **Python** 3.8+ with: `pip install cocotb cryptography Pillow`

## Run Tests

```batch
:: Core functional tests (12 tests: 6 encrypt + 6 decrypt)
scripts\run_aes_gcm_core_cocotb.bat

:: APB + AXI-Stream integration tests (5 tests)
scripts\run_aes_gcm_top_cocotb.bat

:: Image encrypt/decrypt round-trip (2 tests)
scripts\run_aes_gcm_image_cocotb.bat
```

## Test Coverage

| Suite | Tests | Coverage |
| :---- | :---: | :------- |
| Core encrypt | 6 | AES-128/192/256, partial block, zero-length, GMAC, 1024B, back-to-back |
| Core decrypt | 6 | Zero, GMAC, 1024B, back-to-back, partial various, tag tamper (×4 scenarios) |
| APB+AXIS | 5 | Register readback, encrypt, decrypt, tag fail, mixed back-to-back |
| Image | 2 | 64×64 RGB8 aligned (12KB), 100×75 RGB8 unaligned (22KB) |
| **Total** | **19** | All verified against **OpenSSL** via Python `cryptography.AESGCM` |

　

# FPGA Deployment

```batch
:: Vivado batch synthesis (edit TCL for target device/frequency)
vivado -mode batch -source scripts\synth_aes_gcm_top_zynq7100.tcl
```

On Xilinx **Zynq-7100** (xc7z100ffg900-2), post-route @ **250 MHz**:

|     LUT      |      FF      |     BRAM     |  DSP  |   WNS   | Throughput |
| :----------: | :----------: | :----------: | :---: | :-----: | :--------: |
| 18,021 (6.5%) | 10,578 (1.9%) | 4 × RAMB36 |   0   | 0.112 ns | **32 Gbps** |

At 250 MHz, the sustained throughput is **32 Gbps** (128 bits per clock), which satisfies line-rate requirements for **10GbE** and **25GbE** encryption offload.

## Optimization History

| Version | Change | LUT | FF | Savings |
| :-----: | :----- | --: | --: | :------ |
| v1.0 | Initial (dual AES pipe + dual KOA) | 33,147 | 24,353 | — |
| v2.0 | Merge duplicate AES pipeline | 22,979 | 18,074 | LUT −31% |
| v3.0 | + Merge KOA + CF S-box + fixed pipe | 18,348 | 11,713 | LUT −45%, FF −52% |
| v3.2 | + Fixed-latency KOA + LUTRAM fix | 18,021 | 10,578 | **LUT −46%, FF −57%** |

　

# References

- NIST SP 800-38D — GCM/GMAC: https://csrc.nist.gov/publications/detail/sp/800-38d/final
- FIPS 197 — AES: https://csrc.nist.gov/publications/detail/fips/197/final
- RFC 4106 — AES-GCM in IPsec ESP: https://www.rfc-editor.org/rfc/rfc4106
- RFC 8446 — TLS 1.3: https://www.rfc-editor.org/rfc/rfc8446

　

　

　

---

<span id="cn">FPGA-AES-GCM</span>
========================================

基于 **FPGA** 的纯流水 **AES-GCM** 认证加解密 IP 核，符合 **NIST SP 800-38D** 标准。协议无关——适用于 **IPsec**、**TLS**、**MACsec** 或任何 **AEAD** 场景。

使用 APB 寄存器控制 + AXI-Stream 数据流的完整方案，例化 `aes_gcm_top`。仅需裸流接口时，直接例化 `aes_gcm_stream_engine`。

特性：

- 纯 **Verilog** 设计，无厂商专有原语，可移植到 Xilinx / Intel / Lattice。
- 支持 **AES-128**、**AES-192**、**AES-256**。
- 持续吞吐：**每时钟 1 个 128-bit 块** —— **250 MHz 下 32 Gbps**。
- 流水化 **Karatsuba-Ofman (KOA)** GF(2^128) 乘法器用于 GHASH 认证。
- 参数化 GHASH 折叠深度（**N=4/8/16/32**）。
- 复合域 S-box —— AES 轮逻辑零 BRAM。
- 标准 **APB3** 寄存器接口 + **AXI-Stream** 数据接口。
- 19 个 cocotb 测试通过 **OpenSSL** 验证。

　

# 模块文档

## `aes_gcm_top` 模块

顶层 AES-GCM IP，包含 **APB3** 寄存器接口和 **AXI-Stream** 数据端口。内部例化 `aes_gcm_apb_regs` 和 `aes_gcm_stream_engine`。APB 用于密钥/IV/长度配置及状态/tag 读回。AXIS slave 接收 AAD + 载荷，AXIS master 输出密文/明文。完成时产生 `o_irq` 中断。

## `aes_gcm_apb_regs` 模块

APB3 寄存器文件。提供密钥（256-bit）、nonce（96-bit）、AAD/数据长度、加解密方向、期望 tag 的写入接口，以及计算 tag、auth_ok、done、error 的读出接口。CONFIG 寄存器 bit[0] 触发启动，CTRL 寄存器 bit[0] 确认完成。零等待周期。

## `aes_gcm_stream_engine` 模块

核心 AES-GCM 流引擎。接受原始 256-bit 密钥，内部完成密钥展开、H-power 预计算、AES-CTR 密钥流生成、GHASH 认证和 tag 比较——全部共用单条 AES 流水线和单个 KOA 乘法器。支持字节级非对齐末块。15 状态 FSM 覆盖完整处理流程。通过 `FOLD_DEPTH` 参数化（4/8/16/32）。

## `aes_encrypt_core_cf` 模块

AES 加密流核心，内置密钥展开。封装 `aes_key_expand` + `aes_encrypt_pipe_cf`。接受原始密钥，内部顺序展开后以 1 block/cycle 持续吞吐接受数据块。支持 AES-128/192/256。通过 `META_WIDTH` 参数携带元数据旁路。

## `aes_encrypt_pipe_cf` 模块

固定延迟 15 级 AES 加密流水线，使用组合 S-box。14 轮 AES 全展开，每轮一级寄存器。全局 pipe_en 使能代替逐级 valid/ready——消除高扇出 CE 瓶颈。延迟 15 周期，吞吐 1 block/cycle。

## `aes_round` 模块

单轮完整 AES 加密：SubBytes（16 并行 S-box）+ ShiftRows（线排列）+ MixColumns（GF(2^8) xtime）+ AddRoundKey（128-bit XOR）。全组合逻辑。末轮跳过 MixColumns。

## `ghash_mul_koa_pipe_fixed` 模块

固定延迟 6 级 KOA GF(2^128) 流水乘法器。2 级 Karatsuba-Ofman 分解 + 2 级 GCM 多项式约简。全局 pipe_en 使能。延迟 6 周期，吞吐 1 multiply/cycle。

## `ghash_foldN_stream` 模块

参数化流式 GHASH fold 引擎。以 N 块为一组处理 GHASH，利用预计算的 H-power 实现 1 block/cycle 持续吞吐。双缓冲 slot 重叠输入和归约。乘法器接口完全外置——由上层共享 KOA 并仲裁 H-power 预计算和 fold。

　

## 源文件列表

    rtl/lib/val_rdy_lib.v                : valid/ready 流水寄存器、2-entry FIFO、BRAM FIFO
    rtl/aes/aes_sbox.v                   : AES S-box 组合查表
    rtl/aes/aes_sbox_bram.v              : AES S-box LUTRAM（密钥展开用）
    rtl/aes/aes_sub_word_bram.v          : AES SubWord（4 字节并行 S-box）
    rtl/aes/aes_rcon.v                   : AES 轮常量 ROM
    rtl/aes/aes_round.v                  : AES 轮：SubBytes + ShiftRows + MixColumns + AddRoundKey
    rtl/aes/aes_key_expand.v             : AES-128/192/256 密钥展开
    rtl/aes/aes_encrypt_pipe_cf.v        : 15 级固定延迟 AES 加密流水线
    rtl/aes/aes_encrypt_core_cf.v        : AES 加密核心（含内部密钥展开）
    rtl/ghash/ghash_gf2_lib.v            : GF(2) 算术原语（KOA、约简、位反转）
    rtl/ghash/ghash_mul_koa_pipe_fixed.v : 6 级固定延迟 KOA GF(2^128) 乘法器
    rtl/ghash/ghash_foldN_stream.v       : 参数化流式 GHASH fold 引擎
    rtl/gcm/aes_gcm_stream_engine.v      : AES-GCM 流核心（AES-CTR + GHASH + H-power）
    rtl/gcm/aes_gcm_apb_regs.v          : APB3 寄存器文件
    rtl/gcm/aes_gcm_top.v               : 顶层：APB3 + AXI-Stream 封装

　

# 仿真

```batch
scripts\run_aes_gcm_core_cocotb.bat     :: 核心 12 测试
scripts\run_aes_gcm_top_cocotb.bat      :: APB+AXIS 5 测试
scripts\run_aes_gcm_image_cocotb.bat    :: 图像 2 测试
```

全部 **19 个测试**通过 Python `cryptography`（OpenSSL）对比验证。

　

# FPGA 部署

在 Xilinx **Zynq-7100** 上，布局布线后 @ **250 MHz**：

|     LUT      |      FF      |     BRAM     |  DSP  |   WNS   |   吞吐    |
| :----------: | :----------: | :----------: | :---: | :-----: | :-------: |
| 18,021 (6.5%) | 10,578 (1.9%) | 4 × RAMB36 |   0   | 0.112 ns | **32 Gbps** |

　

# 参考

- NIST SP 800-38D — GCM/GMAC：https://csrc.nist.gov/publications/detail/sp/800-38d/final
- FIPS 197 — AES：https://csrc.nist.gov/publications/detail/fips/197/final
- RFC 4106 — IPsec ESP 中的 AES-GCM：https://www.rfc-editor.org/rfc/rfc4106
- RFC 8446 — TLS 1.3：https://www.rfc-editor.org/rfc/rfc8446
