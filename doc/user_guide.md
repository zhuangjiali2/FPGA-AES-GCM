# AES-GCM IP Core User Guide

## 1. Overview

Generic pure-pipeline AES-GCM authenticated encryption/decryption IP core.

- **Standard**: NIST SP 800-38D (GCM/GMAC)
- **Key sizes**: AES-128, AES-192, AES-256
- **Throughput**: 1 block (128-bit) per cycle sustained, **32.0 Gbps @ 250 MHz**
- **Interface**: APB3 control + AXI-Stream data
- **Protocol-agnostic**: No IPsec/TLS/ESP coupling

## 2. Top-Level Module

```
aes_gcm_top #(.FOLD_DEPTH(8), .MUL_IMPL(1))
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `FOLD_DEPTH` | 8 | GHASH fold group size (4, 8, 16, or 32) |
| `MUL_IMPL` | 1 | GF(2^128) multiplier: 0=bit-serial, 1=KOA |

### Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `i_clk` | in | 1 | System clock |
| `i_rst_n` | in | 1 | Async active-low reset |
| **APB3 Slave** | | | |
| `i_psel` | in | 1 | Peripheral select |
| `i_penable` | in | 1 | Enable phase |
| `i_pwrite` | in | 1 | Write enable |
| `i_paddr` | in | 8 | Byte address |
| `i_pwdata` | in | 32 | Write data |
| `o_prdata` | out | 32 | Read data |
| `o_pready` | out | 1 | Always 1 (no wait states) |
| `o_pslverr` | out | 1 | Always 0 |
| **AXI-Stream Slave** | | | |
| `i_s_axis_tdata` | in | 128 | Input data (AAD then payload) |
| `i_s_axis_tvalid` | in | 1 | Data valid |
| `o_s_axis_tready` | out | 1 | Core ready |
| `i_s_axis_tlast` | in | 1 | Last beat marker |
| **AXI-Stream Master** | | | |
| `o_m_axis_tdata` | out | 128 | Output data (cipher/plain) |
| `o_m_axis_tkeep` | out | 16 | Byte-lane enables (MSB-first) |
| `o_m_axis_tvalid` | out | 1 | Output valid |
| `i_m_axis_tready` | in | 1 | Downstream ready |
| `o_m_axis_tlast` | out | 1 | Last output beat |
| **Interrupt** | | | |
| `o_irq` | out | 1 | Pulses when operation completes |

## 3. APB Register Map

All registers are 32-bit, byte-addressed.

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | KEY_0 | RW | key[31:0] |
| 0x04 | KEY_1 | RW | key[63:32] |
| 0x08 | KEY_2 | RW | key[95:64] |
| 0x0C | KEY_3 | RW | key[127:96] |
| 0x10 | KEY_4 | RW | key[159:128] |
| 0x14 | KEY_5 | RW | key[191:160] |
| 0x18 | KEY_6 | RW | key[223:192] |
| 0x1C | KEY_7 | RW | key[255:224] |
| 0x20 | NONCE_0 | RW | nonce[31:0] |
| 0x24 | NONCE_1 | RW | nonce[63:32] |
| 0x28 | NONCE_2 | RW | nonce[95:64] |
| 0x2C | AAD_LEN | RW | AAD length in bytes [15:0] |
| 0x30 | DATA_LEN | RW | Payload length in bytes [15:0] |
| 0x34 | CONFIG | W | bit[0]: start, bit[1]: encrypt, bit[3:2]: key_len |
| 0x38 | TAG_IN_0 | RW | Expected tag for decrypt [31:0] |
| 0x3C | TAG_IN_1 | RW | tag[63:32] |
| 0x40 | TAG_IN_2 | RW | tag[95:64] |
| 0x44 | TAG_IN_3 | RW | tag[127:96] |
| 0x48 | STATUS | R | bit[0]: done, bit[1]: auth_ok, bit[2]: error |
| 0x4C | TAG_OUT_0 | R | Computed tag [31:0] |
| 0x50 | TAG_OUT_1 | R | tag[63:32] |
| 0x54 | TAG_OUT_2 | R | tag[95:64] |
| 0x58 | TAG_OUT_3 | R | tag[127:96] |
| 0x5C | CTRL | W | bit[0]: done_ack (clear STATUS.done) |

### CONFIG register encoding

| Bits | Field | Values |
|------|-------|--------|
| [0] | start | 1 = trigger operation |
| [1] | encrypt | 1 = encrypt, 0 = decrypt |
| [3:2] | key_len | 0 = AES-128, 1 = AES-192, 2 = AES-256 |

## 4. Operation Flow

### Encrypt

1. Write KEY_0..KEY_7 (for AES-128, only KEY_0..KEY_3 matter; left-align in MSB)
2. Write NONCE_0..NONCE_2
3. Write AAD_LEN and DATA_LEN
4. Write CONFIG = {key_len, 1'b1 (encrypt), 1'b1 (start)}
5. Send AAD blocks via `s_axis`, then payload blocks
   - Last AAD/payload block: zero-pad unused bytes
6. Collect ciphertext from `m_axis` (tkeep indicates valid bytes on last beat)
7. Poll STATUS until done=1 (or wait for o_irq)
8. Read TAG_OUT_0..3
9. Write CTRL = 1 to acknowledge done

### Decrypt

1. Write KEY, NONCE, AAD_LEN, DATA_LEN (same as encrypt)
2. Write TAG_IN_0..3 with the expected authentication tag
3. Write CONFIG = {key_len, 1'b0 (decrypt), 1'b1 (start)}
4. Send AAD + ciphertext via `s_axis`
5. Collect plaintext from `m_axis`
6. Poll STATUS: done=1 AND auth_ok=1 means authenticated
7. If auth_ok=0, **discard the plaintext** (authentication failed)
8. Write CTRL = 1 to acknowledge

### GMAC (Authentication Only)

- Set DATA_LEN = 0, AAD_LEN = N
- Send only AAD via s_axis
- No output on m_axis
- Tag in TAG_OUT after done

## 5. AXI-Stream Data Format

- **Data width**: 128 bits (16 bytes per beat)
- **Byte order**: MSB-first (byte 0 in tdata[127:120])
- **AAD phase**: Send AAD blocks first. Last AAD block zero-padded.
- **Data phase**: Send payload blocks after AAD. Last block zero-padded.
- **tkeep**: Output only. MSB-first: tkeep[15]=byte0 valid, tkeep[0]=byte15 valid
- **tlast**: Input: optional marker. Output: asserted on final data beat.

## 6. Timing Characteristics

| Parameter | Value |
|-----------|-------|
| Clock frequency | Up to 250 MHz (Zynq-7100) |
| Sustained throughput | 128 bit/cycle = 32.0 Gbps @ 250 MHz |
| Key setup latency | ~80 cycles (AES-128, FOLD_DEPTH=8) |
| First output latency | Key setup + 15 (AES pipe) + fold overhead |
| Packet gap (same key) | ~40 cycles |
| Packet gap (new key) | ~80 cycles (key re-expansion) |

## 7. Resource Utilization (Zynq-7100, post-route, 250 MHz)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | 18,552 | 277,400 | 6.69% |
| Slice Registers | 11,205 | 554,800 | 2.02% |
| Block RAM | 4 | 755 | 0.53% |
| DSP | 0 | 2,020 | 0% |

## 8. Module Hierarchy

```
aes_gcm_top                    APB + AXIS wrapper
├── aes_gcm_apb_regs           APB3 register file
└── aes_gcm_core               Core wrapper
    └── aes_gcm_stream_engine  Main FSM + AES-CTR + GHASH
        ├── aes_encrypt_core_cf    CF S-box AES with key expand
        │   ├── aes_key_expand     Sequential key schedule
        │   └── aes_encrypt_pipe_cf  15-stage fixed-latency pipe
        │       └── aes_round_core_cf  Combinational AES round
        ├── ghash_mul_koa_pipe_fixed   Shared KOA GF(2^128) multiplier
        ├── ghash_foldN_stream     Parameterized GHASH fold
        ├── byte_mask128 (×3)      Byte masking
        ├── val_rdy_two_entry_fifo AES output buffer
        └── val_rdy_bram_fifo      Data delay FIFO
