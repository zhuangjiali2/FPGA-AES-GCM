"""
Cocotb integration test for aes_gcm_core (generic AES-GCM).

Uses Python cryptography library as golden reference.
Covers AES-128/192/256, encrypt/decrypt, byte-level partial blocks,
tag mismatch detection, and back-to-back packets.
"""

import math
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def to_blocks(data: bytes):
    nblocks = math.ceil(len(data) / 16) if len(data) > 0 else 0
    blocks = []
    for i in range(nblocks):
        chunk = data[i*16:(i+1)*16]
        if len(chunk) < 16:
            chunk = chunk + b'\x00' * (16 - len(chunk))
        blocks.append(int.from_bytes(chunk, "big"))
    return blocks


def blocks_to_bytes(blocks, total_bytes):
    result = b''
    for blk in blocks:
        result += blk.to_bytes(16, "big")
    return result[:total_bytes]


async def reset_dut(dut):
    dut.i_rst_n.value = 0
    dut.i_start_valid.value = 0
    dut.i_encrypt.value = 1
    dut.i_key_len.value = 0
    dut.i_key.value = 0
    dut.i_nonce.value = 0
    dut.i_aad_bytes.value = 0
    dut.i_data_bytes.value = 0
    dut.i_tag.value = 0
    dut.i_s_valid.value = 0
    dut.i_s_data.value = 0
    dut.i_m_ready.value = 1
    dut.i_done_ready.value = 1
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)


async def start_packet(dut, encrypt, key, nonce, aad_bytes, data_bytes, tag=0):
    dut.i_encrypt.value = 1 if encrypt else 0
    dut.i_key_len.value = {16: 0, 24: 1, 32: 2}[len(key)]
    dut.i_key.value = int.from_bytes(key, "big") << (256 - len(key) * 8)
    dut.i_nonce.value = int.from_bytes(nonce, "big")
    dut.i_aad_bytes.value = aad_bytes
    dut.i_data_bytes.value = data_bytes
    dut.i_tag.value = tag
    dut.i_start_valid.value = 1
    while True:
        await RisingEdge(dut.i_clk)
        if int(dut.o_start_ready.value) == 1:
            break
    dut.i_start_valid.value = 0


async def send_blocks(dut, blocks):
    for block in blocks:
        dut.i_s_data.value = block
        dut.i_s_valid.value = 1
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_s_ready.value) == 1:
                break
    dut.i_s_valid.value = 0
    dut.i_s_data.value = 0


async def collect_output(dut, data_bytes, timeout_cycles=20000):
    data_blocks = math.ceil(data_bytes / 16) if data_bytes > 0 else 0
    data = []
    tag = None
    auth_ok = None
    error = None

    for _ in range(timeout_cycles):
        await RisingEdge(dut.i_clk)
        if int(dut.o_m_valid.value) == 1 and int(dut.i_m_ready.value) == 1:
            data.append(int(dut.o_m_data.value))
        if int(dut.o_done_valid.value) == 1 and int(dut.i_done_ready.value) == 1:
            tag = int(dut.o_tag.value)
            auth_ok = int(dut.o_auth_ok.value)
            error = int(dut.o_error.value)
            assert len(data) == data_blocks, (
                f"done before all outputs: got {len(data)}, "
                f"expected {data_blocks}"
            )
            return data, tag, auth_ok, error

    raise AssertionError(
        f"timeout: outputs={len(data)}/{data_blocks}"
    )


async def run_packet(dut, encrypt, key, nonce, aad, payload, tag=0):
    aad_blocks = to_blocks(aad)
    payload_blocks = to_blocks(payload)
    collector = cocotb.start_soon(
        collect_output(dut, len(payload))
    )
    await start_packet(
        dut, encrypt, key, nonce,
        len(aad), len(payload), tag
    )
    await send_blocks(dut, aad_blocks + payload_blocks)
    result = await collector
    return result


