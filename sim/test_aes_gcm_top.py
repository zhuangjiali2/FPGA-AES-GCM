"""
Cocotb test for aes_gcm_top (APB + AXI-Stream wrapper).

Verifies APB register access, AXIS data streaming, encrypt and decrypt
with golden reference from Python cryptography library.
"""

import math
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


# APB register addresses
ADDR_KEY_0    = 0x00
ADDR_NONCE_0  = 0x20
ADDR_AAD_LEN  = 0x2C
ADDR_DATA_LEN = 0x30
ADDR_CONFIG   = 0x34
ADDR_TAG_IN_0 = 0x38
ADDR_STATUS   = 0x48
ADDR_TAG_OUT_0= 0x4C
ADDR_CTRL     = 0x5C


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
    dut.i_psel.value = 0
    dut.i_penable.value = 0
    dut.i_pwrite.value = 0
    dut.i_paddr.value = 0
    dut.i_pwdata.value = 0
    dut.i_s_axis_tdata.value = 0
    dut.i_s_axis_tvalid.value = 0
    dut.i_s_axis_tlast.value = 0
    dut.i_m_axis_tready.value = 1
    for _ in range(10):
        await RisingEdge(dut.i_clk)
    dut.i_rst_n.value = 1
    for _ in range(3):
        await RisingEdge(dut.i_clk)


async def apb_write(dut, addr, data):
    dut.i_psel.value = 1
    dut.i_pwrite.value = 1
    dut.i_paddr.value = addr
    dut.i_pwdata.value = data
    dut.i_penable.value = 0
    await RisingEdge(dut.i_clk)
    dut.i_penable.value = 1
    await RisingEdge(dut.i_clk)
    dut.i_psel.value = 0
    dut.i_penable.value = 0
    dut.i_pwrite.value = 0


async def apb_read(dut, addr):
    dut.i_psel.value = 1
    dut.i_pwrite.value = 0
    dut.i_paddr.value = addr
    dut.i_penable.value = 0
    await RisingEdge(dut.i_clk)
    dut.i_penable.value = 1
    await RisingEdge(dut.i_clk)
    val = int(dut.o_prdata.value)
    dut.i_psel.value = 0
    dut.i_penable.value = 0
    return val


async def configure_and_start(dut, encrypt, key, nonce, aad_bytes,
                               data_bytes, tag=0):
    key_int = int.from_bytes(key, "big") << (256 - len(key) * 8)
    for i in range(8):
        await apb_write(dut, ADDR_KEY_0 + i * 4,
                        (key_int >> (i * 32)) & 0xFFFFFFFF)
    nonce_int = int.from_bytes(nonce, "big")
    for i in range(3):
        await apb_write(dut, ADDR_NONCE_0 + i * 4,
                        (nonce_int >> (i * 32)) & 0xFFFFFFFF)
    await apb_write(dut, ADDR_AAD_LEN, aad_bytes)
    await apb_write(dut, ADDR_DATA_LEN, data_bytes)
    for i in range(4):
        await apb_write(dut, ADDR_TAG_IN_0 + i * 4,
                        (tag >> (i * 32)) & 0xFFFFFFFF)
    key_len = {16: 0, 24: 1, 32: 2}[len(key)]
    config_val = (key_len << 2) | ((1 if encrypt else 0) << 1) | 1
    await apb_write(dut, ADDR_CONFIG, config_val)


async def send_axis_blocks(dut, blocks):
    for idx, block in enumerate(blocks):
        dut.i_s_axis_tdata.value = block
        dut.i_s_axis_tvalid.value = 1
        dut.i_s_axis_tlast.value = 1 if (idx == len(blocks) - 1) else 0
        while True:
            await RisingEdge(dut.i_clk)
            if int(dut.o_s_axis_tready.value) == 1:
                break
    dut.i_s_axis_tvalid.value = 0
    dut.i_s_axis_tlast.value = 0
    dut.i_s_axis_tdata.value = 0


async def collect_axis_output(dut, data_bytes, timeout=20000):
    nblocks = math.ceil(data_bytes / 16) if data_bytes > 0 else 0
    data = []
    for _ in range(timeout):
        await RisingEdge(dut.i_clk)
        if int(dut.o_m_axis_tvalid.value) == 1 and \
           int(dut.i_m_axis_tready.value) == 1:
            data.append(int(dut.o_m_axis_tdata.value))
            if len(data) == nblocks:
                return data
    if nblocks == 0:
        return []
    raise AssertionError(f"timeout: got {len(data)}/{nblocks} blocks")


async def wait_done(dut, timeout=20000):
    for _ in range(timeout):
        await RisingEdge(dut.i_clk)
        status = await apb_read(dut, ADDR_STATUS)
        if status & 1:
            return status
    raise AssertionError("timeout waiting for done")


async def read_tag_out(dut):
    tag = 0
    for i in range(4):
        word = await apb_read(dut, ADDR_TAG_OUT_0 + i * 4)
        tag |= (word << (i * 32))
    return tag


