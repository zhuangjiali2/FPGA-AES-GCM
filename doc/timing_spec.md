# AES-GCM IP Core Timing Specification

## 1. Clock Domain

- Single clock: `i_clk`
- Reset: `i_rst_n`, asynchronous active-low
- Target frequency: 250 MHz (4.0 ns period)
- Verified: Zynq-7100 (xc7z100ffg900-2), post-route WNS = 0.112 ns

## 2. APB3 Timing

```
         ┌───┐   ┌───┐   ┌───┐
  i_clk  ┘   └───┘   └───┘   └───
         ┌───────────────┐
  i_psel ┘               └───────
                 ┌───────┐
  i_penable      ┘       └───────
  i_pwrite ──────X valid X───────
  i_paddr  ──────X valid X───────
  i_pwdata ──────X valid X───────  (write)
  o_prdata ──────────────X valid   (read, combinational)
  o_pready ─────────────────── 1   (always ready, no wait)
```

- **Setup phase**: i_psel=1, i_penable=0, address/data/write valid
- **Access phase**: i_psel=1, i_penable=1, transfer completes
- **o_pready**: Always 1, zero wait states
- **o_prdata**: Combinational from register file, valid during access phase

## 3. AXI-Stream Input Timing

```
         ┌───┐   ┌───┐   ┌───┐   ┌───┐
  i_clk  ┘   └───┘   └───┘   └───┘   └───
         ┌───────────────┐       ┌───┐
  tvalid ┘               └───────┘   └───  (gap allowed)
         ────────┐   ┌───────────────────
  tready         └───┘                      (backpressure)
         ════════X D0 X═══════════X D1 X═  (tdata)
                       ↑               ↑
                     fire            fire
```

- **Handshake**: Data transfers when `tvalid & tready` on rising edge
- **Ordering**: AAD blocks first, then payload blocks (as configured by APB)
- **Last block**: Zero-pad unused bytes. Core masks internally.
- **tlast**: Optional input marker (core uses byte counts from APB)

## 4. AXI-Stream Output Timing

```
         ┌───┐   ┌───┐   ┌───┐
  i_clk  ┘   └───┘   └───┘   └───
         ┌───────┐       ┌───────┐
  tvalid ┘       └───────┘       └───
  tready ─────────────────────────────  (downstream always ready)
         ═══X D0 X═══════X D1   X═══
         ───X K0 X───────X Klast X───  (tkeep: valid bytes)
                         ┌───────┐
  tlast ─────────────────┘       └───  (final data beat)
```

- **tkeep**: MSB-first. tkeep[15]=byte0 valid, tkeep[0]=byte15 valid
- **tkeep on non-last beats**: All 1s (16'hFFFF)
- **tkeep on last beat**: Reflects actual valid bytes (e.g., 7 bytes → 16'hFE00)
- **tlast**: Asserted on the last output data beat

## 5. Operation Timing Diagram

```
APB:  | write KEY | write NONCE | write LEN | write CONFIG(start=1) |
      |  8 words  |   3 words   |  2 words  |       1 word          |
      |← 16 cyc →|←  6 cyc   →|← 4 cyc  →|←      2 cyc         →|

Core: |           | key expand | AES(0)→H | H-power  | J0→mask |
      |           |  ~28 cyc   | ~15 cyc  | ~50 cyc  | ~15 cyc |
      |           |←─── precompute: ~110 cycles total ────────→|

AXIS: |                                                         | AAD blocks | data blocks |
      |                                                         |← N_aad  →|← N_data   →|

m_axis:|                                                                    | ciphertext/plaintext |
       |                                                                    |← N_data (1 blk/cyc)→|

Done:  |                                                                                           | done |
       |                                                                                           | irq↑ |
```

## 6. Latency Summary

### Per-packet latency (first byte out after start)

| Component | Cycles | Notes |
|-----------|--------|-------|
| APB config writes | ~28 | 14 registers × 2 APB cycles each |
| Key expansion | 14-28 | AES-128: 14, AES-256: 28 |
| H computation (AES pipe) | 15 | AES encrypt of zero block |
| H-power iteration | 7×(N-1) | N=8: 49 cycles |
| J0/mask (AES pipe) | 15 | Tag mask computation |
| AAD processing | N_aad | 1 block/cycle |
| Data processing | N_data | 1 block/cycle + 15 cycle pipe fill |
| **Total first output** | **~110 + N_aad + 15** | After config |

### Sustained throughput

| Metric | Value |
|--------|-------|
| Data throughput | 1 block (128-bit) per cycle |
| @ 200 MHz | 25.6 Gbps |
| @ 250 MHz | 32.0 Gbps |

### Inter-packet gap

| Scenario | Gap (cycles) |
|----------|-------------|
| Same key, consecutive packets | ~40 (fold drain + tag + done ack + restart) |
| Different key | ~110 (full key expand + H-power recompute) |

## 7. Backpressure Behavior

- **Input stall**: If `o_s_axis_tready` deasserts, upstream must hold tdata/tvalid stable
- **Output stall**: If `i_m_axis_tready` deasserts, core freezes output and propagates backpressure to input
- **No data loss**: All pipeline stages freeze simultaneously on backpressure
- **Throughput impact**: Backpressure directly reduces effective throughput

## 8. Reset Timing

```
         ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐
  i_clk  ┘   └───┘   └───┘   └───┘   └───┘   └───
              ┌───────────────────────────┐
  i_rst_n ────┘                           └───────
                                           ↑
                                     release: core ready
                                     after 1 cycle
```

- Asynchronous assert, synchronous deassert recommended
- All internal state cleared on reset
- Core ready to accept APB writes 1 cycle after reset release