@cocotb.test()
async def test_encrypt_decrypt_all_key_lengths(dut):
    """Encrypt then decrypt with AES-128/192/256, verify round-trip."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    nonce = bytes.fromhex("101112131415161718191a1b")
    aad = bytes.fromhex("202122232425262728292a2b2c2d2e2f")
    plain = bytes.fromhex(
        "303132333435363738393a3b3c3d3e3f"
        "404142434445464748494a4b4c4d4e4f"
    )
    keys = [
        bytes.fromhex("000102030405060708090a0b0c0d0e0f"),
        bytes.fromhex("000102030405060708090a0b0c0d0e0f"
                      "1011121314151617"),
        bytes.fromhex("000102030405060708090a0b0c0d0e0f"
                      "101112131415161718191a1b1c1d1e1f"),
    ]

    for key in keys:
        dut._log.info(f"Testing AES-{len(key)*8}")
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        expected_cipher = golden[:-16]
        expected_tag = int.from_bytes(golden[-16:], "big")

        # Encrypt
        enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
            dut, True, key, nonce, aad, plain, 0
        )
        enc_bytes = blocks_to_bytes(enc_data, len(plain))
        assert enc_bytes == expected_cipher, (
            f"cipher mismatch for AES-{len(key)*8}"
        )
        assert enc_tag == expected_tag
        assert enc_auth_ok == 1
        assert enc_error == 0

        await RisingEdge(dut.i_clk)

        # Decrypt
        dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
            dut, False, key, nonce, aad, expected_cipher, expected_tag
        )
        dec_bytes = blocks_to_bytes(dec_data, len(plain))
        assert dec_bytes == plain, (
            f"plaintext mismatch for AES-{len(key)*8}"
        )
        assert dec_tag == expected_tag
        assert dec_auth_ok == 1
        assert dec_error == 0

        await RisingEdge(dut.i_clk)

        # Tag mismatch
        bad_tag = expected_tag ^ 1
        bad_data, bad_tag_out, bad_auth_ok, bad_error = await run_packet(
            dut, False, key, nonce, aad, expected_cipher, bad_tag
        )
        assert bad_auth_ok == 0, "bad tag should fail auth"
        assert bad_error == 0

        await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_partial_last_block(dut):
    """Non-16-byte-aligned AAD and data."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = bytes(range(20))       # 20 bytes = 1.25 blocks
    plain = bytes(range(7))      # 7 bytes = partial block

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    expected_cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, plain, 0
    )
    enc_bytes = blocks_to_bytes(enc_data, len(plain))
    assert enc_bytes == expected_cipher
    assert enc_tag == expected_tag
    assert enc_auth_ok == 1

    await RisingEdge(dut.i_clk)

    # Decrypt back
    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, aad, expected_cipher, expected_tag
    )
    dec_bytes = blocks_to_bytes(dec_data, len(plain))
    assert dec_bytes == plain
    assert dec_auth_ok == 1


@cocotb.test()
async def test_zero_aad_zero_data(dut):
    """Tag-only mode: 0 AAD + 0 data."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(16)
    nonce = bytes(12)
    aad = b""
    plain = b""

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    expected_tag = int.from_bytes(golden[-16:], "big")

    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, plain, 0
    )
    assert len(enc_data) == 0
    assert enc_tag == expected_tag
    assert enc_auth_ok == 1


@cocotb.test()
async def test_aad_only(dut):
    """GMAC mode: AAD only, no data."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(32))
    nonce = bytes(range(12))
    aad = bytes(range(48))
    plain = b""

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    expected_tag = int.from_bytes(golden[-16:], "big")

    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, plain, 0
    )
    assert len(enc_data) == 0
    assert enc_tag == expected_tag
    assert enc_auth_ok == 1


@cocotb.test()
async def test_large_payload(dut):
    """Multi-fold-group payload (>32 blocks)."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = bytes(range(16))
    plain = bytes(range(256)) * 4  # 1024 bytes = 64 blocks

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    expected_cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
        dut, True, key, nonce, aad, plain, 0
    )
    enc_bytes = blocks_to_bytes(enc_data, len(plain))
    assert enc_bytes == expected_cipher
    assert enc_tag == expected_tag
    assert enc_auth_ok == 1


@cocotb.test()
async def test_back_to_back_packets(dut):
    """Two packets back-to-back with different keys."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    configs = [
        (bytes(range(16)), bytes(range(12)), bytes(range(16)), bytes(range(32))),
        (bytes(range(32)), bytes(range(12)), bytes(range(20)), bytes(range(48))),
    ]

    for key, nonce, aad, plain in configs:
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        expected_cipher = golden[:-16]
        expected_tag = int.from_bytes(golden[-16:], "big")

        enc_data, enc_tag, enc_auth_ok, enc_error = await run_packet(
            dut, True, key, nonce, aad, plain, 0
        )
        enc_bytes = blocks_to_bytes(enc_data, len(plain))
        assert enc_bytes == expected_cipher
        assert enc_tag == expected_tag
        assert enc_auth_ok == 1

        await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_decrypt_zero_aad_zero_data(dut):
    """Decrypt tag-only mode: 0 AAD + 0 data, verify auth."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(16)
    nonce = bytes(12)
    golden = AESGCM(key).encrypt(nonce, b"", b"")
    expected_tag = int.from_bytes(golden[-16:], "big")

    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, b"", b"", expected_tag
    )
    assert len(dec_data) == 0
    assert dec_auth_ok == 1

    bad_data, bad_tag, bad_auth, bad_err = await run_packet(
        dut, False, key, nonce, b"", b"", expected_tag ^ 1
    )
    assert bad_auth == 0


@cocotb.test()
async def test_decrypt_aad_only(dut):
    """Decrypt GMAC: AAD only, verify auth tag."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(32))
    nonce = bytes(range(12))
    aad = bytes(range(48))
    golden = AESGCM(key).encrypt(nonce, b"", aad)
    expected_tag = int.from_bytes(golden[-16:], "big")

    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, aad, b"", expected_tag
    )
    assert len(dec_data) == 0
    assert dec_auth_ok == 1

    bad_data, bad_tag, bad_auth, bad_err = await run_packet(
        dut, False, key, nonce, aad, b"", expected_tag ^ 0xDEAD
    )
    assert bad_auth == 0