async def ack_done(dut):
    await apb_write(dut, ADDR_CTRL, 1)


async def run_apb_packet(dut, encrypt, key, nonce, aad, payload, tag=0):
    aad_blocks = to_blocks(aad)
    payload_blocks = to_blocks(payload)
    all_blocks = aad_blocks + payload_blocks

    collector = cocotb.start_soon(
        collect_axis_output(dut, len(payload))
    )
    await configure_and_start(
        dut, encrypt, key, nonce, len(aad), len(payload), tag
    )
    if all_blocks:
        await send_axis_blocks(dut, all_blocks)

    out_data = await collector
    status = await wait_done(dut)
    tag_out = await read_tag_out(dut)
    auth_ok = (status >> 1) & 1
    error = (status >> 2) & 1
    await ack_done(dut)
    await RisingEdge(dut.i_clk)
    return out_data, tag_out, auth_ok, error


@cocotb.test()
async def test_apb_register_readback(dut):
    """Verify APB write then read for config registers."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    await apb_write(dut, ADDR_KEY_0, 0xDEADBEEF)
    val = await apb_read(dut, ADDR_KEY_0)
    assert val == 0xDEADBEEF, f"KEY_0 readback: {val:#x}"

    await apb_write(dut, ADDR_NONCE_0, 0x12345678)
    val = await apb_read(dut, ADDR_NONCE_0)
    assert val == 0x12345678, f"NONCE_0 readback: {val:#x}"

    await apb_write(dut, ADDR_AAD_LEN, 0x100)
    val = await apb_read(dut, ADDR_AAD_LEN)
    assert val == 0x100, f"AAD_LEN readback: {val:#x}"


@cocotb.test()
async def test_apb_axis_encrypt(dut):
    """Encrypt via APB config + AXIS data, verify against cryptography lib."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = bytes(range(16))
    plain = bytes(range(32))

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    expected_cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    out_data, tag_out, auth_ok, error = await run_apb_packet(
        dut, True, key, nonce, aad, plain, 0
    )
    out_bytes = blocks_to_bytes(out_data, len(plain))
    assert out_bytes == expected_cipher, "Ciphertext mismatch"
    assert tag_out == expected_tag, f"Tag mismatch: {tag_out:#x} vs {expected_tag:#x}"
    assert auth_ok == 1
    assert error == 0


@cocotb.test()
async def test_apb_axis_decrypt(dut):
    """Decrypt via APB config + AXIS data, verify plaintext and auth."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(32))
    nonce = bytes(range(12))
    aad = bytes(range(20))
    plain = bytes(range(48))

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    cipher = golden[:-16]
    expected_tag = int.from_bytes(golden[-16:], "big")

    out_data, tag_out, auth_ok, error = await run_apb_packet(
        dut, False, key, nonce, aad, cipher, expected_tag
    )
    out_bytes = blocks_to_bytes(out_data, len(plain))
    assert out_bytes == plain, "Plaintext mismatch"
    assert auth_ok == 1


@cocotb.test()
async def test_apb_axis_decrypt_tag_fail(dut):
    """Decrypt with bad tag, verify auth_ok=0."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    key = bytes(range(16))
    nonce = bytes(range(12))
    aad = bytes(range(16))
    plain = bytes(range(16))

    golden = AESGCM(key).encrypt(nonce, plain, aad)
    cipher = golden[:-16]
    good_tag = int.from_bytes(golden[-16:], "big")
    bad_tag = good_tag ^ 0xABCD

    out_data, tag_out, auth_ok, error = await run_apb_packet(
        dut, False, key, nonce, aad, cipher, bad_tag
    )
    assert auth_ok == 0, "Bad tag should fail auth"


@cocotb.test()
async def test_apb_axis_back_to_back(dut):
    """Two packets back-to-back via APB+AXIS."""
    cocotb.start_soon(Clock(dut.i_clk, 10, units="ns").start())
    await reset_dut(dut)

    configs = [
        (True,  bytes(range(16)), bytes(range(12)), bytes(range(16)), bytes(range(32))),
        (False, bytes(range(32)), bytes(range(12)), bytes(range(20)), bytes(range(48))),
    ]

    for encrypt, key, nonce, aad, plain in configs:
        golden = AESGCM(key).encrypt(nonce, plain, aad)
        cipher = golden[:-16]
        expected_tag = int.from_bytes(golden[-16:], "big")

        if encrypt:
            out_data, tag_out, auth_ok, error = await run_apb_packet(
                dut, True, key, nonce, aad, plain, 0
            )
            out_bytes = blocks_to_bytes(out_data, len(plain))
            assert out_bytes == cipher
            assert tag_out == expected_tag
        else:
            out_data, tag_out, auth_ok, error = await run_apb_packet(
                dut, False, key, nonce, aad, cipher, expected_tag
            )
            out_bytes = blocks_to_bytes(out_data, len(plain))
            assert out_bytes == plain
            assert auth_ok == 1