```

## 9. Simulation

### Prerequisites

- ModelSim DE / QuestaSim
- Python 3.8+ with cocotb and cryptography library
- `pip install cocotb cryptography Pillow`

### Run Tests

```powershell
# Core functional tests (12 tests: encrypt + decrypt)
.\scripts\run_aes_gcm_core_cocotb_modelsim.ps1

# APB + AXIS integration tests (5 tests)
.\scripts\run_aes_gcm_top_cocotb_modelsim.ps1

# Image encrypt/decrypt verification (2 tests)
.\scripts\run_aes_gcm_image_cocotb_modelsim.ps1
```

### Test Coverage

| Suite | Tests | Coverage |
|-------|-------|---------|
| Core encrypt | 6 | AES-128/192/256, partial block, zero, GMAC, large, back-to-back |
| Core decrypt | 6 | Zero, GMAC, large, back-to-back, partial various, tag tamper |
| APB+AXIS | 5 | Register readback, encrypt, decrypt, tag fail, back-to-back |
| Image | 2 | 64x64 aligned, 100x75 unaligned |
| **Total** | **19** | |

## 10. Synthesis

```powershell
# Vivado synthesis (250 MHz, Zynq-7100)
.\scripts\synth_aes_gcm_top_zynq7100.tcl
```

Modify `part_name` and clock period in the TCL script for other targets.