@cocotb.test()
async def test_decrypt_large_payload(dut):
    """Decrypt large payload (1024B = 64 blocks)."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = bytes(range(16))
    plain = bytes(range(256)) * 4

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
        dut, False, key, nonce, aad, cipher, expected_tag
    )
    dec_bytes = blocks_to_bytes(dec_data, len(plain))
    assert dec_bytes == plain
    assert dec_auth_ok == 1


@cocotb.test()
async def test_decrypt_back_to_back(dut):
    """Decrypt multiple packets back-to-back with different keys."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    configs = [
        (bytes(range(16)), bytes(range(12)), bytes(range(16)), bytes(range(32))),
        (bytes(range(24)), bytes(range(12)), bytes(range(7)),  bytes(range(100))),
        (bytes(range(32)), bytes(range(12)), bytes(range(20)), bytes(range(48))),
    ]

    for key, nonce, aad, plain in configs:
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        cipher = golden[:-16]
        expected_tag = int.from_bytes(golden[-16:], "big")

        dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
            dut, False, key, nonce, aad, cipher, expected_tag
        )
        dec_bytes = blocks_to_bytes(dec_data, len(plain))
        assert dec_bytes == plain
        assert dec_auth_ok == 1
        await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_decrypt_partial_blocks_various(dut):
    """Decrypt with various non-aligned AAD and data lengths."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))

    test_cases = [
        (b"",           bytes(range(1))),
        (bytes(range(1)), bytes(range(15))),
        (bytes(range(15)), bytes(range(17))),
        (bytes(range(31)), bytes(range(33))),
        (bytes(range(13)), b""),
    ]

    for aad, plain in test_cases:
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        cipher = golden[:-16]
        expected_tag = int.from_bytes(golden[-16:], "big")

        dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
            dut, False, key, nonce, aad, cipher, expected_tag
        )
        dec_bytes = blocks_to_bytes(dec_data, len(plain))
        assert dec_bytes == plain, (
            f"Decrypt mismatch: aad={len(aad)}B data={len(plain)}B"
        )
        assert dec_auth_ok == 1
        await RisingEdge(dut.i_clk)


@cocotb.test()
async def test_decrypt_tag_tamper_various(dut):
    """Verify auth failure with corrupted tag across different scenarios."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(32))
    nonce = bytes(range(12))

    test_cases = [
        (bytes(range(16)), bytes(range(16))),
        (bytes(range(20)), bytes(range(7))),
        (b"",             bytes(range(100))),
        (bytes(range(48)), bytes(range(256))),
    ]

    for aad, plain in test_cases:
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        cipher = golden[:-16]
        good_tag = int.from_bytes(golden[-16:], "big")

        dec_data, dec_tag, dec_auth_ok, dec_error = await run_packet(
            dut, False, key, nonce, aad, cipher, good_tag
        )
        assert dec_auth_ok == 1, (
            f"Good tag failed: aad={len(aad)}B data={len(plain)}B"
        )
        await RisingEdge(dut.i_clk)

        bad_data, bad_tag, bad_auth, bad_err = await run_packet(
            dut, False, key, nonce, aad, cipher, good_tag ^ 0xFF
        )
        assert bad_auth == 0, (
            f"Bad tag passed: aad={len(aad)}B data={len(plain)}B"
        )
        await RisingEdge(dut.i_clk)
